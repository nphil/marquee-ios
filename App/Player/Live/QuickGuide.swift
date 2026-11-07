import MarqueeCore
import SwiftUI

/// The guide over the picture (docs/LIVE-TV.md §6.9): the last three channels, then what every channel
/// airs now and next. A tap changes channel and puts the guide away. It takes the trailing side of the
/// screen when the phone is on its side, and the lower part upright, so the picture stays in view.
struct QuickGuide: View {
    let model: LivePlaybackModel
    let isWide: Bool
    /// Opens an airing's programme sheet.
    let open: (ProgrammeSelection) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: isWide ? .trailing : .bottom) {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { model.setGuide(false) }
                    .accessibilityHidden(true)
                panel
                    .frame(
                        width: isWide ? min(420, proxy.size.width * 0.5) : nil,
                        height: isWide ? nil : max(320, proxy.size.height * 0.6)
                    )
            }
        }
        .accessibilityAction(.escape) { model.setGuide(false) }
    }

    private var panel: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: Radius.sheet,
            bottomLeadingRadius: isWide ? Radius.sheet : 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: isWide ? 0 : Radius.sheet,
            style: .continuous
        )
        return VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let recent = recentChannels
                        if !recent.isEmpty {
                            SectionTitle(text: "Recent")
                            RecentStrip(model: model, channels: recent)
                            SectionTitle(text: "All Channels")
                        }
                        ForEach(model.store.lineup) { channel in
                            row(channel)
                                .id(channel.id)
                        }
                    }
                    .padding(.bottom, Space.s4)
                }
                .scrollIndicators(.hidden)
                // The recent channels are the quickest way back, so they stay in view; without them the
                // list opens on the channel playing.
                .onAppear {
                    if recentChannels.isEmpty { proxy.scrollTo(model.channel.id, anchor: .center) }
                }
            }
        }
        // Opaque, so the picture behind never shows through the text (DESIGN §5.1). Only the fill runs to
        // the screen's edge; the rows stay clear of the Dynamic Island and the home indicator.
        .background {
            shape.fill(theme.roles.sheet.over(theme.roles.canvas).color)
                .overlay { shape.strokeBorder(theme.edge, lineWidth: 1) }
                .ignoresSafeArea(edges: isWide ? [.trailing, .vertical] : .bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("liveplayer.quickguide")
    }

    private var header: some View {
        HStack(spacing: Space.s3) {
            Text("Guide")
                .textRole(.title)
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button("Close", systemImage: "xmark") { model.setGuide(false) }
                .labelStyle(.iconOnly)
                .buttonStyle(.round)
                .accessibilityLabel("Close guide")
                .accessibilityIdentifier("liveplayer.guide.close")
        }
        .padding(.leading, Space.inset)
        .padding(.trailing, Space.s2)
        .padding(.top, Space.s3)
        .padding(.bottom, Space.s1)
    }

    /// Up to three channels watched before the one playing, most recent first.
    private var recentChannels: [LiveChannel] {
        let guide = model.store.guide
        return model.store.recents
            .filter { $0 != model.channel.id }
            .compactMap { guide.channel($0) }
            .prefix(3)
            .map { $0 }
    }

    private func row(_ channel: LiveChannel) -> some View {
        let store = model.store
        let airings = store.guide.nowAndNext(on: channel.id, at: store.now)
        let playing = channel.id == model.channel.id
        return GuideRow(
            channel: channel,
            airing: airings.now,
            next: airings.next,
            now: store.now,
            mark: airings.now.flatMap { store.mark(for: $0) },
            canRecord: store.canRecord,
            isFavourite: store.isFavourite(channel),
            actions: actions
        )
        .background(playing ? theme.focus.opacity(theme.mode == .dark ? 0.07 : 0.06) : .clear)
        .overlay(alignment: .leading) {
            if playing {
                Capsule()
                    .fill(theme.accent)
                    .frame(width: 4)
                    .padding(.vertical, Space.s3)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityValue(playing ? "Playing" : "")
    }

    private var actions: GuideActions {
        GuideActions(
            play: { channel in watch(channel) },
            open: { airing, channel in open(ProgrammeSelection(airing: airing, channel: channel)) },
            record: { airing, channel in open(ProgrammeSelection(airing: airing, channel: channel)) },
            toggleFavourite: { channel in
                Haptics.selection()
                model.store.toggleFavourite(channel)
            }
        )
    }

    private func watch(_ channel: LiveChannel) {
        model.setGuide(false)
        guard channel.id != model.channel.id || model.isStopped || model.state == .idle else { return }
        model.tune(channel)
    }
}

/// A small heading over a part of the guide.
private struct SectionTitle: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .textRole(.label)
            .foregroundStyle(theme.ink2)
            .padding(.horizontal, Space.inset)
            .padding(.top, Space.s3)
            .padding(.bottom, Space.s2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The last channels as tiles, one tap back to each.
private struct RecentStrip: View {
    let model: LivePlaybackModel
    let channels: [LiveChannel]

    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: Space.s2)) : AnyLayout(HStackLayout(alignment: .top, spacing: Space.s2))
        layout {
            ForEach(channels) { channel in
                tile(channel)
            }
        }
        .padding(.horizontal, Space.inset)
    }

    private func tile(_ channel: LiveChannel) -> some View {
        let store = model.store
        let airing = store.guide.airing(on: channel.id, at: store.now)
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        return Button {
            model.setGuide(false)
            model.tune(channel)
        } label: {
            VStack(alignment: .leading, spacing: Space.s1) {
                ChannelLogo(channel: channel, side: 40)
                Text(channel.label)
                    .textRole(.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.ink2)
                    .lineLimit(1)
                Text(airing?.title ?? channel.title)
                    .textRole(.label)
                    .foregroundStyle(theme.ink)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .multilineTextAlignment(.leading)
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, minHeight: Size.target, alignment: .topLeading)
            .background(theme.glass, in: shape)
            .overlay { shape.strokeBorder(theme.edge, lineWidth: 1) }
            .contentShape(shape)
        }
        .buttonStyle(TilePressStyle(shape: shape))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LiveText.spoken(channel, airing: airing, at: store.now, mark: nil))
        .accessibilityHint("Plays the channel")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("liveplayer.recent.\(channel.id)")
    }
}

/// The press on a tile: .97 over 90 ms (DESIGN §9).
private struct TilePressStyle<S: Shape>: ButtonStyle {
    let shape: S

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pressed(configuration.isPressed, in: shape)
    }
}
