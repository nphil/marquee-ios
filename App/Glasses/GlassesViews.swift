import MarqueeCore
import SwiftUI

/// The glasses' screen once they show Marquee: the player, Live TV or the page on top, with the panel
/// and the toast over it.
struct GlassesNavigatorView: View {
    let navigator: GlassesNavigator

    var body: some View {
        ZStack {
            if let player = navigator.player {
                GlassesPlayerView(model: player, scrub: navigator.scrub)
            } else if let live = navigator.live {
                GlassesLiveView(model: live)
            } else if let page = navigator.page {
                GlassesPageView(page: page)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("glasses.page.\(navigator.pages.count)")
                    .id(page.id)
                    .transition(.opacity)
            }
            if let panel = navigator.panel {
                GlassesPanelView(panel: panel)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if let toast = navigator.toast {
                GlassesToast(text: toast)
            }
        }
        .animation(Motion.label, value: navigator.page?.id)
        .animation(Motion.label, value: navigator.panel == nil)
        .animation(Motion.label, value: navigator.toast)
    }
}

extension GlassesTile.Shape {
    var size: CGSize {
        switch self {
        case .poster: GlassesCanvas.poster
        case .landscape: GlassesCanvas.landscape
        case .card, .channel: GlassesCanvas.card
        case .key: GlassesCanvas.key
        }
    }

    var hasCaption: Bool { self == .poster || self == .landscape }

    /// The tiles and their captions, without the row's title.
    var height: CGFloat {
        size.height + (hasCaption ? GlassesCanvas.captionGap + GlassesCanvas.caption + GlassesCanvas.subcaption : 0)
    }

    /// The letter board's rows sit close; other rows keep the full gap.
    var gapBelow: CGFloat { self == .key ? GlassesCanvas.titleGap : GlassesCanvas.rowGap }
}

extension GlassesRow {
    var height: CGFloat {
        (title == nil ? 0 : GlassesCanvas.rowTitle + GlassesCanvas.titleGap) + shape.height
    }
}

/// A page: its title, the opened title or the focused one named large, then the rows.
struct GlassesPageView: View {
    let page: GlassesPage
    @Environment(\.theme) private var theme
    @Environment(\.bigScreen) private var screen

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let backdrop = page.hero?.backdrop {
                GlassesBackdrop(path: backdrop)
            }
            VStack(alignment: .leading, spacing: 0) {
                // An opened title names itself in the hero below; the line keeps its height.
                let heading = page.query.isEmpty ? page.title : page.query
                Text(heading)
                    .glassesText(.title)
                    .foregroundStyle(page.query.isEmpty ? theme.ink2 : theme.ink)
                    .lineLimit(1)
                    .opacity(heading == page.hero?.title ? 0 : 1)
                    .accessibilityHidden(heading == page.hero?.title)
                    .frame(height: GlassesCanvas.header, alignment: .topLeading)
                if let hero = page.hero {
                    GlassesHeroView(hero: hero)
                } else {
                    focusLine
                }
                if let problem = page.problem {
                    GlassesNotice(symbol: "exclamationmark.triangle", title: "Couldn’t load", message: problem)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if page.rows.isEmpty {
                    Text(page.loading ? "Loading…" : "Nothing here yet")
                        .glassesText(.headline)
                        .foregroundStyle(theme.ink2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GlassesRowsView(page: page)
                }
            }
            .padding(.horizontal, screen.marginX)
            .padding(.vertical, screen.marginY)
        }
        .frame(width: screen.canvas.width, height: screen.canvas.height, alignment: .topLeading)
    }

