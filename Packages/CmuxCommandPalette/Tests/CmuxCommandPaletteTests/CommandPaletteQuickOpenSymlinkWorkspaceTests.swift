import Foundation
import Testing

@testable import CmuxCommandPalette

@Suite
struct CommandPaletteQuickOpenSymlinkWorkspaceTests {
    @Test
    func listFilesFollowsSymlinkWorkspaceRoot() throws {
        let fixture = try SymlinkWorkspaceFixture()
        defer { fixture.cleanup() }

        let results = CommandPaletteQuickOpenFileSearch.listFiles(
            inDirectory: fixture.symlinkRoot.path,
            maxCount: 100
        )

        #expect(results.map(\.lastPathComponent).contains("Sources"))
    }

    @Test
    func crossDirectorySearchFollowsSymlinkWorkspaceRoot() async throws {
        let fixture = try SymlinkWorkspaceFixture()
        defer { fixture.cleanup() }

        let results = await CommandPaletteQuickOpenFileSearch.searchCrossDirectory(
            query: "ContentView",
            rootDir: fixture.symlinkRoot.path
        )

        let expectedPath = fixture.contentView.resolvingSymlinksInPath().path
        #expect(results.contains { $0.url.resolvingSymlinksInPath().path == expectedPath })
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
