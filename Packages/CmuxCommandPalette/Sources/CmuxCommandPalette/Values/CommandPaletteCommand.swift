import Foundation

/// One runnable palette command: identity, display strings, search keywords,
/// and the action executed when the command is activated.
public struct CommandPaletteCommand: Identifiable {
    /// Stable command identifier.
    public let id: String
    /// Tie-break rank; lower sorts first at equal score.
    public let rank: Int
    /// Display title.
    public let title: String
    /// Display subtitle.
    public let subtitle: String
    /// Optional keyboard-shortcut hint shown trailing the row.
    public let shortcutHint: String?
    /// Optional kind label (for example a switcher row's surface kind).
    public let kindLabel: String?
    /// Additional search keywords.
    public let keywords: [String]
    /// Whether activating the command dismisses the palette.
    public let dismissOnRun: Bool
    /// The action executed on activation.
    public let action: () -> Void
    /// Optional action executed when the command is activated with the Command
    /// modifier held (Cmd+Enter). Returns `true` when it handled the
    /// activation (so the palette dismisses) or `false` when it was a no-op
    /// (the palette stays open). When nil, Cmd+Enter does nothing.
    public let alternateAction: (() -> Bool)?

    /// Creates a command.
    public init(
        id: String,
        rank: Int,
        title: String,
        subtitle: String,
        shortcutHint: String?,
        kindLabel: String?,
        keywords: [String],
        dismissOnRun: Bool,
        action: @escaping () -> Void,
        alternateAction: (() -> Bool)? = nil
    ) {
        self.id = id
        self.rank = rank
        self.title = title
        self.subtitle = subtitle
        self.shortcutHint = shortcutHint
        self.kindLabel = kindLabel
        self.keywords = keywords
        self.dismissOnRun = dismissOnRun
        self.action = action
        self.alternateAction = alternateAction
    }

    /// Texts the search corpus indexes for this command.
    public var searchableTexts: [String] {
        [title, subtitle] + keywords
    }
}