    private var focusLine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(page.focusedTile?.title ?? " ")
                .glassesText(.headline)
                .foregroundStyle(theme.ink)
                .frame(height: GlassesCanvas.caption + GlassesCanvas.captionGap, alignment: .leading)
            Text(page.focusedTile?.subtitle ?? " ")
                .glassesText(.body)
                .foregroundStyle(theme.ink2)
        }
        .lineLimit(1)
        .frame(height: GlassesCanvas.focusLine, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// The opened title's artwork at the top right, fading into the see-through black.
private struct GlassesBackdrop: View {
    let path: String

    var body: some View {
        PlexArtView(path: path, size: GlassesCanvas.backdrop)
            .frame(width: GlassesCanvas.backdrop.width, height: GlassesCanvas.backdrop.height)
            .mask {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .center)
                    .mask { LinearGradient(colors: [.black, .clear], startPoint: .center, endPoint: .bottom) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .accessibilityHidden(true)
    }
}

private struct GlassesHeroView: View {
    let hero: GlassesHero
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: GlassesCanvas.titleGap) {
            Text(hero.title)
                .glassesText(.display)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            if let meta = hero.meta {
                Text(meta)
                    .glassesText(.body)
                    .foregroundStyle(theme.ink2)
            }
            if let overview = hero.overview {
                Text(overview)
                    .glassesText(.body)
                    .foregroundStyle(theme.ink)
                    .lineLimit(3)
                    .frame(width: GlassesCanvas.overviewWidth, alignment: .leading)
            }
        }
        .frame(height: GlassesCanvas.heroHeight, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// The rows, the focused one held at the top (the letter board stays put while it has the focus), and
/// in each row the focused tile kept second from the left once the row runs past the edge.
private struct GlassesRowsView: View {
    let page: GlassesPage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let rows = page.rows
            let tops = Self.tops(of: rows)
            let focused = min(page.focus.row, max(rows.count - 1, 0))
            let total = (tops.last ?? 0) + (rows.last?.height ?? 0)
            let pinned = rows.indices.contains(focused) && rows[focused].shape == .key ? 0 : tops[safe: focused] ?? 0
            let shift = min(pinned, max(total - proxy.size.height + GlassesCanvas.focusRoom, 0))
            let shown = max(focused - 1, 0)..<min(focused + 4, rows.count)
            ZStack(alignment: .topLeading) {
                ForEach(rows[shown]) { row in
                    let index = rows.firstIndex { $0.id == row.id } ?? 0
                    GlassesRowView(row: row, column: page.focus.column(inRow: index), focused: index == focused, width: proxy.size.width)
                        .offset(y: tops[index] - shift + GlassesCanvas.focusRoom)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .animation(Motion.spring(reduceMotion: reduceMotion), value: page.focus)
        }
        .clipShape(RowsClip())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("glasses.rows")
    }

    private static func tops(of rows: [GlassesRow]) -> [CGFloat] {
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for row in rows {
            tops.append(y)
            y += row.height + row.shape.gapBelow
        }
        return tops
    }
}

/// Cuts the rows off above and below only. A focused tile at the left or right grows past the rows'
/// edge into the margin; a tile gap's width lets that through without showing the tile scrolled off.
private struct RowsClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: -GlassesCanvas.tileGap, dy: 0))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private struct GlassesRowView: View {
    let row: GlassesRow
    let column: Int
    let focused: Bool
    let width: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        let size = row.shape.size
        let step = size.width + GlassesCanvas.tileGap
        let length = CGFloat(row.tiles.count) * step - GlassesCanvas.tileGap
        let shift = min(CGFloat(max(column - 1, 0)) * step, max(length - width, 0))
        VStack(alignment: .leading, spacing: GlassesCanvas.titleGap) {
            if let title = row.title {
                Text(title)
                    .glassesText(.headline)
                    .foregroundStyle(focused ? theme.ink : theme.ink2)
                    .lineLimit(1)
                    .frame(height: GlassesCanvas.rowTitle, alignment: .bottomLeading)
            }
            HStack(alignment: .top, spacing: GlassesCanvas.tileGap) {
                ForEach(Array(row.tiles.enumerated()), id: \.element.id) { index, tile in
                    GlassesTileView(tile: tile, shape: row.shape, focused: focused && index == column)
                }
            }
            .offset(x: -shift)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// A tile: its picture or its words on a raised surface, and under a picture the title and a line.
/// The focused tile grows and takes the focus ring, the one highlight on the glasses.
private struct GlassesTileView: View {
    let tile: GlassesTile
    let shape: GlassesTile.Shape
    let focused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let size = shape.size
        let corners = RoundedRectangle(cornerRadius: shape == .key ? GlassesCanvas.radius / 2 : GlassesCanvas.radius, style: .continuous)
        VStack(alignment: .leading, spacing: GlassesCanvas.captionGap) {
            face(size)
                .frame(width: size.width, height: size.height)
                .background(theme.glassRaised)
                .overlay(alignment: .bottom) { progress(width: size.width) }
                .clipShape(corners)
                .overlay { corners.strokeBorder(theme.focus, lineWidth: GlassesCanvas.focusRing).opacity(focused ? 1 : 0) }
                .scaleEffect(focused ? GlassesCanvas.focusScale : 1)
                .zIndex(focused ? 1 : 0)
            if shape.hasCaption {
                VStack(alignment: .leading, spacing: 0) {
                    Text(tile.title)
                        .glassesText(.label)
                        .foregroundStyle(focused ? theme.ink : theme.ink2)
                        .frame(height: GlassesCanvas.caption, alignment: .leading)
                    Text(tile.subtitle ?? " ")
                        .glassesText(.caption)
                        .foregroundStyle(theme.ink3)
                        .frame(height: GlassesCanvas.subcaption, alignment: .leading)
                }
                .lineLimit(1)
                .frame(width: size.width, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.title)
        .accessibilityValue(tile.subtitle ?? "")
        .accessibilityAddTraits(focused ? .isSelected : [])
        .accessibilityIdentifier("glasses.tile.\(tile.id)")
    }

    @ViewBuilder
    private func face(_ size: CGSize) -> some View {
        switch tile.art {
        case .plex(let path):
            PlexArtView(path: path, size: size)
        case .file(let file):
            LocalArtView(file: file, size: size)
        case .channel(let channel):
            HStack(spacing: GlassesCanvas.tileGap) {
                ChannelLogo(channel: channel, side: GlassesCanvas.logo - GlassesCanvas.tileGap)
                VStack(alignment: .leading, spacing: 0) {
                    Text(channel.number)
                        .glassesText(.caption)
                        .foregroundStyle(theme.ink2)
                    Text(tile.title)
                        .glassesText(.label)
                        .foregroundStyle(theme.ink)
                    Text(tile.subtitle ?? " ")
                        .glassesText(.caption)
                        .foregroundStyle(theme.ink3)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, GlassesCanvas.titleGap)
        case .symbol(let name):
            if shape == .key {
                Image(systemName: name)
                    .font(.system(size: GlassesText.headline.size, weight: .semibold))
                    .foregroundStyle(theme.ink)
            } else {
                HStack(spacing: GlassesCanvas.titleGap) {
                    Image(systemName: name)
                        .font(.system(size: GlassesText.headline.size, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(tile.title)
                            .glassesText(.headline)
                            .foregroundStyle(theme.ink)
                        if let subtitle = tile.subtitle {
                            Text(subtitle)
                                .glassesText(.caption)
                                .foregroundStyle(theme.ink2)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, GlassesCanvas.tileGap)
            }
        case .none:
            Text(tile.title)
                .glassesText(shape == .key ? .headline : .label)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }

    @ViewBuilder
    private func progress(width: CGFloat) -> some View {
        if let progress = tile.progress {
            Capsule()
                .fill(theme.trackOff)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: (width - GlassesCanvas.tileGap) * min(max(progress, 0), 1))
                }
                .frame(height: GlassesCanvas.barHeight)
                .padding(GlassesCanvas.titleGap)
        }
    }
}

/// A title's options or the player's tracks, down the right of the screen.
struct GlassesPanelView: View {
    let panel: GlassesPanel
    @Environment(\.theme) private var theme
    @Environment(\.bigScreen) private var screen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let lines = Self.lines(panel.options)
        VStack(alignment: .leading, spacing: GlassesCanvas.titleGap) {
            Text(panel.title)
                .glassesText(.headline)
                .foregroundStyle(theme.ink)
                .lineLimit(2)
            GeometryReader { proxy in
                let focusTop = lines.first { $0.option?.offset == panel.focus }?.top ?? 0
                let shift = max(focusTop + GlassesCanvas.option * 2 - proxy.size.height, 0)
                ZStack(alignment: .topLeading) {
                    ForEach(lines) { line in
                        lineView(line)
                            .offset(y: line.top - shift)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .animation(Motion.spring(reduceMotion: reduceMotion), value: panel.focus)
            }
            .clipped()
        }
        .padding(GlassesCanvas.tileGap)
        .frame(width: GlassesCanvas.panelWidth)
        .frame(maxHeight: .infinity)
        .background(theme.sheet, in: RoundedRectangle(cornerRadius: GlassesCanvas.radius, style: .continuous))
        .padding(.vertical, screen.marginY)
        .padding(.trailing, screen.marginX)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("glasses.panel")
    }

    @ViewBuilder
    private func lineView(_ line: Line) -> some View {
        if let entry = line.option {
            let option = entry.element
            let focused = entry.offset == panel.focus
            HStack(spacing: GlassesCanvas.titleGap) {
                Text(option.title)
                    .glassesText(.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if option.checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: GlassesText.body.size, weight: .semibold))
                }
            }
            .foregroundStyle(focused ? theme.focusInk : theme.ink)
            .padding(.horizontal, GlassesCanvas.tileGap)
            .frame(height: GlassesCanvas.option)
            .background(focused ? theme.focus : .clear, in: RoundedRectangle(cornerRadius: GlassesCanvas.radius / 2, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(option.checked ? .isSelected : [])
        } else {
            Text(line.section ?? "")
                .glassesText(.caption)
                .foregroundStyle(theme.ink2)
                .frame(height: GlassesCanvas.subcaption + GlassesCanvas.titleGap, alignment: .bottomLeading)
                .padding(.horizontal, GlassesCanvas.tileGap)
        }
    }

    /// Each option, with a heading where its section starts.
    struct Line: Identifiable {
        let id: String
        let top: CGFloat
        var section: String?
        var option: (offset: Int, element: GlassesOption)?
    }

    static func lines(_ options: [GlassesOption]) -> [Line] {
        var lines: [Line] = []
        var top: CGFloat = 0
        var section: String?
        for (index, option) in options.enumerated() {
            if let heading = option.section, heading != section {
                lines.append(Line(id: "section.\(heading)", top: top, section: heading))
                top += GlassesCanvas.subcaption + GlassesCanvas.titleGap
            }
            section = option.section
            lines.append(Line(id: option.id, top: top, option: (index, option)))
            top += GlassesCanvas.option
        }
        return lines
    }
}

private struct GlassesToast: View {
    let text: String
    @Environment(\.theme) private var theme
    @Environment(\.bigScreen) private var screen

    var body: some View {
        Text(text)
            .glassesText(.body)
            .foregroundStyle(theme.ink)
            .padding(.horizontal, GlassesCanvas.tileGap)
            .frame(height: GlassesCanvas.option)
            .background(theme.glassRaised, in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, screen.marginY)
            .transition(.opacity)
            .accessibilityIdentifier("glasses.toast")
    }
}
