import Foundation

/// A shortcut binding as it lives on disk: one or two ``ShortcutStroke``s.
///
/// A single-stroke binding fires when the user presses the recorded
/// modifiers + key. A two-stroke ("chord") binding is the tmux-style
/// prefix pattern: press the first stroke, then the second within a
/// short window. ``isUnbound`` represents an explicit "no shortcut for
/// this action" assignment so users can suppress an inherited default.
public struct StoredShortcut: Sendable, Equatable, Hashable, Codable, SettingCodable {
    /// The primary stroke. Empty `key` means the shortcut is unbound.
    public let first: ShortcutStroke

    /// Optional second stroke (chord). `nil` means single-stroke.
    public let second: ShortcutStroke?

    /// A binding that explicitly clears any inherited default.
    public static let unbound = StoredShortcut(
        first: ShortcutStroke(key: "")
    )

    public init(first: ShortcutStroke, second: ShortcutStroke? = nil) {
        self.first = first
        self.second = second
    }

    /// True when this binding is the explicit "no shortcut" marker.
    public var isUnbound: Bool { first.key.isEmpty && second == nil }

    /// True when the binding fires on two consecutive strokes.
    public var hasChord: Bool { second != nil }

    // MARK: - SettingCodable

    public static func decodeFromUserDefaults(_ raw: Any?) -> StoredShortcut? {
        guard let data = raw as? Data else { return nil }
        return try? JSONDecoder().decode(StoredShortcut.self, from: data)
    }

    public func encodeForUserDefaults() -> Any {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decodeFromJSON(_ raw: Any?) -> StoredShortcut? {
        guard let raw else { return nil }
        if raw is NSNull { return .unbound }
        if let stroke = raw as? String {
            return parseConfig(strokes: [stroke])
        }
        if let strokes = raw as? [String] {
            return parseConfig(strokes: strokes)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed) else {
            return nil
        }
        return try? JSONDecoder().decode(StoredShortcut.self, from: data)
    }

    public func encodeForJSON() -> Any {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return NSNull()
        }
        return object
    }

    private static func parseConfig(strokes: [String]) -> StoredShortcut? {
        if strokes.isEmpty { return .unbound }
        guard strokes.count <= 2 else { return nil }
        if strokes.count == 1, let rawValue = strokes.first, isUnboundConfigToken(rawValue) {
            return .unbound
        }

        let parsedStrokes = strokes.compactMap(ShortcutStroke.parseConfig(_:))
        guard parsedStrokes.count == strokes.count, let first = parsedStrokes.first else {
            return nil
        }
        return StoredShortcut(first: first, second: parsedStrokes.count == 2 ? parsedStrokes[1] : nil)
    }

    private static func isUnboundConfigToken(_ rawValue: String) -> Bool {
        if rawValue.isEmpty { return true }
        if rawValue == " " { return false }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return normalized == "none"
            || normalized == "clear"
            || normalized == "unbound"
            || normalized == "disabled"
    }
}
