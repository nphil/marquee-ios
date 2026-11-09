import Foundation

/// The player's Restart button works as a music player's previous button: the first press goes to the
/// start of the episode, a second press soon after, or a press while the episode has only just begun,
/// goes to the previous episode.
public enum PreviousPress {
    public enum Action: Sendable, Equatable {
        case restart
        case previousItem
    }

    /// Within this many seconds of the start the episode counts as just begun.
    public static let startWindow: TimeInterval = 3
    /// A second press within this many seconds of the first goes back an episode.
    public static let repeatWindow: TimeInterval = 3

    /// `sincePreviousPress` is the time since the last press, nil when there was none.
    public static func action(position: TimeInterval, sincePreviousPress: TimeInterval?, hasPreviousItem: Bool) -> Action {
        guard hasPreviousItem else { return .restart }
        if position <= startWindow { return .previousItem }
        if let sincePreviousPress, sincePreviousPress <= repeatWindow { return .previousItem }
        return .restart
    }
}
