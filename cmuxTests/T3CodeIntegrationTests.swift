import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Safety-net tests for the t3code integration layer.
/// Guards current behavior of Writer, Project, T3CodeSidecarManager,
/// and ChatPanel before any extraction/refactoring.
///
/// These tests verify observable runtime behavior through the public
/// interfaces of the integration models and managers.
final class T3CodeIntegrationTests: XCTestCase {

    // MARK: - Writer Model Tests

    @MainActor
    func testWriterInitDefaultValues() {
        let writer = Writer(name: "Test Task")
        XCTAssertFalse(writer.id.uuidString.isEmpty)
        XCTAssertEqual(writer.name, "Test Task")
        XCTAssertNil(writer.t3codeThreadId)
        XCTAssertFalse(writer.isActive)
        XCTAssertNil(writer.chatPanelId)
    }

    @MainActor
    func testWriterInitWithAllParameters() {
        let id = UUID()
        let chatId = UUID()
        let writer = Writer(
            id: id,
            name: "Feature Branch",
            t3codeThreadId: "thread-abc-123",
            chatPanelId: chatId
        )
        XCTAssertEqual(writer.id, id)
        XCTAssertEqual(writer.name, "Feature Branch")
        XCTAssertEqual(writer.t3codeThreadId, "thread-abc-123")
        XCTAssertFalse(writer.isActive)
        XCTAssertEqual(writer.chatPanelId, chatId)
    }

    @MainActor
    func testWriterCodableRoundTrip() throws {
        let original = Writer(
            name: "Codable Test",
            t3codeThreadId: "thread-xyz-789",
            chatPanelId: UUID()
        )
        original.isActive = true

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let restored = try decoder.decode(Writer.self, from: data)

        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.name, original.name)
        XCTAssertEqual(restored.t3codeThreadId, original.t3codeThreadId)
        XCTAssertEqual(restored.isActive, true)
        XCTAssertEqual(restored.chatPanelId, original.chatPanelId)
    }

    @MainActor
    func testWriterCodableHandlesMissingOptionals() throws {
        // Simulate a JSON payload without optional fields (backward compatibility)
        let json = """
        {
            "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
            "name": "Minimal Writer"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let writer = try decoder.decode(Writer.self, from: json)

        XCTAssertEqual(writer.name, "Minimal Writer")
        XCTAssertNil(writer.t3codeThreadId)
        XCTAssertFalse(writer.isActive)
        XCTAssertNil(writer.chatPanelId)
    }

    @MainActor
    func testWriterNameIsPublished() {
        let writer = Writer(name: "Original")
        var names: [String] = []

        let cancellable = writer.$name.sink { names.append($0) }
        writer.name = "Renamed"
        writer.name = "Renamed Again"

        XCTAssertEqual(names, ["Original", "Renamed", "Renamed Again"])
        cancellable.cancel()
    }

    @MainActor
    func testWriterThreadIdIsPublished() {
        let writer = Writer(name: "Test")
        var threadIds: [String?] = []

        let cancellable = writer.$t3codeThreadId.sink { threadIds.append($0) }
        writer.t3codeThreadId = "thread-1"
        writer.t3codeThreadId = "thread-2"
        writer.t3codeThreadId = nil

        XCTAssertEqual(threadIds.count, 4) // initial nil + 3 updates
        XCTAssertNil(threadIds[0])
        XCTAssertEqual(threadIds[1], "thread-1")
        XCTAssertEqual(threadIds[2], "thread-2")
        XCTAssertNil(threadIds[3])
        cancellable.cancel()
    }

    // MARK: - Project Model Tests

    @MainActor
    func testProjectInitDefaultValues() {
        let project = Project(name: "MyApp", directory: "/Users/test/MyApp")
        XCTAssertFalse(project.id.uuidString.isEmpty)
        XCTAssertEqual(project.name, "MyApp")
        XCTAssertEqual(project.directory, "/Users/test/MyApp")
        XCTAssertTrue(project.workspaceIds.isEmpty)
        XCTAssertTrue(project.isExpanded)
    }

    @MainActor
    func testProjectCodableRoundTrip() throws {
        let wsId1 = UUID()
        let wsId2 = UUID()
        let original = Project(name: "TestProject", directory: "/tmp/test")
        original.workspaceIds = [wsId1, wsId2]
        original.isExpanded = false

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let restored = try decoder.decode(Project.self, from: data)

        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.name, "TestProject")
        XCTAssertEqual(restored.directory, "/tmp/test")
        XCTAssertEqual(restored.workspaceIds, [wsId1, wsId2])
        XCTAssertFalse(restored.isExpanded)
    }

    @MainActor
    func testProjectCodableHandlesMissingOptionals() throws {
        // Simulate a JSON payload without workspaceIds/isExpanded (backward compatibility)
        let json = """
        {
            "id": "A621E1F8-C36C-495A-93FC-0C247A3E6E5F",
            "name": "Legacy Project",
            "directory": "/legacy/path"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let project = try decoder.decode(Project.self, from: json)

        XCTAssertEqual(project.name, "Legacy Project")
        XCTAssertEqual(project.directory, "/legacy/path")
        XCTAssertTrue(project.workspaceIds.isEmpty)
        XCTAssertTrue(project.isExpanded)
    }

    @MainActor
    func testProjectWorkspaceIdsIsPublished() {
        let project = Project(name: "Test", directory: "/tmp")
        var counts: [Int] = []

        let cancellable = project.$workspaceIds.sink { counts.append($0.count) }
        let ws1 = UUID()
        let ws2 = UUID()
        project.workspaceIds.append(ws1)
        project.workspaceIds.append(ws2)

        XCTAssertTrue(counts.count >= 2) // initial + at least 2 updates
        cancellable.cancel()
    }

    // MARK: - T3CodeSidecarManager Tests

    func testSidecarManagerInit() {
        let dir = URL(fileURLWithPath: "/tmp/test-workspace")
        let manager = T3CodeSidecarManager(projectDirectory: dir)

        XCTAssertEqual(manager.projectDirectory, dir)
        XCTAssertNil(manager.port)
    }

    func testSidecarManagerProjectDirectoryImmutable() {
        let dir = URL(fileURLWithPath: "/tmp/workspace-1")
        let manager = T3CodeSidecarManager(projectDirectory: dir)
        // projectDirectory is a let — this test verifies the value is preserved
        XCTAssertEqual(manager.projectDirectory.path, "/tmp/workspace-1")
    }

    func testSidecarManagerCallbacksCanBeSet() {
        let manager = T3CodeSidecarManager(
            projectDirectory: URL(fileURLWithPath: "/tmp/test")
        )

        var readyPort: Int?
        var crashCalled = false

        manager.onReady = { port in readyPort = port }
        manager.onCrash = { crashCalled = true }

        // Verify callbacks are set (not nil)
        XCTAssertNotNil(manager.onReady)
        XCTAssertNotNil(manager.onCrash)

        // Verify callbacks haven't been called yet
        XCTAssertNil(readyPort)
        XCTAssertFalse(crashCalled)
    }

    func testSidecarManagerShutdownWithoutStart() {
        // Shutdown on a never-started manager should not crash
        let manager = T3CodeSidecarManager(
            projectDirectory: URL(fileURLWithPath: "/tmp/test")
        )
        manager.shutdown()
        XCTAssertNil(manager.port)
    }

    func testSidecarManagerDoubleShutdownSafe() {
        let manager = T3CodeSidecarManager(
            projectDirectory: URL(fileURLWithPath: "/tmp/test")
        )
        manager.shutdown()
        manager.shutdown() // Should not crash
        XCTAssertNil(manager.port)
    }
}
