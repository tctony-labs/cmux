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

    @Test func crossDirectorySearchSkipsCommonHeavyDirectories() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-quick-open-skip-heavy-\(UUID().uuidString)", isDirectory: true)
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        let yarnDirectory = root.appendingPathComponent(".yarn", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: yarnDirectory, withIntermediateDirectories: true)
        let gitNeedle = gitDirectory.appendingPathComponent("needle.txt")
        let yarnNeedle = yarnDirectory.appendingPathComponent("needle.txt")
        try "needle".write(to: gitNeedle, atomically: true, encoding: .utf8)
        try "needle".write(to: yarnNeedle, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let gitDirectoryResults = await CommandPaletteQuickOpenFileSearch.searchCrossDirectory(
            query: ".git",
            rootDir: root.path
        )
        let nestedNeedleResults = await CommandPaletteQuickOpenFileSearch.searchCrossDirectory(
            query: "needle",
            rootDir: root.path
        )

        let gitPath = gitDirectory.resolvingSymlinksInPath().path
        let gitNeedlePath = gitNeedle.resolvingSymlinksInPath().path
        let yarnNeedlePath = yarnNeedle.resolvingSymlinksInPath().path
        #expect(
            !gitDirectoryResults.contains { $0.url.resolvingSymlinksInPath().path == gitPath },
            "Expected .git directory to be skipped, got \(gitDirectoryResults.map { $0.url.path })"
        )
        #expect(
            !nestedNeedleResults.contains { $0.url.resolvingSymlinksInPath().path == gitNeedlePath },
            "Expected .git contents to be skipped, got \(nestedNeedleResults.map { $0.url.path })"
        )
        #expect(
            !nestedNeedleResults.contains { $0.url.resolvingSymlinksInPath().path == yarnNeedlePath },
            "Expected .yarn contents to be skipped, got \(nestedNeedleResults.map { $0.url.path })"
        )
    }

    @Test func crossDirectorySearchKeepsVSCodeDirectorySearchable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-quick-open-vscode-\(UUID().uuidString)", isDirectory: true)
        let vscodeDirectory = root.appendingPathComponent(".vscode", isDirectory: true)
        try FileManager.default.createDirectory(at: vscodeDirectory, withIntermediateDirectories: true)
        let settingsFile = vscodeDirectory.appendingPathComponent("settings.json")
        try "{}\n".write(to: settingsFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let results = await CommandPaletteQuickOpenFileSearch.searchCrossDirectory(
            query: ".vscode/settings",
            rootDir: root.path
        )

        let expectedPath = settingsFile.resolvingSymlinksInPath().path
        #expect(
            results.contains { $0.url.resolvingSymlinksInPath().path == expectedPath },
            "Expected .vscode/settings to match settings.json, got \(results.map { $0.url.path })"
        )
    }
}
