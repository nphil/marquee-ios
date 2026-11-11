import MarqueeCore
import UIKit

/// Turns the screen for an open player as Settings › Video & Playback › Video Orientation says; the rule
/// is `OrientationHold` in Core. Players open one at a time.
@MainActor
enum PlayerOrientation {
    /// The ways the screen may turn now: the app's own, or only on its side while a player keeps it there.
    private(set) static var allowed = UIInterfaceOrientationMask.allButUpsideDown
    private static var hold: OrientationHold?
    private static var turns: (any NSObjectProtocol)?

    /// A player opened, or came back from Picture in Picture.
    static func opened(_ setting: VideoOrientation) {
        closed()
        let device = UIDevice.current
        // The device reports how it is held only between this call and its pair in `closed`.
        device.beginGeneratingDeviceOrientationNotifications()
        let sideways = scene?.effectiveGeometry.interfaceOrientation.isLandscape ?? false
        let hold = OrientationHold(
            setting, screenSideways: sideways,
            held: PhoneHold(device.orientation) ?? (sideways ? .sideways : .upright)
        )
        self.hold = hold
        turns = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { turned() }
        }
        if hold.holdsLandscape { allow(.landscape, turning: .landscape) }
    }

    /// The player closed, or left for Picture in Picture: the screen is the app's again.
    static func closed() {
        guard let hold else { return }
        self.hold = nil
        if let turns { NotificationCenter.default.removeObserver(turns) }
        turns = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        if hold.holdsLandscape { allow(.allButUpsideDown, turning: hold.turnsUprightOnClose ? .portrait : nil) }
    }

    private static func turned() {
        guard let before = hold, let held = PhoneHold(UIDevice.current.orientation) else { return }
        var after = before
        after.turned(to: held)
        hold = after
        if before.holdsLandscape, !after.holdsLandscape { allow(.allButUpsideDown, turning: nil) }
    }

    /// Has iOS ask again which ways the screen may turn, and turns it to `turn` now.
    private static func allow(_ orientations: UIInterfaceOrientationMask, turning turn: UIInterfaceOrientationMask?) {
        allowed = orientations
        guard let scene else { return }
        var controller = scene.keyWindow?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
        if let turn {
            scene.requestGeometryUpdate(UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: turn))
        }
    }

    private static var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

extension AppDelegate {
    /// iOS 27 deprecates this for `UIWindowSceneDelegate.supportedInterfaceOrientations(for:)`. It stays on
    /// the app delegate: the scene's delegate is SwiftUI's, and how SwiftUI passes this question on to one
    /// of the app's is not documented.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        PlayerOrientation.allowed
    }
}

private extension PhoneHold {
    /// Nil flat or upside down, which turns no screen.
    init?(_ orientation: UIDeviceOrientation) {
        switch orientation {
        case .portrait: self = .upright
        case .landscapeLeft, .landscapeRight: self = .sideways
        default: return nil
        }
    }
}
