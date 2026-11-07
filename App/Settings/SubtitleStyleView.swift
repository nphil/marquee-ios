import MarqueeCore
import SwiftUI

/// How subtitles look (behaviour spec §3, "Subtitle look"), saved for the active profile: a preset, every
/// setting under it, and a preview that follows each change.
struct SubtitleStyleView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @State private var sample = SubtitleSample.accents
    @State private var scene = SubtitleScene.daylight

    var body: some View {
        @Bindable var session = session
        let look = session.settings.subtitleStyle
        List {
            Section {
                SubtitlePreview(look: look, sample: $sample, scene: scene)
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text(look.isCustom ? "Your own mix of settings. Pick a preset to start over." : look.preset.about)
                    .foregroundStyle(theme.ink2)
                    .accessibilityIdentifier("style.about")
            }
            .listRowBackground(Color.clear)

            Section {
                Picker("Preset", selection: preset) {
                    ForEach(SubtitleLook.Preset.allCases, id: \.self) { preset in
                        Text(preset.title).tag(Optional(preset))
                    }
                    if look.isCustom {
                        Text("Custom").tag(SubtitleLook.Preset?.none)
                    }
                }
                .accessibilityIdentifier("style.preset")
                picker("Sample Text", "sample", $sample, SubtitleSample.allCases, \.title)
                picker("Sample Scene", "scene", $scene, SubtitleScene.allCases, \.title)
            } header: {
                Text("Look")
            }
            .listRowBackground(theme.sheet)

            Section {
                picker("Font", "font", $session.settings.subtitleStyle.font, SubtitleLook.Font.allCases, \.title)
                picker("Size", "size", $session.settings.subtitleStyle.size, SubtitleLook.sizes, Self.percent)
                picker("Colour", "colour", $session.settings.subtitleStyle.colour, SubtitleLook.TextColour.allCases, \.title)
                picker("Opacity", "opacity", $session.settings.subtitleStyle.opacity, SubtitleLook.opacities, Self.percent)
                Toggle("Bold", isOn: $session.settings.subtitleStyle.isBold)
                    .tint(theme.accent)
                    .accessibilityIdentifier("style.bold")
            } header: {
                Text("Text")
            }
            .listRowBackground(theme.sheet)

            Section {
                picker("Edge Style", "edge", $session.settings.subtitleStyle.edge, SubtitleLook.Edge.allCases, \.title)
                if look.edge != .none {
                    picker("Edge Width", "edgeWidth", $session.settings.subtitleStyle.edgeWidth, SubtitleLook.edgeWidths, Self.pixels)
                }
            } header: {
                Text("Edge")
            }
            .listRowBackground(theme.sheet)

            Section {
                picker("Background", "background", $session.settings.subtitleStyle.background, SubtitleLook.Background.allCases, \.title)
                if look.background != .none {
                    picker("Colour", "backgroundColour", $session.settings.subtitleStyle.backgroundColour, SubtitleLook.BoxColour.allCases, \.title)
                    picker("Opacity", "backgroundOpacity", $session.settings.subtitleStyle.backgroundOpacity, SubtitleLook.opacities, Self.percent)
                    picker("Rounded Corners", "corners", $session.settings.subtitleStyle.cornerRadius, SubtitleLook.cornerRadii) { radius in
                        radius == 0 ? "Square" : Self.pixels(radius)
                    }
                    picker("Padding", "padding", $session.settings.subtitleStyle.padding, SubtitleLook.paddings, Self.pixels)
                }
            } header: {
                Text("Background")
            }
            .listRowBackground(theme.sheet)

            Section {
                picker("Position", "position", $session.settings.subtitleStyle.anchor, SubtitleLook.Anchor.allCases, \.title)
                picker("Edge Distance", "distance", $session.settings.subtitleStyle.edgeDistance, SubtitleLook.edgeDistances, Self.pixels)
                picker("Line Spacing", "lineSpacing", $session.settings.subtitleStyle.lineSpacing, SubtitleLook.lineSpacings, Self.percent)
            } header: {
                Text("Position")
            } footer: {
                Text("Sizes and distances are pixels of a 1080-line picture, so subtitles keep their place on any screen.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            Section {
                Toggle(isOn: $session.settings.subtitleStyle.blendsWithVideo) {
                    Text("Blend with Video")
                    Text("Keeps the text just under full brightness")
                }
                .tint(theme.accent)
                .accessibilityIdentifier("style.blend")
                picker("Reveal as Spoken", "reveal", $session.settings.subtitleStyle.reveal, SubtitleLook.Reveal.allCases, \.title)
                picker("File Styling", "fileStyling", $session.settings.subtitleStyle.keepsFileStyling, [true, false]) { keeps in
                    keeps ? "Keep" : "My Look"
                }
                Button {
                    session.settings.subtitleStyle.resetToPreset()
                } label: {
                    Text("Reset to Preset")
                    Text("Back to \(look.preset.title)’s own settings")
                }
                .disabled(!look.isCustom)
                .accessibilityIdentifier("style.reset")
            } header: {
                Text("Behaviour")
            } footer: {
                Text("Keep draws a styled file’s own colours; My Look draws it in this look. Image subtitles keep their own look.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("Subtitle Style")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.default, value: look.edge == .none)
        .animation(.default, value: look.background == .none)
    }

    /// Picking a preset sets every look field; "Custom" only shows, and only while the look is one.
    private var preset: Binding<SubtitleLook.Preset?> {
        Binding {
            let look = session.settings.subtitleStyle
            return look.isCustom ? nil : look.preset
        } set: { preset in
            if let preset { session.settings.subtitleStyle.apply(preset) }
        }
    }

    private func picker<Value: Hashable>(
        _ title: String, _ id: String, _ selection: Binding<Value>, _ values: [Value], _ label: @escaping (Value) -> String
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(values, id: \.self) { value in
                Text(label(value)).tag(value)
            }
        }
        .accessibilityIdentifier("style.\(id)")
    }

    private static func percent(_ value: Int) -> String { "\(value)%" }
    private static func pixels(_ value: Int) -> String { "\(value) px" }
}

/// A 16:9 scene with a sample subtitle in the look, so the edge and background show over a real kind of
/// picture. Played in landscape, the picture spans the phone's short side, which the preview's width
/// matches, so the text takes the size it has on a video. Tapping it shows the next sample. The rows read
/// out the same choices, so the preview is hidden from VoiceOver.
private struct SubtitlePreview: View {
    let look: SubtitleLook
    @Binding var sample: SubtitleSample
    let scene: SubtitleScene

    /// About an iPhone's short side. A landscape list row is far wider, and would make both the frame and
    /// the text larger than any video shows them.
    private static let maxWidth: CGFloat = 400

    var body: some View {
        GeometryReader { proxy in
            let pictureHeight = proxy.size.width
            let distance = CGFloat(look.edgeDistance) * pictureHeight / 1080
            SubtitleLine(text: sample.text, look: look, pictureHeight: pictureHeight)
                .padding(.horizontal, proxy.size.width * 0.06)
                .padding(look.anchor == .top ? .top : .bottom, distance)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: look.anchor == .top ? .top : .bottom)
            Text("Sample \(sample.number) of \(SubtitleSample.allCases.count) · \(sample.title)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Space.s2)
                .padding(.vertical, Space.s1)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(Space.s2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: look.anchor == .top ? .bottomLeading : .topLeading)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(scene.picture)
        .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { sample = sample.next }
        .frame(maxWidth: Self.maxWidth)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// Text that tests a look: scripts with accents, ideographs and right-to-left writing, symbols, italics, and
/// a styled file's own colour.
enum SubtitleSample: CaseIterable {
    case accents, cjk, rtl, symbols, italics, styled

    var title: String {
        switch self {
        case .accents: "Accents"
        case .cjk: "CJK"
        case .rtl: "Arabic, Hebrew"
        case .symbols: "Symbols, Emoji"
        case .italics: "Italics"
        case .styled: "Styled File"
        }
    }

    var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    var next: SubtitleSample {
        let all = Self.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }

    var text: AttributedString {
        switch self {
        case .accents:
            return AttributedString("Crème brûlée for the señor?\nNo, déjà vu: the naïve façade.")
        case .cjk:
            return AttributedString("明日は雨が降るでしょう。\n내일은 비가 올 거예요.")
        case .rtl:
            return AttributedString("مرحبًا، كيف حالك؟\nשלום, מה שלומך?")
        case .symbols:
            return AttributedString("♪ Rain on the window ♪\n[door creaks] 😮 3½ hours → 4")
        case .italics:
            var aside = AttributedString("Previously…")
            aside.inlinePresentationIntent = .emphasized
            var stress = AttributedString("never")
            stress.inlinePresentationIntent = .stronglyEmphasized
            return aside + AttributedString("\nShe said ") + stress + AttributedString(" again.")
        case .styled:
            var speaker = AttributedString("Mission control:")
            speaker[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Color(red: 0.55, green: 0.85, blue: 1)
            speaker.inlinePresentationIntent = .emphasized
            return speaker + AttributedString("\nWe have liftoff.")
        }
    }
}

/// Pictures to judge a look against: a bright day, a dark night and white snow.
enum SubtitleScene: CaseIterable {
    case daylight, night, snow

    var title: String {
        switch self {
        case .daylight: "Daylight"
        case .night: "Night"
        case .snow: "Snow"
        }
    }

    var picture: LinearGradient {
        let stops: [Color] = switch self {
        case .daylight:
            [Color(red: 0.45, green: 0.68, blue: 0.92), Color(red: 0.86, green: 0.9, blue: 0.9), Color(red: 0.78, green: 0.7, blue: 0.5)]
        case .night:
            [Color(red: 0.02, green: 0.03, blue: 0.08), Color(red: 0.07, green: 0.09, blue: 0.2), Color(red: 0.16, green: 0.12, blue: 0.1)]
        case .snow:
            [Color(red: 0.86, green: 0.9, blue: 0.95), Color(white: 0.98), Color(red: 0.9, green: 0.92, blue: 0.95)]
        }
        return LinearGradient(colors: stops, startPoint: .top, endPoint: .bottom)
    }
}

extension SubtitleLook.Preset {
    var title: String {
        switch self {
        case .blend: "Blend with Video"
        case .appleTV: "Apple TV"
        case .classic: "Classic"
        case .netflix: "Netflix"
        case .outline: "Outline"
        case .largePrint: "Large Print"
        case .highContrast: "High Contrast"
        case .marquee: "Marquee"
        }
    }

    var about: String {
        switch self {
        case .blend: "Soft, slightly translucent text with a diffuse shadow, held just under full brightness."
        case .appleTV: "White text with a soft shadow, modelled on Apple TV’s default look."
        case .classic: "White text on a black box with square corners: the look of broadcast closed captions."
        case .netflix: "White text with a hard drop shadow and no box."
        case .outline: "White text with a thick black outline and no box. The most readable choice over bright or busy pictures."
        case .largePrint: "Bigger, bolder text with an outline, for reading from further away."
        case .highContrast: "Yellow text with a black outline on a dark box, for the most contrast."
        case .marquee: "Bold white text with a thin outline: Marquee’s own look."
        }
    }
}

extension SubtitleLook.Font {
    var title: String {
        switch self {
        case .standard: "Default"
        case .serif: "Serif"
        case .mono: "Monospace"
        case .legible: "Easy to Read"
        }
    }
}

extension SubtitleLook.TextColour {
    var title: String {
        switch self {
        case .white: "White"
        case .softWhite: "Soft White"
        case .yellow: "Yellow"
        case .cyan: "Cyan"
        case .green: "Green"
        case .pink: "Pink"
        }
    }
}

extension SubtitleLook.Edge {
    var title: String {
        switch self {
        case .none: "None"
        case .outline: "Outline"
        case .dropShadow: "Drop Shadow"
        case .raised: "Raised"
        case .depressed: "Depressed"
        case .softShadow: "Soft Shadow"
        }
    }
}

extension SubtitleLook.Background {
    var title: String {
        switch self {
        case .none: "None"
        case .lineBox: "Line Box"
        case .window: "Window"
        }
    }
}

extension SubtitleLook.BoxColour {
    var title: String {
        switch self {
        case .black: "Black"
        case .plum: "Plum"
        case .slate: "Slate"
        case .brown: "Brown"
        }
    }
}

extension SubtitleLook.Anchor {
    var title: String { self == .bottom ? "Bottom" : "Top" }
}

extension SubtitleLook.Reveal {
    var title: String {
        switch self {
        case .off: "Off"
        case .word: "Word by Word"
        case .line: "Line by Line"
        }
    }
}
