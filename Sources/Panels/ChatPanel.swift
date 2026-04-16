import AppKit
import Combine
import WebKit
import os

/// A panel that displays the t3code chat UI in a CmuxWebView.
/// Each ChatPanel corresponds to one writer/task within a workspace.
@MainActor
final class ChatPanel: NSObject, Panel, ObservableObject, WKScriptMessageHandler {

    private static let threadSyncMessageHandlerName = "cmuxThreadSync"
    private static let diagnosticsMessageHandlerName = "cmuxDiagnostics"
    private static let reservedEmbeddedThreadIDs: Set<String> = ["_chat", "settings"]
    private static let threadIDPathAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return allowed
    }()

    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "ChatPanel")
    private let startupTimeoutSeconds: TimeInterval = 45
    private let readinessPollIntervalNanoseconds: UInt64 = 500_000_000

    let id: UUID
    let panelType: PanelType = .chat

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// The writer's t3code thread ID (set after the first conversation is created).
    @Published var t3codeThreadId: String?

    /// The t3code sidecar server port for this workspace.
    private(set) var serverPort: Int?

    /// The workspace project directory passed to the embedded URL so t3code
    /// can bind the thread to the correct project.
    private let projectCwd: String?

    /// Stable auth bootstrap token surfaced to the embedded web app.
    private var localBootstrapToken: String?

    /// The web view displaying t3code's React UI.
    private(set) var webView: CmuxWebView

    /// Callback fired when the embedded web app reports its active thread ID.
    var onThreadIdChange: ((String?) -> Void)?

    /// Polls the target URL until the sidecar actually starts accepting requests.
    private var serverReadinessTask: Task<Void, Never>?

    /// Tracks whether the real t3code UI has been loaded yet.
    private var hasLoadedServerUI = false

    /// Display title shown in the tab bar.
    @Published private(set) var displayTitle: String = String(
        localized: "chat.newChat",
        defaultValue: "Chat"
    )

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "bubble.left.and.text.bubble.right" }

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    // MARK: - Init

    init(
        workspaceId: UUID,
        threadId: String? = nil,
        serverPort: Int? = nil,
        projectCwd: String? = nil,
        localBootstrapToken: String? = nil
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.t3codeThreadId = Self.normalizedThreadId(threadId)
        self.serverPort = serverPort
        self.projectCwd = projectCwd
        self.localBootstrapToken = localBootstrapToken

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        Self.installDesktopBridgeUserScript(
            on: config.userContentController,
            bootstrapToken: localBootstrapToken
        )

        let webView = CmuxWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = false
        self.webView = webView
        super.init()
        config.userContentController.add(self, name: Self.threadSyncMessageHandlerName)
        config.userContentController.add(self, name: Self.diagnosticsMessageHandlerName)

        if let port = serverPort {
            waitForServerAndLoad(port: port)
        } else {
            loadWaitingPage()
        }
    }

    // MARK: - Panel protocol

    func focus() {
        guard let window = webView.window, !webView.isHiddenOrHasHiddenAncestor else { return }

        if webView.window?.firstResponder === webView {
            return
        }
        window.makeFirstResponder(webView)
    }

    func unfocus() {
        guard let window = webView.window else { return }
        if window.firstResponder === webView {
            window.makeFirstResponder(nil)
        }
    }

    func close() {
        unfocus()
        serverReadinessTask?.cancel()
        serverReadinessTask = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.threadSyncMessageHandlerName
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.diagnosticsMessageHandlerName
        )
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken &+= 1
    }

    // MARK: - t3code UI loading

    /// Load or reload the t3code UI with the given server port.
    func loadT3CodeUI(port: Int) {
        self.serverPort = port
        waitForServerAndLoad(port: port)
    }

    func setLocalBootstrapToken(_ token: String?) {
        guard localBootstrapToken != token else { return }
        localBootstrapToken = token
        Self.installDesktopBridgeUserScript(
            on: webView.configuration.userContentController,
            bootstrapToken: token
        )
    }

    private func loadLiveT3CodeUI(port: Int) {
        self.serverPort = port
        self.hasLoadedServerUI = true
        self.serverReadinessTask?.cancel()
        self.serverReadinessTask = nil

        let normalizedThreadId = Self.normalizedThreadId(t3codeThreadId)
        t3codeThreadId = normalizedThreadId

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/"

        // Load the pathless chat root and let the web app bootstrap the correct
        // embedded thread/workspace route from query params.
        var queryItems = [URLQueryItem(name: "embedded", value: "1")]
        if let cwd = projectCwd {
            queryItems.append(URLQueryItem(name: "projectCwd", value: cwd))
        }
        if let threadId = normalizedThreadId,
           !threadId.isEmpty {
            queryItems.append(URLQueryItem(name: "threadId", value: threadId))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            logger.error("Invalid t3code URL for port \(port)")
            loadErrorPage(message: String(
                localized: "chat.error.invalidURL",
                defaultValue: "Failed to construct t3code URL."
            ))
            return
        }

        logger.info("Loading t3code UI: \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    /// Update the thread ID (called when the user starts or switches conversations).
    func setThreadId(_ threadId: String?) {
        let normalizedThreadId = Self.normalizedThreadId(threadId)
        guard self.t3codeThreadId != normalizedThreadId else { return }
        self.t3codeThreadId = normalizedThreadId
        if let port = serverPort, hasLoadedServerUI {
            loadLiveT3CodeUI(port: port)
        }
    }

    /// Reload the web view (used after sidecar restart).
    func reload() {
        if let port = serverPort {
            waitForServerAndLoad(port: port)
        } else {
            loadWaitingPage()
        }
    }

    private func waitForServerAndLoad(port: Int) {
        serverPort = port
        hasLoadedServerUI = false
        serverReadinessTask?.cancel()
        loadWaitingPage()
        let timeoutSeconds = startupTimeoutSeconds
        let pollInterval = readinessPollIntervalNanoseconds

        serverReadinessTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(timeoutSeconds)

            while !Task.isCancelled {
                if await Self.isServerReachable(port: port) {
                    await MainActor.run { [weak self] in
                        guard let self, self.serverPort == port else { return }
                        self.loadLiveT3CodeUI(port: port)
                    }
                    return
                }

                if Date() >= deadline {
                    await MainActor.run { [weak self] in
                        guard let self, self.serverPort == port else { return }
                        self.loadErrorPage(message: String(
                            localized: "chat.error.timeout",
                            defaultValue: "t3code did not respond within 45 seconds."
                        ))
                    }
                    return
                }

                try? await Task.sleep(nanoseconds: pollInterval)
            }
        }
    }

    nonisolated private static func isServerReachable(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return (200..<600).contains(httpResponse.statusCode)
            }
            return true
        } catch {
            return false
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == Self.diagnosticsMessageHandlerName {
            logger.error("Embedded t3code diagnostics: \(String(describing: message.body), privacy: .public)")
            return
        }

        guard message.name == Self.threadSyncMessageHandlerName else { return }

        let rawThreadId: String
        if let payload = message.body as? [String: Any], let payloadThreadId = payload["threadId"] as? String {
            rawThreadId = payloadThreadId
        } else if let bodyThreadId = message.body as? String {
            rawThreadId = bodyThreadId
        } else {
            return
        }

        let trimmedThreadId = rawThreadId.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextThreadId = Self.normalizedThreadId(trimmedThreadId)
        if !trimmedThreadId.isEmpty, nextThreadId == nil {
            logger.warning("Ignoring invalid embedded thread ID: \(trimmedThreadId, privacy: .public)")
            return
        }

        guard t3codeThreadId != nextThreadId else { return }
        t3codeThreadId = nextThreadId
        onThreadIdChange?(nextThreadId)
    }

    static func normalizedThreadId(_ rawThreadId: String?) -> String? {
        guard let rawThreadId else { return nil }
        let trimmed = rawThreadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("_") else { return nil }
        guard !reservedEmbeddedThreadIDs.contains(trimmed.lowercased()) else { return nil }
        guard !trimmed.contains("/") && !trimmed.contains("?") && !trimmed.contains("#") else { return nil }
        return trimmed
    }

    private static func installDesktopBridgeUserScript(
        on userContentController: WKUserContentController,
        bootstrapToken: String?
    ) {
        userContentController.removeAllUserScripts()
        guard let bootstrapToken, !bootstrapToken.isEmpty else { return }

        let script = WKUserScript(
            source: desktopBridgeUserScript(bootstrapToken: bootstrapToken),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(script)
    }

    private static func desktopBridgeUserScript(bootstrapToken: String) -> String {
        let tokenLiteral = javaScriptStringLiteral(bootstrapToken)
        return """
        (() => {
          const bootstrapToken = \(tokenLiteral);
          const buildBootstrap = () => {
            const origin = window.location.origin;
            const wsBaseUrl = origin.replace(/^http/i, (protocol) =>
              protocol.toLowerCase() === "https" ? "wss" : "ws"
            );
            return {
              label: "Local environment",
              httpBaseUrl: origin,
              wsBaseUrl,
              bootstrapToken
            };
          };
          const existing =
            window.desktopBridge && typeof window.desktopBridge === "object"
              ? window.desktopBridge
              : {};
          const diagnostics = window.webkit?.messageHandlers?.\(diagnosticsMessageHandlerName);
          const report = (kind, detail) => {
            try {
              diagnostics?.postMessage({ kind, detail });
            } catch {}
          };
          const wrapConsole = (level) => {
            const original = console[level];
            if (typeof original !== "function") {
              return;
            }
            console[level] = function (...args) {
              try {
                report("console-" + level, {
                  args: args.map((value) => {
                    if (typeof value === "string") {
                      return value;
                    }
                    if (value instanceof Error) {
                      return value.stack || value.message;
                    }
                    try {
                      return JSON.stringify(value);
                    } catch {
                      return String(value);
                    }
                  }),
                });
              } catch {}
              return original.apply(this, args);
            };
          };
          wrapConsole("error");
          wrapConsole("warn");
          window.addEventListener("error", (event) => {
            report("error", {
              message: event.message,
              filename: event.filename,
              lineno: event.lineno,
              colno: event.colno,
            });
          });
          window.addEventListener("unhandledrejection", (event) => {
            const reason =
              typeof event.reason === "string"
                ? event.reason
                : event.reason && typeof event.reason === "object" && "message" in event.reason
                  ? event.reason.message
                  : String(event.reason);
            report("unhandledrejection", { reason });
          });
          window.addEventListener("load", () => {
            setTimeout(() => {
              if (document.getElementById("boot-shell")) {
                report("boot-shell-stuck", {
                  href: window.location.href,
                  hash: window.location.hash,
                  readyState: document.readyState,
                  title: document.title,
                });
              }
            }, 4000);
          });
          window.__CMUX_EMBEDDED__ = true;
          window.desktopBridge = Object.assign({}, existing, {
            getLocalEnvironmentBootstrap: () => buildBootstrap()
          });
        })();
        """
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2 else {
            return "\"\""
        }
        return String(encoded.dropFirst().dropLast())
    }

    // MARK: - Placeholder pages

    /// Show a waiting page when no sidecar port is available yet.
    private func loadWaitingPage() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                body {
                    margin: 0;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    height: 100vh;
                    background: #1a1a2e;
                    color: #a0a0b8;
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    font-size: 14px;
                }
                .container {
                    text-align: center;
                    padding: 32px;
                }
                .spinner {
                    width: 24px;
                    height: 24px;
                    border: 2px solid #333;
                    border-top-color: #7c7cf0;
                    border-radius: 50%;
                    animation: spin 0.8s linear infinite;
                    margin: 0 auto 16px;
                }
                @keyframes spin {
                    to { transform: rotate(360deg); }
                }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="spinner"></div>
                <div>Starting t3code server&hellip;</div>
            </div>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    /// Show an error page with a message.
    private func loadErrorPage(message: String) {
        let escapedMessage = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                body {
                    margin: 0;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    height: 100vh;
                    background: #1a1a2e;
                    color: #a0a0b8;
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    font-size: 14px;
                }
                .container {
                    text-align: center;
                    padding: 32px;
                }
                .icon {
                    font-size: 32px;
                    margin-bottom: 12px;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="icon">&#x26A0;</div>
                <div>\(escapedMessage)</div>
            </div>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}
