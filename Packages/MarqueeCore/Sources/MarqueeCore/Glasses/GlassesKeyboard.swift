import Foundation

/// One key of the letter board search types with on the glasses.
public enum GlassesKey: Hashable, Sendable {
    case character(Character)
    case space
    case delete

    public var label: String {
        switch self {
        case .character(let character): String(character).uppercased()
        case .space: "Space"
        case .delete: "Delete"
        }
    }
}

/// The letter board: three rows wide enough to cross in a flick, letters then digits.
public enum GlassesKeyboard {
    public static let rows: [[GlassesKey]] = [
        "abcdefghijklm".map(GlassesKey.character),
        "nopqrstuvwxyz".map(GlassesKey.character),
        "1234567890".map(GlassesKey.character) + [.space, .delete],
    ]

    public static func type(_ key: GlassesKey, into text: String) -> String {
        switch key {
        case .character(let character): text + String(character)
        // Two spaces in a row, or one leading, add nothing to a search.
        case .space: text.isEmpty || text.hasSuffix(" ") ? text : text + " "
        case .delete: String(text.dropLast())
        }
    }
}
