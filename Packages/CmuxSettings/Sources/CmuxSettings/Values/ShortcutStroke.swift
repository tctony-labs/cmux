import Foundation

/// One keystroke in a (possibly chorded) shortcut.
///
/// `key` is the platform-canonical lower-case character or named token
/// (e.g. `"a"`, `"space"`, `"return"`, `"f5"`, `"←"`). `keyCode` is the
/// optional macOS virtual key code, captured when the user records a
/// shortcut so we can re-match the same physical key after a layout
/// change. Modifier flags are flat booleans because the cmux JSON
/// config encodes them that way for easy hand-editing.
public struct ShortcutStroke: Sendable, Equatable, Hashable, Codable {
    public let key: String
    public let command: Bool
    public let shift: Bool
    public let option: Bool
    public let control: Bool
    public let keyCode: UInt16?

    public init(
        key: String,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false,
        keyCode: UInt16? = nil
    ) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.keyCode = keyCode
    }

    /// True when at least one of `cmd`, `shift`, `opt`, or `ctrl` is set.
    public var hasAnyModifier: Bool { command || shift || option || control }
}

extension ShortcutStroke {
    static func parseConfig(_ rawValue: String) -> ShortcutStroke? {
        guard !rawValue.isEmpty else { return nil }

        let rawParts = rawValue.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let parts = rawParts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !parts.isEmpty, let lastRawPart = rawParts.last, !lastRawPart.isEmpty else {
            return nil
        }

        var command = false
        var shift = false
        var option = false
        var control = false

        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "cmd", "command", "⌘":
                command = true
            case "shift", "⇧":
                shift = true
            case "opt", "option", "alt", "⌥":
                option = true
            case "ctrl", "control", "ctl", "⌃":
                control = true
            default:
                return nil
            }
        }

        guard let key = parseConfigKeyToken(lastRawPart) else { return nil }
        return ShortcutStroke(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control
        )
    }

    private static func parseConfigKeyToken(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return rawValue == " " ? "space" : nil
        }

        let lowered = trimmed.lowercased()
        switch lowered {
        case "left", "arrowleft", "leftarrow", "←": return "←"
        case "right", "arrowright", "rightarrow", "→": return "→"
        case "up", "arrowup", "uparrow", "↑": return "↑"
        case "down", "arrowdown", "downarrow", "↓": return "↓"
        case "tab": return "\t"
        case "return", "enter", "↩": return "\r"
        case "space", "spacebar", "<space>": return "space"
        case "comma": return ","
        case "period", "dot": return "."
        case "slash": return "/"
        case "backslash": return "\\"
        case "semicolon": return ";"
        case "quote", "apostrophe": return "'"
        case "backtick", "grave": return "`"
        case "minus", "hyphen": return "-"
        case "plus", "equals": return "="
        case "leftbracket", "openbracket": return "["
        case "rightbracket", "closebracket": return "]"
        case "volumeup", "mediavolumeup", "media.volumeup": return "media.volumeUp"
        case "volumedown", "mediavolumedown", "media.volumedown": return "media.volumeDown"
        case "brightnessup", "mediabrightnessup", "media.brightnessup": return "media.brightnessUp"
        case "brightnessdown", "mediabrightnessdown", "media.brightnessdown": return "media.brightnessDown"
        case "mute", "mediamute", "media.mute": return "media.mute"
        case "playpause", "mediaplaypause", "media.playpause": return "media.playPause"
        case "nexttrack", "medianext", "media.next", "media.nexttrack": return "media.next"
        case "previoustrack", "mediaprevious", "media.previous", "media.previoustrack":
            return "media.previous"
        default:
            if lowered.hasPrefix("f"),
               let number = Int(lowered.dropFirst()),
               (1...20).contains(number) {
                return "f\(number)"
            }
            return lowered.count == 1 ? lowered : nil
        }
    }
}
