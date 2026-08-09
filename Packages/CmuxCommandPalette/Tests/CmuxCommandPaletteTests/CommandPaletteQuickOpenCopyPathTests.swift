import Foundation
import Testing

@testable import CmuxCommandPalette

@Suite("Quick Open copied paths")
struct CommandPaletteQuickOpenCopyPathTests {
    @Test("Path mode copies the complete path")
    func pathModeCopiesCompletePath() {
        let workspaceRoot = "/tmp/cmux-workspace"
        let url = URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent("Sources/ContentView.swift")

        #expect(
            CommandPaletteQuickOpenFileSearch.pathForCopying(
                url,
                workspaceRoot: workspaceRoot,
                matchingQuery: "./Sources/Content"
            ) == "/tmp/cmux-workspace/Sources/ContentView.swift"
        )
    }

    @Test("Cross-directory search copies a workspace-relative path")
    func crossDirectoryCopiesWorkspaceRelativePath() {
        let workspaceRoot = "/tmp/cmux-workspace"
        let url = URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent("Sources/ContentView.swift")

        #expect(
            CommandPaletteQuickOpenFileSearch.pathForCopying(
                url,
                workspaceRoot: workspaceRoot,
                matchingQuery: "Content"
            ) == "Sources/ContentView.swift"
        )
    }

    @Test("An empty query copies a workspace-relative path", arguments: ["", "   "])
    func emptyQueryCopiesWorkspaceRelativePath(matchingQuery: String) {
        let workspaceRoot = "/tmp/cmux-workspace"
        let url = URL(fileURLWithPath: workspaceRoot)
            .appendingPathComponent("Sources/ContentView.swift")

        #expect(
            CommandPaletteQuickOpenFileSearch.pathForCopying(
                url,
                workspaceRoot: workspaceRoot,
                matchingQuery: matchingQuery
            ) == "Sources/ContentView.swift"
        )
    }
}
