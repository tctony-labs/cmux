import Foundation
import Testing

@testable import CmuxCommandPalette

@Suite("Quick Open parent-relative paths")
struct CommandPaletteQuickOpenParentPathTests {
    @Test("Parent-relative queries use path mode from the workspace root")
    func parentRelativeQueryUsesPathMode() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-quick-open-parent-\(UUID().uuidString)", isDirectory: true)
        let workspace = parent.appendingPathComponent("Workspace", isDirectory: true)
        let sibling = parent.appendingPathComponent("Sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let (parentDirectory, parentSearchTerm, parentIsPathMode) = CommandPaletteQuickOpenFileSearch.resolve(
            matchingQuery: "../",
            workspaceRoot: workspace.path
        )
        let (directory, searchTerm, isPathMode) = CommandPaletteQuickOpenFileSearch.resolve(
            matchingQuery: "../Sibling/needle",
            workspaceRoot: workspace.path
        )

        #expect(parentDirectory == parent.path)
        #expect(parentSearchTerm == "")
        #expect(parentIsPathMode)
        #expect(URL(fileURLWithPath: directory).standardizedFileURL.path == sibling.path)
        #expect(searchTerm == "needle")
        #expect(isPathMode)
    }

    @Test("Parent-relative directory queries have no filename search term")
    func parentRelativeDirectoryHasNoSearchTerm() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-quick-open-parent-term-\(UUID().uuidString)", isDirectory: true)
        let workspace = parent.appendingPathComponent("Workspace", isDirectory: true)
        let sibling = parent.appendingPathComponent("Sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        #expect(
            CommandPaletteQuickOpenFileSearch.matchingTerm(
                "../Sibling",
                workspaceRoot: workspace.path
            ) == ""
        )
    }

    @Test("Parent-relative path mode copies an absolute result path")
    func parentRelativePathCopiesAbsolutePath() {
        let workspaceRoot = "/tmp/cmux-parent/Workspace"
        let url = URL(fileURLWithPath: workspaceRoot + "/Sources/needle.txt")

        #expect(
            CommandPaletteQuickOpenFileSearch.pathForCopying(
                url,
                workspaceRoot: workspaceRoot,
                matchingQuery: "../Workspace/Sources/needle"
            ) == url.path
        )
    }
}
