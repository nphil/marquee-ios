import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum DockSide: String, Sendable { case start, end }

/// Where the orb rests: one of five rows down the screen's two edges.
public struct RemoteDock: Equatable, Sendable {
    public var side: DockSide
    public var row: Int

    public init(side: DockSide, row: Int) {
        self.side = side
        self.row = row
    }

    public static let rows = 5
    public static let `default` = RemoteDock(side: .end, row: 3)

    /// The saved form, `start:2` or `end:3`.
    public var encoded: String { "\(side.rawValue):\(row)" }

    /// Nil for nil, junk, or a row outside the five.
    public init?(decoding text: String?) {
        guard let parts = text?.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false), parts.count == 2,
              let side = DockSide(rawValue: String(parts[0])),
              let row = Int(parts[1]), (0..<Self.rows).contains(row)
        else { return nil }
        self.init(side: side, row: row)
    }

    /// Every spot: the start edge top to bottom, then the end edge.
    public static var all: [RemoteDock] {
        [DockSide.start, .end].flatMap { side in (0..<rows).map { RemoteDock(side: side, row: $0) } }
    }
}

/// Top-left corner of an edge spot. `field` is the area the whole orb may occupy.
public func edgeOrigin(field: CGRect, dock: RemoteDock, size: CGFloat) -> CGPoint {
    let x = dock.side == .start ? field.minX : field.maxX - size
    let y = field.minY + (field.height - size) * CGFloat(dock.row) / CGFloat(RemoteDock.rows - 1)
    return CGPoint(x: x, y: y)
}

/// Where a fling would bring the orb to rest.
public func projectedCenter(center: CGPoint, velocity: CGPoint, seconds: TimeInterval = 0.18) -> CGPoint {
    CGPoint(x: center.x + velocity.x * seconds, y: center.y + velocity.y * seconds)
}

/// The spot closest to `center`.
public func nearestDock(center: CGPoint, field: CGRect, size: CGFloat) -> RemoteDock {
    let side: DockSide = center.x < field.midX ? .start : .end
    let span = field.height - size
    let last = CGFloat(RemoteDock.rows - 1)
    let row = span <= 0 ? 0 : Int(min(max(((center.y - size / 2 - field.minY) / span * last).rounded(), 0), last))
    return RemoteDock(side: side, row: row)
}
