import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The groups of controls the floating remote can show. `pad` is always on; the rest are the user's choice.
public enum RemoteModule: String, CaseIterable, Sendable {
    case pad, nav, volume, channel, playback, keyboard, apps, more

    public var label: String {
        switch self {
        case .pad: "Pad"
        case .nav: "Back & home"
        case .volume: "Volume"
        case .channel: "Channel"
        case .playback: "Playback"
        case .keyboard: "Keyboard"
        case .apps: "Apps"
        case .more: "More"
        }
    }
}

/// A row of keys under or beside the pad. Declaration order is the order on the panel.
public enum RemoteStrip: CaseIterable, Sendable {
    case nav, volume, channel, playback, launchers

    public var modules: [RemoteModule] {
        switch self {
        case .nav: [.nav]
        case .volume: [.volume]
        case .channel: [.channel]
        case .playback: [.playback]
        case .launchers: [.keyboard, .apps, .more]
        }
    }
}

public enum RemoteShape: Sendable { case column, row, compact }

/// All measures are points on a 4 grid, relative to the panel's top-left corner.
public enum RemoteMetrics {
    public static let grid: CGFloat = 4
    /// The window's edge margin for the panel itself.
    public static let margin: CGFloat = 16
    /// Space between the card's edge and everything on its face.
    public static let inset: CGFloat = 20
    public static let gap: CGFloat = 12
    public static let key: CGFloat = 56
    public static let header: CGFloat = 52
    public static let padMin: CGFloat = 144
    /// Three keys and the two gaps between them.
    public static let stripWidth: CGFloat = 192
    public static let tray: CGFloat = 56
    public static let minPanel: CGFloat = 232
}

public struct ModuleRect: Equatable, Sendable {
    public let module: RemoteModule
    public let rect: CGRect

    public init(module: RemoteModule, rect: CGRect) {
        self.module = module
        self.rect = rect
    }
}

public struct StripPlacement: Equatable, Sendable {
    public let strip: RemoteStrip
    public let rect: CGRect
    public let modules: [RemoteModule]

    public init(strip: RemoteStrip, rect: CGRect, modules: [RemoteModule]) {
        self.strip = strip
        self.rect = rect
        self.modules = modules
    }

    /// A strip is three keys; the launchers are one key per module the user kept.
    public var keys: Int { strip == .launchers ? modules.count : 3 }

    public var keyRects: [CGRect] { rect.split(keys, gap: RemoteMetrics.gap) }

    /// What a tap on the edit badge removes, with the rectangle it outlines.
    public var moduleRects: [ModuleRect] {
        if strip == .launchers {
            return zip(modules, keyRects).map { ModuleRect(module: $0, rect: $1) }
        }
        return modules.prefix(1).map { ModuleRect(module: $0, rect: rect) }
    }
}

/// The panel laid out for its shape: a column when it is tall, a row when it is wide, and the pad alone when it is
/// small. Strips that do not fit are dropped in `dropOrder` and reported in `dropped`.
public struct RemoteLayout: Equatable, Sendable {
    public let shape: RemoteShape
    public let area: CGRect
    public let pad: CGRect
    public let strips: [StripPlacement]
    /// Visible modules that did not fit at this size.
    public let dropped: [RemoteModule]

    /// `tray` reserves room along the bottom for the hidden-module chips while editing.
    public init(width: CGFloat, height: CGFloat, visible: Set<RemoteModule>, tray: CGFloat = 0) {
        let m = RemoteMetrics.self
        let w = Self.onGrid(max(width, m.minPanel))
        let h = Self.onGrid(max(height, m.minPanel))
        let area = CGRect(left: m.inset, top: m.header, right: w - m.inset, bottom: h - m.inset - tray)
        let wanted = RemoteStrip.allCases.filter { strip in strip.modules.contains { visible.contains($0) } }
        let shape: RemoteShape
        if area.width >= 1.25 * area.height, area.width >= m.padMin + m.gap + m.stripWidth {
            shape = .row
        } else if area.height >= m.padMin + m.gap + m.key, area.width >= m.stripWidth {
            shape = .column
        } else {
            shape = .compact
        }
        switch shape {
        case .compact:
            self.init(shape: shape, area: area, pad: area, strips: [], visible: visible)
        case .column:
            let (pad, strips) = Self.column(area: area, wanted: wanted, visible: visible)
            self.init(shape: shape, area: area, pad: pad, strips: strips, visible: visible)
        case .row:
            let (pad, strips) = Self.row(area: area, wanted: wanted, visible: visible)
            self.init(shape: shape, area: area, pad: pad, strips: strips, visible: visible)
        }
    }

