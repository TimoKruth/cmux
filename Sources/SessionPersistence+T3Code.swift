import Foundation

// MARK: - T3Code Session Snapshot Types

/// Snapshot of a single writer (task/topic) within a workspace.
struct SessionWriterSnapshot: Codable, Sendable {
    let id: UUID
    var name: String
    var t3codeThreadId: String?
    var chatPanelId: UUID?
    var layout: SessionWorkspaceLayoutSnapshot?
}

struct SessionProjectSnapshot: Codable, Sendable {
    var id: UUID
    var name: String
    var directory: String
    var workspaceIds: [UUID]
    var isExpanded: Bool
}
