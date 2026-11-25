import LumaRemoteKit
import UIKit

/// Feedback for the remote's controls, gated by the remote's own Haptics switch (Settings › LumaTV Remote). The
/// app's `Haptics` serves the rest of the app and does not read that switch.
@MainActor
struct PanelHaptics {
    let enabled: Bool

    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let firm = UIImpactFeedbackGenerator(style: .rigid)
    private static let ticks = UISelectionFeedbackGenerator()

    /// A key going down.
    func press() {
        guard enabled else { return }
        Self.soft.impactOccurred(intensity: 0.7)
    }

    /// A click, a held key taking effect, or the panel entering edit mode.
    func click() {
        guard enabled else { return }
        Self.firm.impactOccurred(intensity: 0.8)
    }

    /// One arrow step of the joystick, a change of pad, or a change of the panel's shape.
    func tick() {
        guard enabled else { return }
        Self.ticks.selectionChanged()
    }
}

extension RemoteModel {
    /// Feedback for the remote's controls, as the remote's Haptics switch has it.
    var feedback: PanelHaptics { PanelHaptics(enabled: settings.haptics) }
}
