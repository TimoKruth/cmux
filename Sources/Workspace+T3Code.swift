import Foundation

// MARK: - T3Code Writer Management

extension Workspace {

    static func defaultDraftThreadId(for writerId: UUID) -> String {
        writerId.uuidString.lowercased()
    }

    /// Create a new writer with a default name and a chat panel.
    @discardableResult
    func createWriter(name: String? = nil) -> Writer {
        let writerName = name ?? "New task \(writers.count + 1)"
        let writer = Writer(name: writerName)
        writer.t3codeThreadId = Self.defaultDraftThreadId(for: writer.id)
        writers.append(writer)
        activeWriterId = writer.id

        // Create a chat panel for this writer
        if let rootPaneId = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first {
            if let chatPanel = newChatSurface(
                inPane: rootPaneId,
                threadId: writer.t3codeThreadId,
                serverPort: t3codeSidecarManager?.port
            ) {
                writer.chatPanelId = chatPanel.id
            }
        }

        return writer
    }

    /// Select a writer and focus its chat panel.
    func selectWriter(_ writerId: UUID) {
        activeWriterId = writerId
        if let writer = writers.first(where: { $0.id == writerId }),
           let chatPanelId = writer.chatPanelId,
           let tabId = surfaceIdFromPanelId(chatPanelId) {
            bonsplitController.selectTab(tabId)
        }
    }

    /// Delete a writer and clean up its resources.
    func deleteWriter(_ writer: Writer) {
        // Close the writer's chat panel before removing
        if let chatPanelId = writer.chatPanelId {
            _ = closePanel(chatPanelId, force: true)
        }

        writers.removeAll { $0.id == writer.id }
        if activeWriterId == writer.id {
            activeWriterId = writers.first?.id
            // Focus the new active writer's chat panel
            if let newActiveId = activeWriterId {
                selectWriter(newActiveId)
            }
        }
    }

    /// Rename a writer.
    func renameWriter(_ writer: Writer, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        writer.name = trimmed

        // Project tasks currently model a single writer per workspace.
        // Keep the workspace title path in sync so sidebar rows, workspace tabs,
        // and restored task names all stay aligned.
        if writers.count == 1, writers.first?.id == writer.id {
            setCustomTitle(trimmed)
        }
    }

    func updateWriterThreadId(_ threadId: String?, forChatPanelId chatPanelId: UUID) {
        guard let writer = writers.first(where: { $0.chatPanelId == chatPanelId }) else { return }
        let normalizedThreadId = ChatPanel.normalizedThreadId(threadId)
        guard writer.t3codeThreadId != normalizedThreadId else { return }
        writer.t3codeThreadId = normalizedThreadId
    }

    /// Move a writer from one index to another (reorder).
    func moveWriter(from source: IndexSet, to destination: Int) {
        writers.move(fromOffsets: source, toOffset: destination)
    }
}
