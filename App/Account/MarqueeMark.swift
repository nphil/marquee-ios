import SwiftUI

/// The app icon's marquee board, drawn in the active theme's roles: a raised board, a ring of
/// 22 bulbs and the M. Geometry follows `Design/AppIcon/light.svg`, measured on its 740 × 490 board.
struct MarqueeMark: View {
    @Environment(\.theme) private var theme

    var body: some View {
        // Plain colours, so the renderer closure captures nothing actor-bound.
        let (fill, rim, bulb, ink) = (theme.glassRaised, theme.edgeRaised, theme.ink2, theme.ink)
        Canvas { context, size in
            let unit = size.width / 740
            let board = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 118 * unit, style: .continuous)
            context.fill(board, with: .color(fill))
            context.stroke(board, with: .color(rim), lineWidth: max(1, 4 * unit))

            for centre in Self.bulbs(in: CGRect(origin: .zero, size: size).insetBy(dx: 56 * unit, dy: 56 * unit), radius: 62 * unit) {
                let rect = CGRect(x: centre.x - 19 * unit, y: centre.y - 19 * unit, width: 38 * unit, height: 38 * unit)
                context.fill(Path(ellipseIn: rect), with: .color(bulb))
            }

            var letter = Path()
            letter.move(to: CGPoint(x: 257 * unit, y: 334 * unit))
            letter.addLine(to: CGPoint(x: 257 * unit, y: 156 * unit))
            letter.addLine(to: CGPoint(x: 370 * unit, y: 269.9 * unit))
            letter.addLine(to: CGPoint(x: 483 * unit, y: 156 * unit))
            letter.addLine(to: CGPoint(x: 483 * unit, y: 334 * unit))
            context.stroke(letter, with: .color(ink), style: StrokeStyle(lineWidth: 54 * unit, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(740 / 490, contentMode: .fit)
    }

    /// 22 points spaced evenly along a rounded rectangle, starting at the middle of the top edge.
    nonisolated private static func bulbs(in rect: CGRect, radius r: CGFloat) -> [CGPoint] {
        let straightX = rect.width - 2 * r
        let straightY = rect.height - 2 * r
        let arc = CGFloat.pi / 2 * r
        let perimeter = 2 * straightX + 2 * straightY + 4 * arc
        // Segments clockwise from the top-left end of the top edge.
        let corners = [
            CGPoint(x: rect.maxX - r, y: rect.minY + r),
            CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            CGPoint(x: rect.minX + r, y: rect.maxY - r),
            CGPoint(x: rect.minX + r, y: rect.minY + r),
        ]
        func point(at distance: CGFloat) -> CGPoint {
            var s = distance.truncatingRemainder(dividingBy: perimeter)
            let edges = [straightX, straightY, straightX, straightY]
            let starts = [
                CGPoint(x: rect.minX + r, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY + r),
                CGPoint(x: rect.maxX - r, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY - r),
            ]
            let directions = [CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: -1)]
            for side in 0..<4 {
                if s <= edges[side] {
                    return CGPoint(x: starts[side].x + directions[side].x * s, y: starts[side].y + directions[side].y * s)
                }
                s -= edges[side]
                if s <= arc {
                    // Quarter turn around the corner, from -90° (top) clockwise.
                    let angle = -CGFloat.pi / 2 + CGFloat(side) * CGFloat.pi / 2 + s / r
                    return CGPoint(x: corners[side].x + r * cos(angle), y: corners[side].y + r * sin(angle))
                }
                s -= arc
            }
            return starts[0]
        }
        let start = straightX / 2
        return (0..<22).map { point(at: start + CGFloat($0) * perimeter / 22) }
    }
}