    private init(shape: RemoteShape, area: CGRect, pad: CGRect, strips: [StripPlacement], visible: Set<RemoteModule>) {
        self.shape = shape
        self.area = area
        self.pad = pad
        self.strips = strips
        let placed = Set(strips.flatMap(\.modules))
        dropped = RemoteModule.allCases.filter { $0 != .pad && visible.contains($0) && !placed.contains($0) }
    }

    /// The strip that goes first when space runs out: the least used keys leave before the essentials.
    private static let dropOrder: [RemoteStrip] = [.channel, .playback, .launchers, .volume, .nav]

    private static func onGrid(_ value: CGFloat) -> CGFloat {
        (value / RemoteMetrics.grid).rounded(.down) * RemoteMetrics.grid
    }

    private static func dropOne(_ shown: inout [RemoteStrip]) {
        if let victim = dropOrder.first(where: shown.contains) {
            shown.removeAll { $0 == victim }
        }
    }

    private static func column(area: CGRect, wanted: [RemoteStrip], visible: Set<RemoteModule>) -> (CGRect, [StripPlacement]) {
        let m = RemoteMetrics.self
        var shown = wanted
        // The strips plus the gap above them.
        func need(_ count: Int) -> CGFloat {
            count == 0 ? 0 : CGFloat(count) * m.key + CGFloat(count - 1) * m.gap + m.gap
        }
        while !shown.isEmpty, area.height - need(shown.count) < m.padMin { dropOne(&shown) }
        let pad = CGRect(left: area.minX, top: area.minY, right: area.maxX, bottom: area.minY + area.height - need(shown.count))
        var y = pad.maxY + m.gap
        let strips = shown.map { strip in
            defer { y += m.key + m.gap }
            return StripPlacement(
                strip: strip, rect: CGRect(left: area.minX, top: y, right: area.maxX, bottom: y + m.key),
                modules: strip.modules.filter(visible.contains))
        }
        return (pad, strips)
    }

    private static func row(area: CGRect, wanted: [RemoteStrip], visible: Set<RemoteModule>) -> (CGRect, [StripPlacement]) {
        let m = RemoteMetrics.self
        let capacity = max(Int(((area.height + m.gap) / (m.key + m.gap)).rounded(.down)), 0)
        let columns = area.width >= m.padMin + 2 * (m.stripWidth + m.gap) ? 2 : 1
        var shown = wanted
        while shown.count > capacity * columns { dropOne(&shown) }
        let used = shown.isEmpty ? 0 : (shown.count + capacity - 1) / capacity
        let pad = CGRect(
            left: area.minX, top: area.minY,
            right: area.minX + area.width - CGFloat(used) * (m.stripWidth + m.gap), bottom: area.maxY)
        let perColumn = used == 0 ? 1 : (shown.count + used - 1) / used
        var strips: [StripPlacement] = []
        for (column, start) in stride(from: 0, to: shown.count, by: perColumn).enumerated() {
            let group = shown[start..<min(start + perColumn, shown.count)]
            let span = CGFloat(group.count) * m.key + CGFloat(group.count - 1) * m.gap
            let x = pad.maxX + m.gap + CGFloat(column) * (m.stripWidth + m.gap)
            var y = area.minY + onGrid((area.height - span) / 2)
            for strip in group {
                strips.append(StripPlacement(
                    strip: strip, rect: CGRect(left: x, top: y, right: x + m.stripWidth, bottom: y + m.key),
                    modules: strip.modules.filter(visible.contains)))
                y += m.key + m.gap
            }
        }
        return (pad, strips)
    }
}

extension CGRect {
    init(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) {
        self.init(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// `count` equal cells side by side with `gap` between them.
    func split(_ count: Int, gap: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let each = (width - gap * CGFloat(count - 1)) / CGFloat(count)
        return (0..<count).map { index in
            CGRect(x: minX + CGFloat(index) * (each + gap), y: minY, width: each, height: height)
        }
    }
}

extension Set where Element == RemoteModule {
    /// Every module: what an unsaved choice shows.
    public static var all: Set<RemoteModule> { Set(RemoteModule.allCases) }
}

/// The saved choice: a comma list in declaration order. `pad` is implied, so it is never written.
public func encodeRemoteModules(_ modules: Set<RemoteModule>) -> String {
    RemoteModule.allCases.filter { $0 != .pad && modules.contains($0) }.map(\.rawValue).joined(separator: ",")
}

/// An unsaved choice shows everything; a saved empty one is a panel with only the pad.
public func decodeRemoteModules(_ text: String?) -> Set<RemoteModule> {
    guard let text else { return .all }
    let chosen = text.split(separator: ",").compactMap { RemoteModule(rawValue: String($0)) }
    return Set(chosen).union([.pad])
}
