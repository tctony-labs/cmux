import Foundation
import Testing
@testable import CmuxCommandPalette

@Suite("Command palette candidate completion")
struct CommandPaletteCandidateCompletionTests {
    @Test("command and switcher candidates complete from their title")
    func titleFallbackCompletion() {
        let command = candidate(title: "Open Folder")

        #expect(command.completionQuery(for: .commands) == ">Open Folder")
        #expect(command.completionQuery(for: .switcher) == "Open Folder")
        #expect(command.completionQuery(for: .fileSearch) == nil)
    }

    @Test("explicit completion text overrides title fallback")
    func explicitCompletion() {
        let command = candidate(title: "Sources", completionText: "@./Sources/")

        #expect(command.completionQuery(for: .fileSearch) == "@./Sources/")
    }

    @Test("Quick Open completion preserves typed path prefixes")
    func quickOpenPathCompletion() {
        let root = "/tmp/workspace"
        let directory = URL(fileURLWithPath: root + "/Sources", isDirectory: true)
        let file = URL(fileURLWithPath: root + "/Sources/ContentView.swift")
        let parentRelativeDirectory = URL(
            fileURLWithPath: NSHomeDirectory() + "/Sibling",
            isDirectory: true
        )

        #expect(
            CommandPaletteQuickOpenFileSearch.candidateSelectionPath(
                for: directory,
                rootDir: root,
                currentMatchingTerm: "./Sou",
                isDirectory: true
            ) == "./Sources/"
        )
        #expect(
            CommandPaletteQuickOpenFileSearch.candidateSelectionPath(
                for: file,
                rootDir: root,
                currentMatchingTerm: "./Sources/Cont",
                isDirectory: false
            ) == "./Sources/ContentView.swift"
        )
        #expect(
            CommandPaletteQuickOpenFileSearch.candidateSelectionPath(
                for: file,
                rootDir: root,
                currentMatchingTerm: "content",
                isDirectory: false
            ) == "Sources/ContentView.swift"
        )
        #expect(
            CommandPaletteQuickOpenFileSearch.candidateSelectionPath(
                for: parentRelativeDirectory,
                rootDir: NSHomeDirectory() + "/Develop/Projects",
                currentMatchingTerm: "../../Sib",
                isDirectory: true
            ) == "../../Sibling/"
        )
    }

    private func candidate(title: String, completionText: String? = nil) -> CommandPaletteCommand {
        CommandPaletteCommand(
            id: "candidate",
            rank: 0,
            title: title,
            subtitle: "",
            shortcutHint: nil,
            kindLabel: nil,
            keywords: [],
            dismissOnRun: false,
            action: {},
            completionText: completionText
        )
    }
}
