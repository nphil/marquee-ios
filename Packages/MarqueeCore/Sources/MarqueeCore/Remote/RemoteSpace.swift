import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where the remote's panel may sit: the window less the system's insets, and the keyboard while it is up.
public struct RemoteSpace: Equatable, Sendable {
    public let window: CGRect
    /// The window inside the status bar, the notch and the home indicator.
    public let safe: CGRect
    /// The keyboard's top edge, nil while it is down.
    public let keyboardTop: CGFloat?

    public init(
        size: CGSize, top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0,
        keyboardTop: CGFloat? = nil
    ) {
        window = CGRect(origin: .zero, size: size)
        safe = CGRect(left: leading, top: top, right: size.width - trailing, bottom: size.height - bottom)
        self.keyboardTop = keyboardTop.flatMap { $0 < size.height ? $0 : nil }
    }

    /// The lowest edge anything may reach: the keyboard's top when it is up, else the home indicator's.
    private var floor: CGFloat { min(safe.maxY, keyboardTop ?? safe.maxY) }

    /// Where the panel may be: a margin inside the safe area, above the keyboard while it is up.
    public var panelBounds: CGRect {
        let margin = RemoteMetrics.margin
        let top = safe.minY + margin
        return CGRect(left: safe.minX + margin, top: top, right: safe.maxX - margin, bottom: max(floor - margin, top))
    }
}
