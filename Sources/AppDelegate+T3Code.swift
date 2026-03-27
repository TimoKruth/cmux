import Foundation

// MARK: - T3Code Sidecar Management

extension AppDelegate {

    /// Start a t3code sidecar for the given workspace. Called from TabManager.addTask and session restore.
    func startSidecarForWorkspace(_ workspace: Workspace) {
        startT3CodeSidecar(for: workspace)
    }

    /// Clean up the sidecar tracking entry for a closed workspace.
    /// The actual shutdown is performed by TabManager.closeWorkspace via
    /// workspace.t3codeSidecarManager.shutdown().
    func removeSidecarTracking(for workspaceId: UUID) {
        t3codeSidecarManagers.removeValue(forKey: workspaceId)
    }

    /// Shut down all active t3code sidecars. Called during app termination.
    func shutdownAllT3CodeSidecars() {
        for (_, manager) in t3codeSidecarManagers {
            manager.shutdown()
        }
        t3codeSidecarManagers.removeAll()
    }

    /// Start t3code sidecars for all workspaces in the given tab manager.
    /// Called after session restore to re-attach sidecars.
    func startT3CodeSidecars(in tabManager: TabManager) {
        for workspace in tabManager.tabs {
            startT3CodeSidecar(for: workspace)
        }
    }

    /// Start a t3code sidecar for the given workspace.
    private func startT3CodeSidecar(for workspace: Workspace) {
        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { return }
        let directoryURL = URL(fileURLWithPath: directory)

        let manager = T3CodeSidecarManager(projectDirectory: directoryURL)

        manager.onReady = { [weak workspace] port in
            workspace?.notifyChatPanelsOfPort(port)
        }

        manager.onCrash = { [weak self, weak workspace] in
            guard let self = self, let workspace = workspace else { return }
            self.t3codeSidecarManagers[workspace.id]?.restart()
        }

        t3codeSidecarManagers[workspace.id] = manager
        workspace.t3codeSidecarManager = manager
        manager.start()
    }
}
