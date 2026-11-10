import SwiftUI

/// The buttons in Home's bar whose sheet grows out of the button and shrinks back into it (DESIGN §9).
enum SheetZoomSource: String, Hashable {
    case remote, settings
}

extension EnvironmentValues {
    /// RootView's namespace: the sheets it presents and the bar buttons they zoom from share it.
    @Entry var sheetZoomNamespace: Namespace.ID? = nil
}

extension ToolbarContent {
    /// Makes this bar item the place the sheet for `source` zooms out of and back into. Without a
    /// namespace, as in a preview, the item stays as it is.
    @ToolbarContentBuilder
    func sheetZoomSource(_ source: SheetZoomSource, in namespace: Namespace.ID?) -> some ToolbarContent {
        if let namespace {
            matchedTransitionSource(id: source, in: namespace)
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
