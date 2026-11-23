import Foundation

/// Where the floating remote may rest and open: the window less the system's insets, the bar along the bottom
/// (the tab bar and its accessory) and the keyboard while it is up.
public struct RemoteSpace: Equatable, Sendable {
    public let window: CGRect
    /// The window inside the status bar, the notch and the home indicator.
    public let safe: CGRect
    /// The top edge of the bottom bar: its measured reach up from the window's foot, never less than the home
    /// indicator's inset.
    public let barTop: CGFloat
    /// The keyboard's top edge, nil while it is down.
    public let keyboardTop: CGFloat?

    /// `chrome` is how far the bottom bar reaches up from the window's foot, 0 before anything has measured it.
    public init(
        size: CGSize, top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0,
        chrome: CGFloat = 0, keyboardTop: CGFloat? = nil
    ) {
        window = CGRect(origin: .zero, size: size)
        safe = CGRect(left: leading, top: top, right: size.width - trailing, bottom: size.height - bottom)
        barTop = size.height - max(chrome, bottom)
        self.keyboardTop = keyboardTop.flatMap { $0 < size.height ? $0 : nil }
    }

    /// The lowest edge anything may reach: the keyboard's top when it is up, else the home indicator's.
    private var floor: CGFloat { min(safe.maxY, keyboardTop ?? safe.maxY) }

    /// Where the whole button may rest: a margin inside the safe area, above the bottom bar and the keyboard.
    public var orbField: CGRect {
        let margin = RemoteMetrics.margin
        let top = safe.minY + margin
        return CGRect(left: safe.minX + margin, top: top, right: safe.maxX - margin, bottom: max(min(barTop, floor) - margin, top))
    }

    /// Where the panel may be: a margin inside the safe area, above the keyboard while it is up. It may cover
    /// the bottom bar.
    public var panelBounds: CGRect {
        let margin = RemoteMetrics.margin
        let top = safe.minY + margin
        return CGRect(left: safe.minX + margin, top: top, right: safe.maxX - margin, bottom: max(floor - margin, top))
    }

    /// The button at an edge spot.
    public func orbRect(for dock: RemoteDock, size: CGFloat) -> CGRect {
        CGRect(origin: edgeOrigin(field: orbField, dock: dock, size: size), size: CGSize(width: size, height: size))
    }
}
