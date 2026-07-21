import Testing

@testable import CmuxSettings

@Suite struct QuickRunShortcutDefaultsTests {
    @Test func quickRunOwnsCommandOByDefault() {
        #expect(
            ShortcutAction.quickRun.defaultStroke
                == ShortcutStroke(key: "o", command: true)
        )
    }

    @Test func openFolderIsUnboundByDefault() {
        #expect(ShortcutAction.openFolder.defaultShortcut == nil)
    }
}
