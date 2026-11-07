import MarqueeCore
import SwiftUI

/// A channel in the portrait list (docs/LIVE-TV.md §6.4): logo and number, the airing at the chosen
/// time with its times and progress, then the one after it. One tap plays a channel that is on; a later
/// airing opens its programme sheet.
struct GuideRow: View {
    let channel: LiveChannel
    let airing: LiveAiring?
    let next: LiveAiring?
    let now: Date
    let mark: RecordingMark?
    let canRecord: Bool
    let isFavourite: Bool
    let actions: GuideActions
    /// The colour under the row, painted into it so the long-press preview is opaque.
    var surface: Color = .clear

    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize

    private var isOn: Bool { airing?.isOn(at: now) ?? true }
    private var dimmed: Bool { !channel.device.isAlive }

    var body: some View {
        Button(action: tap) {
            layout
                .padding(.horizontal, Space.inset)
                .padding(.vertical, Space.s3)
                .frame(maxWidth: .infinity, minHeight: Size.rowMin, alignment: .leading)
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) { separator }
        }
        .buttonStyle(RowPressStyle())
        .opacity(dimmed ? 0.55 : 1)
        // The long-press preview is a snapshot of the row, and the screen behind the menu stays sharp: at
        // accessibility sizes the preview sits over the next row, whose text showed through a clear one.
        .background(surface)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LiveText.spoken(channel, airing: airing, at: now, mark: mark))
        .accessibilityHint(isOn ? "Plays the channel" : "Shows the programme")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Watch") { actions.play(channel) }
        .accessibilityActions {
            if let airing, canRecord, airing.end > now, mark == nil {
                Button("Record") { actions.record(airing, channel) }
            }
            if let airing {
                Button("Details") { actions.open(airing, channel) }
            }
            Button(isFavourite ? "Remove from Favourites" : "Add to Favourites") { actions.toggleFavourite(channel) }
        }
        .accessibilityIdentifier("livetv.row.\(channel.id)")
    }

    // MARK: Layout

    /// Logo beside the text; at accessibility sizes the logo row sits above the text so titles get the
    /// full width.
    @ViewBuilder
    private var layout: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack(spacing: Space.s3) {
                    ChannelLogo(channel: channel, side: 40)
                    Text(channel.label)
                        .textRole(.label)
                        .monospacedDigit()
                        .foregroundStyle(theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    glyphs
                }
                programme
            }
        } else {
            HStack(alignment: .top, spacing: Space.s3) {
                VStack(spacing: Space.s1) {
                    ChannelLogo(channel: channel, side: 40)
                    Text(channel.number)
                        .textRole(.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.ink2)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(minWidth: 40)
                VStack(alignment: .leading, spacing: Space.s1) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                        title
                        Spacer(minLength: 0)
                        glyphs
                    }
                    details
                }
            }
        }
    }

    @ViewBuilder
    private var programme: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            title
            details
        }
    }

    private var title: some View {
        Text(airing?.title ?? channel.title)
            .textRole(.headline)
            .foregroundStyle(theme.ink)
            .lineLimit(typeSize.isAccessibilitySize ? nil : typeSize >= .xLarge ? 2 : 1)
            .fixedSize(horizontal: false, vertical: typeSize.isAccessibilitySize)
    }

    @ViewBuilder
    private var details: some View {
        if let airing {
            HStack(spacing: Space.s2) {
                Text(timeLine(airing))
                    .textRole(.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.ink2)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                if airing.isNew {
                    TagChip(text: "NEW")
                }
            }
            if airing.isOn(at: now) {
                ProgressLine(progress: airing.progress(at: now), height: 3)
                    .padding(.vertical, 2)
            }
            if let next {
                Text("\(Text("Next").foregroundStyle(theme.ink3))  \(Text(LiveText.time(next.start)).monospacedDigit())  \(next.title)")
                    .textRole(.label)
                    .foregroundStyle(theme.ink2)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
        } else {
            Text("No guide data")
                .textRole(.caption)
                .foregroundStyle(theme.ink2)
        }
    }

    /// "8:00 – 8:30 PM · 12 min left" for an airing on now, "Tonight 10:00 – 11:00 PM" for a later one.
    private func timeLine(_ airing: LiveAiring) -> String {
        if airing.isOn(at: now) {
            return "\(LiveText.range(airing)) · \(LiveText.left(airing, at: now))"
        }
        return LiveText.when(airing, now: now)
    }

    @ViewBuilder
    private var glyphs: some View {
        if let mark {
            RecordGlyph(mark: mark)
        } else if isFavourite {
            Image(systemName: "star.fill")
                .font(.caption)
                .foregroundStyle(theme.ink3)
                .accessibilityHidden(true)
        }
    }

    /// A hairline under the text column, as far left as the text starts.
    private var separator: some View {
        Rectangle()
            .fill(theme.edge)
            .frame(height: 1)
            .padding(.leading, typeSize.isAccessibilitySize ? Space.inset : Space.inset + 40 + Space.s3)
    }

    // MARK: Actions

    private func tap() {
        if let airing, !airing.isOn(at: now) {
            actions.open(airing, channel)
        } else {
            actions.play(channel)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Watch", systemImage: "play.fill") { actions.play(channel) }
        if let airing, canRecord, airing.end > now, mark == nil {
            Button("Record", systemImage: "record.circle") { actions.record(airing, channel) }
        }
        if let airing {
            Button("Details", systemImage: "info.circle") { actions.open(airing, channel) }
        }
        Button(isFavourite ? "Remove from Favourites" : "Add to Favourites", systemImage: isFavourite ? "star.slash" : "star") {
            actions.toggleFavourite(channel)
        }
    }
}

/// Programme progress: an accent fill on a trackOff capsule. The fill is scaled rather than resized, so
/// the 30 s tick redraws without a layout pass.
struct ProgressLine: View {
    let progress: Double
    var height: CGFloat = 3
    var fill: Color?
    var track: Color?
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(track ?? theme.trackOff)
            Rectangle()
                .fill(fill ?? theme.accent)
                .scaleEffect(x: min(max(progress, 0), 1), y: 1, anchor: .leading)
        }
        .frame(height: height)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// NEW, LIVE, HD: a small outlined tag in caption type.
struct TagChip: View {
    let text: String
    var tint: Color?
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .tracking(0.4)
            .foregroundStyle(tint ?? theme.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay { Capsule().strokeBorder((tint ?? theme.ink2).opacity(0.8), lineWidth: 1) }
            .fixedSize()
    }
}

/// A row's press: a wash over the full width (DESIGN §9), since a scaled list row would shift its
/// neighbours' edges.
private struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowPressLabel(configuration: configuration)
    }
}

private struct RowPressLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.theme) private var theme

    var body: some View {
        configuration.label
            .background(theme.focus.opacity(configuration.isPressed ? (theme.mode == .dark ? 0.07 : 0.06) : 0))
            .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
    }
}
