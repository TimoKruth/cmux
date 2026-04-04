import Foundation

// MARK: - T3Code Project & Task Management

extension TabManager {

    // MARK: - Project Queries

    /// Find the project that contains a given workspace.
    func project(for workspaceId: UUID) -> Project? {
        projects.first { $0.workspaceIds.contains(workspaceId) }
    }

    /// All workspace IDs that belong to any project.
    var projectOwnedWorkspaceIds: Set<UUID> {
        Set(projects.flatMap(\.workspaceIds))
    }

    /// Workspaces not owned by any project (standalone).
    var standaloneWorkspaces: [Workspace] {
        let owned = projectOwnedWorkspaceIds
        return tabs.filter { !owned.contains($0.id) }
    }

    // MARK: - Project Mutations

    /// Create a new project with the given name and directory, then create its first task.
    @discardableResult
    func addProject(name: String, directory: String) -> Project {
        let project = Project(name: name, directory: directory)
        projects.append(project)
        // Create the first task in the project
        addTask(to: project, name: String(
            localized: "project.firstTask.defaultName",
            defaultValue: "Task 1"
        ))
        return project
    }

    /// Delete a project and close all its task workspaces.
    func deleteProject(_ project: Project) {
        // Close all task workspaces belonging to this project
        let workspaceIdsToClose = project.workspaceIds
        for wsId in workspaceIdsToClose {
            if let workspace = tabs.first(where: { $0.id == wsId }) {
                // Only close if there are other workspaces remaining
                if tabs.count > 1 {
                    closeWorkspace(workspace)
                }
            }
        }
        projects.removeAll { $0.id == project.id }
    }

    /// Create a new task (workspace) within a project.
    /// The workspace starts with a chat panel only (no terminal).
    @discardableResult
    func addTask(to project: Project, name: String? = nil) -> Workspace {
        let workspace = addWorkspace(
            workingDirectory: project.directory,
            select: true,
            autoWelcomeIfNeeded: false,
            skipInitialTerminal: true
        )
        let resolvedName = name ?? String(
            localized: "project.newTask.defaultName",
            defaultValue: "Task \(project.workspaceIds.count + 1)"
        )
        workspace.setCustomTitle(resolvedName)
        project.workspaceIds.append(workspace.id)

        // Create a chat panel as the sole content for this task workspace.
        // Since we skipped the initial terminal, the workspace is empty — create
        // a writer which will also create the chat panel.
        if workspace.writers.isEmpty {
            workspace.createWriter(name: workspace.customTitle ?? project.name)
        }

        // Start the t3code sidecar for this new task workspace.
        AppDelegate.shared?.startSidecarForWorkspace(workspace)

        return workspace
    }

    /// Remove a task from its project (and close the workspace).
    func removeTask(workspaceId: UUID, from project: Project) {
        project.workspaceIds.removeAll { $0 == workspaceId }
        if let workspace = tabs.first(where: { $0.id == workspaceId }) {
            closeWorkspace(workspace)
        }
    }

    // MARK: - T3Code Sidecar Cleanup

    /// Clean up the t3code sidecar for a closing workspace.
    func cleanupT3CodeSidecar(for workspace: Workspace) {
        workspace.t3codeSidecarManager?.shutdown()
        workspace.t3codeSidecarManager = nil
        AppDelegate.shared?.removeSidecarTracking(for: workspace.id)
    }

    /// Remove a workspace from any project that owns it.
    func removeWorkspaceFromProjects(_ workspace: Workspace) {
        for project in projects {
            project.workspaceIds.removeAll { $0 == workspace.id }
        }
    }

    // MARK: - Session Restore Helpers

    /// Ensure each writer across all workspaces has a unique thread ID.
    func normalizeChatThreadAssignments() {
        var usedThreadIds = Set<String>()

        for workspace in tabs {
            for writer in workspace.writers {
                let currentThreadId = ChatPanel.normalizedThreadId(writer.t3codeThreadId)
                var resolvedThreadId: String

                if let currentThreadId, !usedThreadIds.contains(currentThreadId) {
                    resolvedThreadId = currentThreadId
                } else {
                    resolvedThreadId = Workspace.defaultDraftThreadId(for: writer.id)
                    while usedThreadIds.contains(resolvedThreadId) {
                        resolvedThreadId = UUID().uuidString.lowercased()
                    }
                }

                usedThreadIds.insert(resolvedThreadId)
                guard writer.t3codeThreadId != resolvedThreadId else { continue }
                writer.t3codeThreadId = resolvedThreadId

                if let chatPanelId = writer.chatPanelId,
                   let chatPanel = workspace.panels[chatPanelId] as? ChatPanel {
                    chatPanel.setThreadId(resolvedThreadId)
                }
            }
        }
    }

    /// Re-attach legacy task workspaces (created before projects were introduced) to their projects.
    func reattachLegacyProjectTaskWorkspaces(
        projects: inout [Project],
        workspaces: [Workspace],
        legacyWorkspaceIds: Set<UUID>
    ) {
        guard !projects.isEmpty, !legacyWorkspaceIds.isEmpty else { return }

        var claimedWorkspaceIds = Set(projects.flatMap(\.workspaceIds))

        for project in projects {
            let normalizedProjectDirectory = normalizedWorkingDirectory(project.directory)
            let matchingWorkspaceIds = workspaces.compactMap { workspace -> UUID? in
                guard legacyWorkspaceIds.contains(workspace.id) else { return nil }
                guard !claimedWorkspaceIds.contains(workspace.id) else { return nil }
                guard isLegacyProjectTaskWorkspace(workspace) else { return nil }
                guard normalizedWorkingDirectory(workspace.currentDirectory) == normalizedProjectDirectory else { return nil }
                return workspace.id
            }

            guard !matchingWorkspaceIds.isEmpty else { continue }
            project.workspaceIds.append(contentsOf: matchingWorkspaceIds)
            claimedWorkspaceIds.formUnion(matchingWorkspaceIds)
        }
    }

    func isLegacyProjectTaskWorkspace(_ workspace: Workspace) -> Bool {
        guard !workspace.writers.isEmpty else { return false }
        guard !workspace.panels.values.contains(where: { $0 is TerminalPanel }) else { return false }
        return workspace.panels.values.contains(where: { $0 is ChatPanel })
    }
}
