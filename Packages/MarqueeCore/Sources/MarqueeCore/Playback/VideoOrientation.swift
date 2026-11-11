import Foundation

/// How the player's screen turns (Settings › Video & Playback › Video Orientation).
public enum VideoOrientation: String, Codable, CaseIterable, Sendable {
    /// The screen turns with the phone.
    case followDevice
    /// The player opens on its side, then turns with the phone.
    case startInLandscape
    /// The player stays on its side for as long as it is open.
    case lockToLandscape

    public var title: String {
        switch self {
        case .followDevice: "Follow Device"
        case .startInLandscape: "Start in Landscape"
        case .lockToLandscape: "Lock to Landscape"
        }
    }
}

/// How the phone is held, as far as a screen turns with it. Flat on a table or upside down is neither.
public enum PhoneHold: Sendable, Equatable {
    case upright, sideways
}

/// What the open player asks of the screen under a `VideoOrientation`: made when the player opens, told of
/// each new way the phone is held, and asked on closing whether the screen turns back.
public struct OrientationHold: Sendable, Equatable {
    /// The screen is kept on its side, however the phone is held.
    public private(set) var holdsLandscape: Bool
    private let setting: VideoOrientation
    private var held: PhoneHold

    /// - Parameters:
    ///   - screenSideways: The screen is on its side as the player opens.
    ///   - held: How the phone is held then.
    public init(_ setting: VideoOrientation, screenSideways: Bool, held: PhoneHold) {
        self.setting = setting
        self.held = held
        switch setting {
        case .followDevice: holdsLandscape = false
        case .startInLandscape: holdsLandscape = !screenSideways
        case .lockToLandscape: holdsLandscape = true
        }
    }

    /// The phone is held another way. Start in Landscape lets the screen go once the phone is on its side,
    /// and the screen turns with the phone from then on; the upright hold the player opened in never turns
    /// it back.
    public mutating func turned(to hold: PhoneHold) {
        held = hold
        if setting == .startInLandscape, hold == .sideways { holdsLandscape = false }
    }

    /// Closing the player turns the screen upright again: the player kept it on its side and the phone is
    /// held upright. A screen that followed the phone stays as it is.
    public var turnsUprightOnClose: Bool { holdsLandscape && held == .upright }
}
