import Testing

@testable import CmuxSettings

@Suite("Quick Open copy-path shortcut")
struct QuickOpenCopyPathShortcutDefaultsTests {
    @Test("Default shortcut is Command-Y")
    func defaultShortcutIsCommandY() {
        #expect(
            ShortcutAction.quickOpenCopyPath.defaultStroke
                == ShortcutStroke(key: "y", command: true)
        )
    }
}
