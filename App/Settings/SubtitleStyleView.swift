import SwiftUI

/// How subtitles look (behaviour spec §3, "Subtitle look"), saved for the active profile, with a
/// preview that follows every change.
struct SubtitleStyleView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var session = session
        List {
            Section {
                SubtitlePreview(style: session.settings.subtitleStyle)
                    .listRowInsets(EdgeInsets())
            }
            .listRowBackground(Color.clear)

            Section {
                Picker("Size", selection: $session.settings.subtitleStyle.size) {
                    ForEach(SubtitleStyle.Size.allCases, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                }
                .accessibilityIdentifier("style.size")
                Picker("Colour", selection: $session.settings.subtitleStyle.colour) {
                    ForEach(SubtitleStyle.Colour.allCases, id: \.self) { colour in
                        Text(colour.title).tag(colour)
                    }
                }
                .accessibilityIdentifier("style.colour")
                Picker("Edge", selection: $session.settings.subtitleStyle.edge) {
                    ForEach(SubtitleStyle.Edge.allCases, id: \.self) { edge in
                        Text(edge.title).tag(edge)
                    }
                }
                .accessibilityIdentifier("style.edge")
                Toggle("Background", isOn: $session.settings.subtitleStyle.hasBackground)
                    .tint(theme.accent)
                    .accessibilityIdentifier("style.background")
                Toggle("Bold", isOn: $session.settings.subtitleStyle.isBold)
                    .tint(theme.accent)
                    .accessibilityIdentifier("style.bold")
                Picker("Position", selection: $session.settings.subtitleStyle.position) {
                    ForEach(SubtitleStyle.Position.allCases, id: \.self) { position in
                        Text(position.title).tag(position)
                    }
                }
                .accessibilityIdentifier("style.position")
            } footer: {
                Text("Subtitles that carry their own styling keep it.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("Subtitle Style")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A 16:9 frame shaded from dark to bright, with a subtitle in the chosen style, so the edge and background
/// choices show over both kinds of picture. Played in landscape, the picture spans the phone's short side,
/// which the preview's width matches, so the line takes about the size it has on a video. The rows read
/// out the same choices, so the preview is hidden from VoiceOver.
private struct SubtitlePreview: View {
    let style: SubtitleStyle

    /// About an iPhone's short side. A landscape list row is far wider, and would make both the frame and
    /// the line larger than any video shows them.
    private static let maxWidth: CGFloat = 400

    var body: some View {
        GeometryReader { proxy in
            SubtitleLine(text: "Subtitles look\nlike this.", style: style, pictureHeight: proxy.size.width)
                .padding(proxy.size.height * 0.06)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: style.position == .top ? .top : .bottom)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(LinearGradient(colors: [PictureColours.black, PictureColours.bright], startPoint: .leading, endPoint: .trailing))
        .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .frame(maxWidth: Self.maxWidth)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// One subtitle line in a style. The text height is a share of the picture's, as on a TV, so it
/// does not follow the iPhone's text size. The player passes cue text with its italics and bold.
struct SubtitleLine: View {
    let text: AttributedString
    let style: SubtitleStyle
    let pictureHeight: CGFloat

    init(text: AttributedString, style: SubtitleStyle, pictureHeight: CGFloat) {
        self.text = text
        self.style = style
        self.pictureHeight = pictureHeight
    }

    init(text: String, style: SubtitleStyle, pictureHeight: CGFloat) {
        self.init(text: AttributedString(text), style: style, pictureHeight: pictureHeight)
    }

    var body: some View {
        let size = pictureHeight * CGFloat(style.size.heightFraction)
        Text(text)
            .font(.system(size: size, weight: style.isBold ? .bold : .medium))
            .foregroundStyle(PictureColours.subtitle(style.colour))
            .multilineTextAlignment(.center)
            .modifier(SubtitleEdge(edge: style.edge, textSize: size))
            .padding(.horizontal, size * 0.3)
            .padding(.vertical, size * 0.1)
            .background(style.hasBackground ? PictureColours.subtitleBox : .clear, in: RoundedRectangle(cornerRadius: size * 0.2))
    }
}

private struct SubtitleEdge: ViewModifier {
    let edge: SubtitleStyle.Edge
    let textSize: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        switch edge {
        case .none:
            content
        case .outline:
            // Four hard shadows, one per side, read as an outline.
            let width = max(1, textSize * 0.06)
            content
                .shadow(color: PictureColours.subtitleEdge, radius: 0, x: width, y: 0)
                .shadow(color: PictureColours.subtitleEdge, radius: 0, x: -width, y: 0)
                .shadow(color: PictureColours.subtitleEdge, radius: 0, x: 0, y: width)
                .shadow(color: PictureColours.subtitleEdge, radius: 0, x: 0, y: -width)
        case .shadow:
            content
                .shadow(color: PictureColours.subtitleEdge.opacity(0.8), radius: textSize * 0.08, x: textSize * 0.05, y: textSize * 0.05)
        }
    }
}
