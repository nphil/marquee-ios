import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The panel's rectangle as fractions of the window, so a saved layout survives rotation and a new screen.
public struct PanelFractions: Equatable, Sendable {
    public var x, y, w, h: CGFloat

    public init(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public init(rect: CGRect, in window: CGRect) {
        self.init(
            x: (rect.minX - window.minX) / window.width, y: (rect.minY - window.minY) / window.height,
            w: rect.width / window.width, h: rect.height / window.height)
    }

    public func rect(in window: CGRect) -> CGRect {
        CGRect(
            left: window.minX + x * window.width, top: window.minY + y * window.height,
            right: window.minX + (x + w) * window.width, bottom: window.minY + (y + h) * window.height)
    }

    /// Four numbers with a `.` decimal separator whatever the device's locale.
    public var encoded: String {
        String(format: "%.4f,%.4f,%.4f,%.4f", locale: Locale(identifier: "en_US_POSIX"), Double(x), Double(y), Double(w), Double(h))
    }

    /// Nil unless the text holds four finite numbers with a positive width and height.
    public init?(decoding text: String?) {
        guard let text else { return nil }
        let numbers = text.split(separator: ",", omittingEmptySubsequences: false).compactMap { Double($0) }
        guard numbers.count == 4, numbers.allSatisfy(\.isFinite), numbers[2] > 0, numbers[3] > 0 else { return nil }
        self.init(x: CGFloat(numbers[0]), y: CGFloat(numbers[1]), w: CGFloat(numbers[2]), h: CGFloat(numbers[3]))
    }
}

/// Which edges a resize handle moves.
public struct PanelHandle: Equatable, Sendable {
    public var left, top, right, bottom: Bool

    public init(left: Bool = false, top: Bool = false, right: Bool = false, bottom: Bool = false) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    /// Four corners and four edge centres, top row first.
    public static let all: [PanelHandle] = [
        PanelHandle(left: true, top: true), PanelHandle(top: true), PanelHandle(top: true, right: true),
        PanelHandle(left: true), PanelHandle(right: true),
        PanelHandle(left: true, bottom: true), PanelHandle(bottom: true), PanelHandle(right: true, bottom: true),
    ]
}

private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(value, low), high) }

/// Rounds half up, as the Android port does, so a saved edge never lands on a different grid line.
private func roundHalfUp(_ value: CGFloat) -> CGFloat { (value + 0.5).rounded(.down) }

/// The size and place the panel opens at before the user has moved it: centred across `bounds`, near its top.
public func defaultPanel(bounds: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
    let w = min(width, bounds.width)
    let h = min(height, bounds.height)
    return CGRect(x: bounds.midX - w / 2, y: bounds.minY, width: w, height: h)
}

/// Keeps `rect` inside `bounds`, shrinking it only when it cannot fit even at `minSize`.
public func fitPanel(_ rect: CGRect, in bounds: CGRect, minSize: CGFloat) -> CGRect {
    let w = clamp(rect.width, min(minSize, bounds.width), bounds.width)
    let h = clamp(rect.height, min(minSize, bounds.height), bounds.height)
    let x = clamp(rect.minX, bounds.minX, bounds.maxX - w)
    let y = clamp(rect.minY, bounds.minY, bounds.maxY - h)
    return CGRect(x: x, y: y, width: w, height: h)
}

public func movePanel(_ rect: CGRect, by delta: CGPoint, in bounds: CGRect) -> CGRect {
    fitPanel(rect.offsetBy(dx: delta.x, dy: delta.y), in: bounds, minSize: min(rect.width, rect.height))
}

public func resizePanel(_ rect: CGRect, handle: PanelHandle, delta: CGPoint, bounds: CGRect, minSize: CGFloat) -> CGRect {
    func between(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { clamp(value, low, max(low, high)) }
    var left = rect.minX
    var top = rect.minY
    var right = rect.maxX
    var bottom = rect.maxY
    let minW = min(minSize, bounds.width)
    let minH = min(minSize, bounds.height)
    if handle.left { left = between(left + delta.x, bounds.minX, right - minW) }
    if handle.right { right = between(right + delta.x, left + minW, bounds.maxX) }
    if handle.top { top = between(top + delta.y, bounds.minY, bottom - minH) }
    if handle.bottom { bottom = between(bottom + delta.y, top + minH, bounds.maxY) }
    return CGRect(left: left, top: top, right: right, bottom: bottom)
}

/// Rounds every edge to the grid so the panel's measures stay on it.
public func snapPanel(_ rect: CGRect, step: CGFloat) -> CGRect {
    func snap(_ value: CGFloat) -> CGFloat { roundHalfUp(value / step) * step }
    let left = snap(rect.minX)
    let top = snap(rect.minY)
    return CGRect(left: left, top: top, right: max(snap(rect.maxX), left + step), bottom: max(snap(rect.maxY), top + step))
}
