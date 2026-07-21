import Foundation

/// A shell command entered through the command palette's `!` mode.
public struct CommandPaletteShellInput: Equatable, Sendable {
    /// The command text after removing the mode prefix and surrounding whitespace.
    public let command: String

    /// Parses an ASCII or full-width exclamation-prefixed palette query.
    ///
    /// Both `!git status` and `！git status` enter shell mode. A prefix without
    /// a command still returns a value so the palette can show shell-mode help.
    ///
    /// - Parameter query: The complete command-palette query.
    public init?(query: String) {
        guard query.hasPrefix("!") || query.hasPrefix("！") else { return nil }
        command = String(query.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the input contains a command that can be submitted.
    public var isExecutable: Bool {
        !command.isEmpty
    }

}
