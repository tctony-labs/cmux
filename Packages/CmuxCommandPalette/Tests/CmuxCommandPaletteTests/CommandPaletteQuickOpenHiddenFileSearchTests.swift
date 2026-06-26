import Foundation
import Testing

@testable import CmuxCommandPalette

@Suite struct CommandPaletteQuickOpenHiddenFileSearchTests {
    @Test func crossDirectoryDotfileQueryMatchesRootDotfile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-quick-open-dotfile-cross-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(".xcode-version")
        try "16.4\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let results = await CommandPaletteQuickOpenFileSearch.searchCrossDirectory(
            query: ".xcode",
            rootDir: root.path
        )

        let expectedPath = file.resolvingSymlinksInPath().path
        #expect(
            results.contains { $0.url.resolvingSymlinksInPath().path == expectedPath },
            "Expected .xcode to match .xcode-version, got \(results.map { $0.url.path })"
        )
    }
}
