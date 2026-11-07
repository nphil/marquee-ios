import MarqueeCore
import SwiftUI

/// Subtitle text in a profile's look (behaviour spec §3, "Subtitle look"). Every length is a share of the
/// picture's height, as on a TV, so the text does not follow the iPhone's text size. The player passes cue
/// text with its italics and bold, and a styled file's own colours.
struct SubtitleLine: View {
    let text: AttributedString
    let look: SubtitleLook
    let pictureHeight: CGFloat

    init(text: AttributedString, look: SubtitleLook, pictureHeight: CGFloat) {
        self.text = text
        self.look = look
        self.pictureHeight = pictureHeight
    }

    init(text: String, look: SubtitleLook, pictureHeight: CGFloat) {
        self.init(text: AttributedString(text), look: look, pictureHeight: pictureHeight)
    }

    var body: some View {
        let metrics = SubtitleMetrics(look: look, pictureHeight: pictureHeight)
        let lines = Self.lines(look.keepsFileStyling ? text : Self.withoutFileColours(text))
        VStack(spacing: metrics.lineGap) {
            ForEach(lines.indices, id: \.self) { index in
                letters(lines[index], metrics)
                    .modifier(SubtitleBox(look: look, metrics: metrics, isOn: look.background == .lineBox))
            }
        }
        .modifier(SubtitleBox(look: look, metrics: metrics, isOn: look.background == .window))
    }

    private func letters(_ line: AttributedString, _ metrics: SubtitleMetrics) -> some View {
        Text(line)
            .font(metrics.font)
            .foregroundStyle(PictureColours.subtitle(look))
            .multilineTextAlignment(.center)
            .lineSpacing(max(0, metrics.lineGap))
            .fixedSize(horizontal: false, vertical: true)
            .modifier(SubtitleEdge(edge: look.edge, width: metrics.edgeWidth, textSize: metrics.textSize))
            // Letters and their edge fade as one, so the edge never shows through translucent letters.
            .compositingGroup()
            .opacity(Double(look.opacity) / 100)
    }

    /// The cue's lines, each drawn on its own so a line box hugs every line and the spacing between lines
    /// can also shrink.
    static func lines(_ text: AttributedString) -> [AttributedString] {
        var lines: [AttributedString] = []
        var start = text.startIndex
        for index in text.characters.indices where text.characters[index].isNewline {
            lines.append(AttributedString(text[start..<index]))
            start = text.characters.index(after: index)
        }
        lines.append(AttributedString(text[start...]))
        return lines
    }

    /// File styling "My look": a styled file's colours give way to the look's; italics and bold stay, since
    /// they carry meaning.
    static func withoutFileColours(_ text: AttributedString) -> AttributedString {
        var text = text
        text[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = nil
        return text
    }
}

/// The look's lengths in points for a picture of a given height. Pixel values are pixels of a 1080-line
/// picture.
private struct SubtitleMetrics {
    let look: SubtitleLook
    /// One pixel of a 1080-line picture.
    let unit: CGFloat
    /// The standard line is 5.5 % of the picture's height.
    let textSize: CGFloat

    init(look: SubtitleLook, pictureHeight: CGFloat) {
        self.look = look
        unit = pictureHeight / 1080
        textSize = pictureHeight * 0.055 * CGFloat(look.size) / 100
    }

    var edgeWidth: CGFloat { CGFloat(look.edgeWidth) * unit }
    var padding: CGFloat { CGFloat(look.padding) * unit }
    var cornerRadius: CGFloat { CGFloat(look.cornerRadius) * unit }
    /// Added between lines; negative below 100 % line spacing.
    var lineGap: CGFloat { textSize * CGFloat(look.lineSpacing - 100) / 100 }

    var font: Font {
        let weight: Font.Weight = look.isBold ? .bold : .medium
        return switch look.font {
        case .standard: .system(size: textSize, weight: weight)
        case .serif: .system(size: textSize, weight: weight, design: .serif)
        case .mono: .system(size: textSize, weight: weight, design: .monospaced)
        // Atkinson Hyperlegible comes in regular and bold only.
        case .legible: .custom(look.isBold ? "AtkinsonHyperlegible-Bold" : "AtkinsonHyperlegible-Regular", fixedSize: textSize)
        }
    }
}

private struct SubtitleBox: ViewModifier {
    let look: SubtitleLook
    let metrics: SubtitleMetrics
    let isOn: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isOn {
            content
                .padding(.horizontal, metrics.padding + metrics.textSize * 0.2)
                .padding(.vertical, metrics.padding * 0.5)
                .background(
                    PictureColours.subtitleBox(look.backgroundColour).opacity(Double(look.backgroundOpacity) / 100),
                    in: RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                )
        } else {
            content
        }
    }
}

/// Edges are stacked hard shadows: each shadow also shadows the ones before it, so four offsets make a
/// full outline, and a dark and a light offset make a raised or a depressed edge.
private struct SubtitleEdge: ViewModifier {
    let edge: SubtitleLook.Edge
    let width: CGFloat
    let textSize: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let dark = PictureColours.subtitleEdge
        let light = PictureColours.subtitleHighlight
        switch edge {
        case .none:
            content
        case .outline:
            content
                .shadow(color: dark, radius: 0, x: width, y: 0)
                .shadow(color: dark, radius: 0, x: -width, y: 0)
                .shadow(color: dark, radius: 0, x: 0, y: width)
                .shadow(color: dark, radius: 0, x: 0, y: -width)
        case .dropShadow:
            content
                .shadow(color: dark, radius: 0, x: width, y: width)
        case .raised:
            content
                .shadow(color: dark, radius: 0, x: width, y: width)
                .shadow(color: light, radius: 0, x: -width / 2, y: -width / 2)
        case .depressed:
            content
                .shadow(color: dark, radius: 0, x: -width, y: -width)
                .shadow(color: light, radius: 0, x: width / 2, y: width / 2)
        case .softShadow:
            content
                .shadow(color: dark.opacity(0.8), radius: textSize * 0.06 + width, x: 0, y: textSize * 0.02 + width / 2)
        }
    }
}
