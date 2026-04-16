import Darwin
import Foundation
import os

/// Manages a t3code Node.js server process for a single workspace.
/// Spawns the server with a preselected port, confirms startup via the
/// sidecar state directory, and handles restart/shutdown with deduplication.
final class T3CodeSidecarManager {

    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "T3CodeSidecar")

    /// The configured server port for this sidecar process.
    private(set) var port: Int?

    /// The workspace's project directory (used as cwd and state-dir base).
    let projectDirectory: URL

    /// The .cmux home directory for this workspace (passed as --base-dir to t3code).
    private var homeDir: String { projectDirectory.appendingPathComponent(".cmux").path }

    /// Host-side log directory for cmux-managed sidecar bootstrap output.
    private var hostLogsDir: String { (homeDir as NSString).appendingPathComponent("logs") }

    /// Combined stdout/stderr log for the spawned sidecar process.
    private var sidecarLogPath: String { (hostLogsDir as NSString).appendingPathComponent("sidecar.log") }

    /// The t3code "userdata" state directory (derived by the server as {homeDir}/userdata).
    private var stateDir: String { (homeDir as NSString).appendingPathComponent("userdata") }

    /// The port file path inside the state directory.
    private var portFilePath: String { (stateDir as NSString).appendingPathComponent("server.port") }

    /// The running Node.js process.
    private var process: Process?

    /// File handle for combined sidecar stdout/stderr logging.
    private var sidecarLogHandle: FileHandle?

    /// Whether we're intentionally shutting down (suppress restart).
    private var isShuttingDown = false

    /// Whether a restart is already scheduled (prevent duplicate restarts).
    private var isRestartPending = false

    /// Timer for polling the port file.
    private var portPollTimer: DispatchSourceTimer?

    /// Prevent duplicate port publication while startup probes converge.
    private var hasPublishedPort = false

    /// Stable bootstrap token exposed to the embedded web client for this workspace.
    private(set) var desktopBootstrapToken: String = UUID().uuidString.lowercased()

    /// Callback when a port is assigned so consumers can start readiness polling.
    var onReady: ((Int) -> Void)?

    /// Callback when server crashes unexpectedly.
    var onCrash: (() -> Void)?

    init(projectDirectory: URL) {
        self.projectDirectory = projectDirectory
    }

    deinit {
        shutdown()
    }

    // MARK: - Lifecycle

    /// Start the t3code server process.
    func start() {
        guard process == nil else {
            logger.warning("Sidecar already running for \(self.projectDirectory.path)")
            return
        }

        isShuttingDown = false
        isRestartPending = false
        hasPublishedPort = false

        // Create .cmux directories if needed
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: hostLogsDir, withIntermediateDirectories: true)

        // Clean up stale port file from previous run
        try? FileManager.default.removeItem(atPath: portFilePath)

        // Locate the t3code server binary
        guard let serverBinary = resolveServerBinary() else {
            logger.error("Could not find t3code server binary")
            return
        }

        logger.info("Using t3code binary: \(serverBinary)")

        guard let selectedPort = port ?? reserveAvailablePort() else {
            logger.error("Could not reserve a local port for the t3code sidecar")
            return
        }
        port = selectedPort

        let proc = Process()
        let bootstrapPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [
            "node",
            serverBinary,
            "--port", String(selectedPort),
            "--base-dir", homeDir,
            "--bootstrap-fd", "0",
            "--auto-bootstrap-project-from-cwd",
            "--no-browser",
            "--mode", "desktop"
        ]
        proc.currentDirectoryURL = projectDirectory
        proc.standardInput = bootstrapPipe

        // Inherit environment but ensure PATH includes common Node locations
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin", "/opt/homebrew/opt/node/bin", "/Users/\(NSUserName())/.bun/bin", "/Users/\(NSUserName())/.local/bin"]
        if let existingPath = env["PATH"] {
            env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
        }
        // The embedded cmux sidecar is loopback-only and does not plumb auth tokens
        // into the webview/WebSocket client. Ignore any shell-level token override
        // inherited from the user's environment so the local chat can hydrate.
        env.removeValue(forKey: "T3CODE_AUTH_TOKEN")
        proc.environment = env

        sidecarLogHandle = openSidecarLogHandle()
        proc.standardOutput = sidecarLogHandle ?? FileHandle.nullDevice
        proc.standardError = sidecarLogHandle ?? FileHandle.nullDevice

        // Handle unexpected termination.
        // Dispatch to main thread to avoid data races — terminationHandler
        // fires on an unspecified background thread.
        proc.terminationHandler = { [weak self] terminatedProc in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.isShuttingDown else { return }
                self.logger.error("t3code sidecar exited unexpectedly (code \(terminatedProc.terminationStatus))")
                self.process = nil
                self.port = nil
                self.stopPortPolling()
                self.closeSidecarLogHandle()
                self.onCrash?()
            }
        }

        do {
            try proc.run()
            bootstrapPipe.fileHandleForReading.closeFile()
            writeBootstrapEnvelope(to: bootstrapPipe.fileHandleForWriting)
            self.process = proc
            logger.info(
                "Spawned t3code sidecar (PID \(proc.processIdentifier)) on port \(selectedPort) for \(self.projectDirectory.path)"
            )
            // Don't call publishPort here — defer onReady until the port file
            // confirms the actual port. This avoids the race where the OS
            // recycles our reserved port before the server binds it.
        } catch {
            bootstrapPipe.fileHandleForReading.closeFile()
            bootstrapPipe.fileHandleForWriting.closeFile()
            logger.error("Failed to spawn t3code sidecar: \(error.localizedDescription)")
            port = nil
            closeSidecarLogHandle()
            return
        }

        // Keep polling the port file for confirmation and timeout diagnostics.
        startPortPolling()
    }

    /// Gracefully shut down the sidecar process.
    func shutdown() {
        isShuttingDown = true
        stopPortPolling()

        guard let proc = process, proc.isRunning else {
            process = nil
            closeSidecarLogHandle()
            return
        }

        logger.info("Shutting down t3code sidecar (PID \(proc.processIdentifier))")
        proc.terminate()  // SIGTERM

        // Capture proc locally — process is cleared below, so the delayed
        // closure must hold its own strong reference to send SIGKILL.
        let capturedProc = proc
        let capturedPID = proc.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard capturedProc.isRunning else { return }
            self?.logger.warning("Force killing t3code sidecar (PID \(capturedPID))")
            kill(capturedPID, SIGKILL)
        }

        process = nil
        port = nil
        hasPublishedPort = false
        closeSidecarLogHandle()

        // Clean up port file
        try? FileManager.default.removeItem(atPath: portFilePath)
    }

    /// Restart the sidecar (used after crash detection). Deduplicates.
    func restart() {
        guard !isRestartPending else {
            logger.info("Restart already pending, skipping duplicate")
            return
        }
        isRestartPending = true
        shutdown()
        // Delay to let port be released and SQLite locks clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.start()
        }
    }

    // MARK: - Port File Polling

    /// Poll the HTTP endpoint until the t3code server is ready.
    /// Falls back to reading a server.port file for older server versions.
    private func startPortPolling() {
        stopPortPolling()

        guard let selectedPort = port else {
            logger.error("No port assigned — cannot poll for readiness")
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1.0)

        var attempts = 0
        let maxAttempts = 30  // Give up after 30 seconds

        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            attempts += 1

            // Probe the HTTP endpoint — the server responds once it is ready.
            let url = URL(string: "http://127.0.0.1:\(selectedPort)/")!
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
            request.httpMethod = "HEAD"
            let semaphore = DispatchSemaphore(value: 0)
            var reachable = false
            let task = URLSession.shared.dataTask(with: request) { _, response, _ in
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    reachable = true
                }
                semaphore.signal()
            }
            task.resume()
            semaphore.wait()

            if reachable {
                self.logger.info("t3code server ready on port \(selectedPort)")
                self.handlePortDetected(selectedPort)
                return
            }

            // Fallback: check for port file (older server versions)
            if let portStr = try? String(contentsOfFile: self.portFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let port = Int(portStr), port > 0 {
                self.logger.info("Detected t3code port \(port) from port file at \(self.portFilePath)")
                self.handlePortDetected(port)
                return
            }

            // Check if process is still alive
            if let proc = self.process, !proc.isRunning {
                self.logger.error("t3code process died while waiting for readiness")
                self.stopPortPolling()
                return
            }

            if attempts >= maxAttempts {
                self.logger.error("Timed out waiting for t3code readiness after \(maxAttempts)s on port \(selectedPort)")
                self.stopPortPolling()
            }
        }

        timer.resume()
        self.portPollTimer = timer
    }

    private func stopPortPolling() {
        portPollTimer?.cancel()
        portPollTimer = nil
    }

    private func handlePortDetected(_ port: Int) {
        self.stopPortPolling()
        publishPort(port)
    }

    private func publishPort(_ port: Int) {
        let isNewPort = self.port != port
        self.port = port
        // Publish if we haven't yet, or if the confirmed port differs
        // from the initially reserved port (TOCTOU correction).
        guard !hasPublishedPort || isNewPort else { return }
        hasPublishedPort = true
        DispatchQueue.main.async { [weak self] in
            self?.onReady?(port)
        }
    }

    private func writeBootstrapEnvelope(to handle: FileHandle) {
        let payload: [String: Any] = [
            "desktopBootstrapToken": desktopBootstrapToken
        ]
        defer {
            try? handle.close()
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            logger.error("Failed to encode t3code bootstrap envelope")
            return
        }

        do {
            try handle.write(contentsOf: data)
        } catch {
            logger.error("Failed to write t3code bootstrap envelope: \(error.localizedDescription)")
        }
    }

    private func openSidecarLogHandle() -> FileHandle? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: sidecarLogPath) {
            fm.createFile(atPath: sidecarLogPath, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: sidecarLogPath)) else {
            self.logger.error("Failed to open t3code sidecar log at \(self.sidecarLogPath)")
            return nil
        }

        do {
            try handle.seekToEnd()
            let banner = "\n=== \(ISO8601DateFormatter().string(from: Date())) sidecar start \(projectDirectory.path) ===\n"
            try handle.write(contentsOf: Data(banner.utf8))
            return handle
        } catch {
            logger.error("Failed to initialize t3code sidecar log: \(error.localizedDescription)")
            try? handle.close()
            return nil
        }
    }

    private func closeSidecarLogHandle() {
        try? sidecarLogHandle?.close()
        sidecarLogHandle = nil
    }

    private func reserveAvailablePort() -> Int? {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return nil }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: in_addr_t(0))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }

        guard bindResult == 0 else { return nil }

        var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(socketFD, sockaddrPointer, &length)
            }
        }

        guard nameResult == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    // Port detection is done via port file polling only (see startPortPolling).
    // The t3code server writes {stateDir}/server.port on startup.

    // MARK: - Server Binary Resolution

    /// Find the t3code server binary.
    ///
    /// Resolution order (4 stages):
    /// 1. Environment variables (T3CODE_SERVER_PATH or CMUXTERM_REPO_ROOT)
    /// 2. Walk up from project directory to find t3code sibling
    /// 3. Common global install paths (npm, Homebrew)
    /// 4. App bundle resources (self-contained distribution)
    private func resolveServerBinary() -> String? {
        let fm = FileManager.default

        // 1. Environment variables (set by install script / LSEnvironment)
        if let t3codePath = ProcessInfo.processInfo.environment["T3CODE_SERVER_PATH"],
           fm.fileExists(atPath: t3codePath) {
            return t3codePath
        }
        if let repoRoot = ProcessInfo.processInfo.environment["CMUXTERM_REPO_ROOT"] {
            let candidate = (repoRoot as NSString).appendingPathComponent("t3code/apps/server/dist/index.mjs")
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
        }

        // 2. Walk up from project directory looking for t3code sibling.
        // Stop at the project's git root to avoid escaping the repository
        // and matching an unrelated standalone t3code installation.
        // Submodules use a .git *file* — only real .git directories are boundaries.
        var searchDir = projectDirectory.path
        for _ in 0..<6 {
            let candidate = (searchDir as NSString).appendingPathComponent("t3code/apps/server/dist/index.mjs")
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
            let gitMarker = (searchDir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: gitMarker, isDirectory: &isDir), isDir.boolValue {
                break
            }
            let parent = (searchDir as NSString).deletingLastPathComponent
            if parent == searchDir { break }
            searchDir = parent
        }

        // 3. Common global install paths
        let globalPaths = [
            "/usr/local/lib/node_modules/t3/dist/index.mjs",
            "/opt/homebrew/lib/node_modules/t3/dist/index.mjs",
        ]
        for path in globalPaths {
            if fm.fileExists(atPath: path) {
                return path
            }
        }

        // 4. App bundle resources (last resort)
        if let resourceURL = Bundle.main.resourceURL {
            let bundledPath = resourceURL.appendingPathComponent("t3code-server/index.mjs").path
            if fm.fileExists(atPath: bundledPath) {
                return bundledPath
            }
        }

        logger.warning("t3code server binary not found. Set T3CODE_SERVER_PATH env var.")
        return nil
    }
}
