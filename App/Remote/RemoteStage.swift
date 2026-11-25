import MarqueeCore
import SwiftUI

/// What the remote's panel is doing at this moment, as against what was chosen: the chosen layout lives in
/// `TVRemote`, and nothing here is saved.
@MainActor @Observable
final class RemoteStage {
    /// The panel before it has been moved or resized.
    static let defaultSize = CGSize(width: 380, height: 660)
    /// The window's measures, kept current by the host for the gestures that need them.
    var space = RemoteSpace(size: .zero)
    /// The open panel's own rectangle in the window, nil while it is closed. It stays as chosen and is fitted to
    /// the room there is each time it is drawn, so a keyboard that squeezes the panel gives the size back.
    var live: CGRect?
    /// The panel is in the view tree, from the first frame of opening to the last of closing.
    var shown = false
    var editing = false
    /// The pages that are open over the panel's face.
    var path: [RemotePage] = []
    /// The keyboard page came up because the TV opened a text field, so it leaves when the field does.
    var keyboardFollowsTV = false

    /// The panel as it opens: the saved one fitted to the room there is, or the default, centred.
    static func openingPanel(_ remote: TVRemote, in space: RemoteSpace) -> CGRect {
        if let saved = remote.panel {
            return fitPanel(saved.rect(in: space.safe), in: space.panelBounds, minSize: RemoteMetrics.minPanel)
        }
        return defaultPanel(bounds: space.panelBounds, width: defaultSize.width, height: defaultSize.height)
    }

    /// The open panel as it is drawn, kept inside the room there is.
    func panel(in space: RemoteSpace) -> CGRect {
        guard let live else { return .zero }
        return fitPanel(live, in: space.panelBounds, minSize: RemoteMetrics.minPanel)
    }

    /// A move or a resize ended: the panel snaps to the grid, stays inside the room and is saved.
    func settle(_ remote: TVRemote) {
        guard let live else { return }
        let rect = fitPanel(snapPanel(live, step: RemoteMetrics.grid), in: space.panelBounds, minSize: RemoteMetrics.minPanel)
        self.live = rect
        remote.setPanel(PanelFractions(rect: rect, in: space.safe))
    }

    /// A move from VoiceOver's actions, which have no drag to follow: the panel by `delta`, then settled as the
    /// end of a drag would.
    func nudge(by delta: CGPoint, _ remote: TVRemote) {
        guard let live else { return }
        self.live = movePanel(live, by: delta, in: space.panelBounds)
        settle(remote)
    }

    /// A resize from VoiceOver's actions: the edge or corner `handle` by `delta`.
    func resize(_ handle: PanelHandle, by delta: CGPoint, _ remote: TVRemote) {
        guard let live else { return }
        self.live = resizePanel(live, handle: handle, delta: delta, bounds: space.panelBounds, minSize: RemoteMetrics.minPanel)
        settle(remote)
    }

    /// Arrange › Reset layout: the default panel with every module and the D-pad.
    func resetLayout(_ remote: TVRemote) {
        remote.resetLayout()
        live = Self.openingPanel(remote, in: space)
    }

    /// Opens or closes the keyboard page. `followingTV` marks one the TV's own text field asked for.
    func showKeyboard(_ shown: Bool, followingTV: Bool) {
        keyboardFollowsTV = shown && followingTV
        if shown {
            if path.last != .keyboard { path.append(.keyboard) }
        } else {
            path.removeAll { $0 == .keyboard }
        }
    }
}
