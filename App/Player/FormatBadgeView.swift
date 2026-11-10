import MarqueeCore
import SwiftUI

/// The mark shown for a moment when a video first starts: picture size, high dynamic range kind and
/// surround sound (`FormatBadge`). Glyphs are drawn here as vectors (the Dolby Vision and Atmos marks are
/// original wordmarks, not the licensed logos) and take their colour from the theme. The text grows with
/// Dynamic Type and, by `screenShortSide`, with the screen, so the badge reads the same on a phone and a
/// tablet.
struct FormatBadgeView: View {
    let badge: FormatBadge
    /// The shorter side of the screen in points, 390 on an iPhone held either way.
    let screenShortSide: CGFloat
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .caption) private var base: CGFloat = 13

    /// Text size: scaled by Dynamic Type up to 2.2x, then by the screen from 1x to 1.5x.
    private var unit: CGFloat {
        min(base, 13 * 2.2) * min(1.5, max(1, screenShortSide / 390))
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: unit * 0.9) { segments }
            VStack(alignment: .leading, spacing: unit * 0.6) { segments }
        }
        .padding(.horizontal, unit * 1.1)
        .padding(.vertical, unit * 0.7)
        .background(theme.glassRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.edge, lineWidth: 1))
        .foregroundStyle(theme.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.spoken)
        .accessibilityIdentifier("player.formatBadge")
    }

    @ViewBuilder
    private var segments: some View {
        let parts = self.parts
        ForEach(parts.indices, id: \.self) { index in
            if index > 0 {
                Capsule()
                    .fill(theme.edge)
                    .frame(width: 1, height: unit * 1.2)
            }
            parts[index]
        }
    }

    private var parts: [AnyView] {
        var parts: [AnyView] = []
        if let resolution = badge.resolution {
            parts.append(AnyView(outlined(resolution.rawValue)))
        }
        switch badge.range {
        case .dolbyVision:
            parts.append(AnyView(mark(LensMark().stroke(style: stroke).frame(width: markSize.width, height: markSize.height), "DOLBY VISION")))
        case .hdr10, .hdr10Plus, .hlg:
            if let range = badge.range { parts.append(AnyView(outlined(range.name))) }
        case nil:
            break
        }
        switch badge.sound {
        case .atmos:
            parts.append(AnyView(mark(DomeMark(size: markSize, strokeWidth: stroke.lineWidth), "ATMOS")))
        case .surround51, .surround71:
            if let sound = badge.sound {
                parts.append(AnyView(
                    HStack(spacing: unit * 0.4) {
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: unit * 0.95))
                        Text(sound.name)
                            .font(.system(size: unit, weight: .bold, design: .rounded))
                    }
                ))
            }
        case nil:
            break
        }
        return parts
    }

    private var markSize: CGSize { CGSize(width: unit * 1.5, height: unit * 1.1) }

    private var stroke: StrokeStyle {
        StrokeStyle(lineWidth: max(1, unit * 0.11), lineCap: .round, lineJoin: .round)
    }

    /// Bold text in a thin rounded outline, as the picture-size and HDR tags on a TV box.
    private func outlined(_ text: String) -> some View {
        Text(text)
            .font(.system(size: unit, weight: .heavy, design: .rounded))
            .padding(.horizontal, unit * 0.45)
            .padding(.vertical, unit * 0.1)
            .overlay(RoundedRectangle(cornerRadius: unit * 0.3).strokeBorder(theme.ink, lineWidth: stroke.lineWidth))
    }

    /// A drawn mark beside a tracked, upper-case wordmark.
    private func mark(_ glyph: some View, _ word: String) -> some View {
        HStack(spacing: unit * 0.45) {
            glyph
                .frame(width: markSize.width, height: markSize.height)
            Text(word)
                .font(.system(size: unit * 0.85, weight: .bold))
                .tracking(unit * 0.12)
        }
    }
}

/// A lens: an eye-shaped outline round a pupil.
private struct LensMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let half = rect.height / 2
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.midY - 2 * half))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.midY + 2 * half))
        let pupil = half * 0.5
        path.addEllipse(in: CGRect(x: rect.midX - pupil, y: rect.midY - pupil, width: pupil * 2, height: pupil * 2))
        return path
    }
}

/// Three arcs round a point: sound all around.
private struct DomeMark: View {
    let size: CGSize
    let strokeWidth: CGFloat

    var body: some View {
        let diameter = size.width
        ZStack {
            ForEach([1.0, 0.66, 0.32], id: \.self) { fraction in
                Circle()
                    .trim(from: 0.5, to: 1)
                    .stroke(style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                    .frame(width: diameter * fraction, height: diameter * fraction)
            }
            Circle()
                .fill()
                .frame(width: strokeWidth * 1.6, height: strokeWidth * 1.6)
        }
        // The arcs' centre is the middle of this square, so the top half is the drawing.
        .frame(width: diameter, height: diameter)
        .frame(width: size.width, height: size.height, alignment: .top)
        .offset(y: (size.height - diameter / 2) / 2)
    }
}
