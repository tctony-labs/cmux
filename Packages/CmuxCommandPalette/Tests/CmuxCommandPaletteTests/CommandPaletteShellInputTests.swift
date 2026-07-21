import Testing

@testable import CmuxCommandPalette

@Suite struct CommandPaletteShellInputTests {
    @Test(arguments: ["!git status", "！git status"])
    func parsesSupportedPrefixes(query: String) throws {
        let input = try #require(CommandPaletteShellInput(query: query))

        #expect(input.command == "git status")
        #expect(input.isExecutable)
    }

    @Test func trimsWhitespaceAroundCommandWithoutChangingArguments() throws {
        let input = try #require(CommandPaletteShellInput(query: "!   printf '%s %s' one two   "))

        #expect(input.command == "printf '%s %s' one two")
    }

    @Test(arguments: ["!", "！   "])
    func recognizesEmptyShellMode(query: String) throws {
        let input = try #require(CommandPaletteShellInput(query: query))

        #expect(input.command.isEmpty)
        #expect(!input.isExecutable)
    }

    @Test(arguments: ["git status", ">close tab", "@README"])
    func rejectsOtherPaletteModes(query: String) {
        #expect(CommandPaletteShellInput(query: query) == nil)
    }
}
