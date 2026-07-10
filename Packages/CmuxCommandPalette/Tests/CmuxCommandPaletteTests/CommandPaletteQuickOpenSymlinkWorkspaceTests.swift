import Foundation
import Testing

@testable import CmuxCommandPalette

@Suite
struct CommandPaletteQuickOpenSymlinkWorkspaceTests {
    @Test
    func listFilesRetainsSymlinkWorkspaceRoot() throws {
        let fixture = try SymlinkWorkspaceFixture()
        defer { fixture.cleanup() }

        let results = CommandPaletteQuickOpenFileSearch.listFiles(
            inDirectory: fixture.symlinkRoot.path,
            maxCount: 100
        )

        let expectedPath = fixture.symlinkRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .path
        #expect(results.contains { $0.path == expectedPath })
    }

    @Test
    func crossDirectorySearchRetainsSymlinkWorkspaceRoot() async throws {
        let fixture = try SymlinkWorkspaceFixture()
        defer { fixture.cleanup() }

        let results = await CommandPaletteQuickOpenFileSearch.searchCrossDirectory(
            query: "ContentView",
            rootDir: fixture.symlinkRoot.path
        )

        let expectedPath = fixture.symlinkRoot
            .appendingPathComponent("Sources/ContentView.swift")
            .path
        #expect(results.contains { $0.url.path == expectedPath })
    }

    @Test
    func displayPathMapsResolvedResultsBackToSymlinkWorkspaceRoot() throws {
        let fixture = try SymlinkWorkspaceFixture()
        defer { fixture.cleanup() }

        #expect(
            CommandPaletteQuickOpenFileSearch.displayPath(
                url: fixture.contentView.resolvingSymlinksInPath(),
                rootDir: fixture.symlinkRoot.path
            ) == "Sources/ContentView.swift"
        )
        #expect(
            CommandPaletteQuickOpenFileSearch.pathForDirectory(
                fixture.sourcesDirectory.resolvingSymlinksInPath(),
                rootDir: fixture.symlinkRoot.path
            ) == "./Sources/"
        )
        #expect(
            CommandPaletteQuickOpenFileSearch.pathForDirectory(
                fixture.realRoot,
                rootDir: fixture.symlinkRoot.path
            ) == "./"
        )
    }
}
