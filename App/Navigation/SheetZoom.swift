import SwiftUI

/// What the system's zoom grows a sheet or the player out of and shrinks it back into (DESIGN §9): the
/// profile button in Home's bar, and the mini player's picture.
enum SheetZoomSource: String, Hashable {
    case settings, miniPlayer
}

extension EnvironmentValues {
    /// RootView's namespace: the sheets it presents and the bar buttons they zoom from share it.
    @Entry var sheetZoomNamespace: Namespace.ID? = nil
}

extension View {
    /// Makes this button the place the sheet for `source` zooms out of and back into, clipped to a circle.
    /// The source sits on the button rather than on its bar item: the item's source takes the item's own
    /// shape and frame, and the return showed the round button cut top and bottom for a moment (0.1.34,
    /// still after the button was made exactly 44 pt in 0.1.35). Without a namespace, as in a preview,
    /// the button stays as it is.
    @ViewBuilder
    func sheetZoomSource(_ source: SheetZoomSource, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            // The source takes only rounded rectangles; half the 44 pt button's side makes it a circle.
            matchedTransitionSource(id: source, in: namespace) {
                $0.clipShape(RoundedRectangle(cornerRadius: Size.barButton / 2, style: .circular))
            }
        } else {
            self
        }
    }

    /// The mini player's picture: the player grows out of it and shrinks back into it. Without a
    /// namespace, as in a preview, the picture stays as it is.
    @ViewBuilder
    func miniPlayerZoomSource(in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: SheetZoomSource.miniPlayer, in: namespace) {
                $0.clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
        } else {
            self
        }
    }

    /// The player's zoom out of the mini player's picture. `enabled` is false for a start, which keeps
    /// the cover's own motion, and for Reduce Motion.
    @ViewBuilder
    func miniPlayerZoom(in namespace: Namespace.ID?, enabled: Bool) -> some View {
        if let namespace {
            sheetZoom(from: .miniPlayer, in: namespace, enabled: enabled)
        } else {
            self
        }
    }
}

extension View {
    /// Zooms this sheet out of the bar button for `source` and back into it. `enabled` is false for
    /// Reduce Motion, which keeps the system's sheet motion, and for a sheet opened from anywhere but
    /// that button.
    func sheetZoom(from source: SheetZoomSource, in namespace: Namespace.ID, enabled: Bool) -> some View {
        modifier(SheetZoom(source: source, namespace: namespace, enabled: enabled))
    }
}

private struct SheetZoom: ViewModifier {
    let source: SheetZoomSource
    let namespace: Namespace.ID
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.navigationTransition(.zoom(sourceID: source, in: namespace))
        } else {
            content
        }
    }
}
