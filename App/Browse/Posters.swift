import MarqueeCore
import SwiftUI

/// A 3 pt progress track: accent on trackOff (DESIGN §8.1). Decoration; the label carries the time left.
struct ProgressBar: View {
    let value: Double
    @Environment(\.theme) private var theme

    var body: some View {
        theme.trackOff
            .overlay(alignment: .leading) {
                theme.accent.scaleEffect(x: min(max(value, 0), 1), y: 1, anchor: .leading)
            }
            .frame(height: 3)
            .clipShape(Capsule())
            .accessibilityHidden(true)
    }
}

/// The badge on a poster, top trailing: the unwatched-episode count, or a check once watched. A solid
/// canvas pill with ink text, never glass (DESIGN §8.1).
struct PosterBadge: View {
    let item: PlexMetadata
    @Environment(\.theme) private var theme

    var body: some View {
        if let count = item.unwatchedBadge {
            pill { Text(count, format: .number).monospacedDigit() }
        } else if item.isWatched, item.type != .collection, item.type != .clip {
            pill { Image(systemName: "checkmark").fontWeight(.semibold) }
        }
    }

    private func pill(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .textRole(.caption)
            .foregroundStyle(theme.ink)
            .padding(.horizontal, Space.s2)
            .padding(.vertical, Space.s1 / 2)
            .frame(minWidth: Space.s6)
            .background(theme.canvas, in: Capsule())
            .padding(Space.s2)
            .accessibilityHidden(true)
    }
}

/// A poster in a shelf or grid: 2:3 art with its badge, a progress track when part-watched (kept as empty
/// space otherwise, so titles line up), and a one-line Caption title (DESIGN §8.1).
struct PosterCell: View {
    let item: PlexMetadata
    let width: CGFloat
    var zoomID: String?

    @Environment(\.theme) private var theme

    var body: some View {
        let radius = width >= 96 ? Radius.tile : Radius.control
        VStack(alignment: .leading, spacing: Space.s1) {
            PlexArtView(path: item.posterPath, size: Self.artSize(width: width), placeholder: placeholder)
                .overlay(alignment: .topTrailing) { PosterBadge(item: item) }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .zoomSource(zoomID, cornerRadius: radius)
            ProgressBar(value: item.progress ?? 0)
                .opacity(item.progress == nil ? 0 : 1)
            Text(item.posterTitle)
                .textRole(.caption)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.spokenSummary)
        .accessibilityIdentifier("poster.\(item.ratingKey)")
    }

    /// The 2:3 art at `width`, in whole points so the requested pixels match on every screen.
    static func artSize(width: CGFloat) -> CGSize {
        CGSize(width: width, height: (width * 1.5).rounded())
    }

    private var placeholder: String {
        item.type == .collection ? "square.stack" : "photo"
    }
}

/// Press feedback for posters and cards: the .97 scale, or the wash under Reduce Motion (DESIGN §9).
struct PressButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = Radius.tile

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pressed(configuration.isPressed, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension ButtonStyle where Self == PressButtonStyle {
    static var press: PressButtonStyle { PressButtonStyle() }
}

/// What a long press on a Home shelf's title offers (DESIGN §8.1).
struct ShelfMenu {
    let hide: @MainActor () -> Void
    let edit: @MainActor () -> Void
}

/// A shelf's title (a heading for VoiceOver's rotor) with "See all" as a trailing chevron (DESIGN §8.1).
struct ShelfHeader: View {
    let title: String
    var seeAll: Route?
    var menu: ShelfMenu?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            heading
            if let seeAll {
                NavigationLink(value: seeAll) {
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.ink2)
                        .frame(width: Size.target, height: Size.target)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("See all \(title)")
            }
        }
        .padding(.leading, Space.inset)
        .padding(.trailing, Space.s1)
    }

    @ViewBuilder
    private var heading: some View {
        let text = Text(title)
            .textRole(.title)
            .foregroundStyle(theme.ink)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
        if let menu {
            // The whole width answers a long press; the lifted preview is the title with a margin.
            text
                .contentShape(Rectangle())
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Radius.control, style: .continuous).inset(by: -Space.s2))
                .contextMenu {
                    Button("Hide This Row", systemImage: "eye.slash", action: menu.hide)
                    Button("Edit Home", systemImage: "slider.horizontal.3", action: menu.edit)
                }
                .accessibilityActions {
                    Button("Hide This Row", action: menu.hide)
                    Button("Edit Home", action: menu.edit)
                }
                .accessibilityIdentifier("shelf.\(title)")
        } else {
            text
        }
    }
}

/// A row of posters under its header; each opens its detail page, zooming from its art. The first six
/// fade in 30 ms apart the first time the shelf appears (DESIGN §9).
struct PosterShelf: View {
    let id: String
    let title: String
    let items: [PlexMetadata]
    var seeAll: Route?
    var menu: ShelfMenu?

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let prefetch = ArtPrefetcher()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            ShelfHeader(title: title, seeAll: seeAll, menu: menu)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Space.s3) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let zoomID = "\(id)/\(item.ratingKey)"
                        NavigationLink(value: Route.to(item, zoomID: zoomID)) {
                            PosterCell(item: item, width: Size.gridMin, zoomID: zoomID)
                        }
                        .buttonStyle(.press)
                        .opacity(appeared ? 1 : 0)
                        .animation(entrance(index), value: appeared)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, Space.inset, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
        .onAppear {
            guard !appeared else { return }
            appeared = true
            prefetch(items.map(\.posterPath), size: PosterCell.artSize(width: Size.gridMin))
        }
    }

    private func entrance(_ index: Int) -> Animation {
        if reduceMotion { return .linear(duration: 0.12) }
        return .easeOut(duration: 0.2).delay(Double(min(index, 5)) * 0.03)
    }
}

extension PosterShelf {
    /// A server hub as a shelf, with "See all" when the server holds more than it sent. A Home row
    /// passes its own id and title, since two libraries can hold hubs of one name.
    init(hub: PlexHub, id: String? = nil, title: String? = nil, menu: ShelfMenu? = nil) {
        let title = title ?? hub.title
        self.init(
            id: id ?? hub.id,
            title: title,
            items: hub.items,
            seeAll: hub.more ? hub.key.map { Route.hub(key: $0, title: title) } : nil,
            menu: menu
        )
    }
}

/// Columns for a poster grid (DESIGN §8.2): adaptive at a 104 pt minimum with 12 pt gutters, so three
/// at 390 pt; two at the first accessibility sizes and one, at most 240 pt wide, from accessibility 3.
struct PosterGridMetrics: Equatable {
    let columns: Int
    let cellWidth: CGFloat

    static let gutter = Space.s3

    init(width: CGFloat, typeSize: DynamicTypeSize) {
        let usable = max(width, Size.gridMin)
        if typeSize >= .accessibility3 {
            columns = 1
            cellWidth = min(usable, 240)
        } else if typeSize >= .accessibility1 {
            columns = 2
            cellWidth = ((usable - Self.gutter) / 2).rounded(.down)
        } else {
            columns = max(1, Int((usable + Self.gutter) / (Size.gridMin + Self.gutter)))
            cellWidth = ((usable - Self.gutter * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        }
    }

    var gridItems: [GridItem] {
        Array(repeating: GridItem(.fixed(cellWidth), spacing: Self.gutter, alignment: .top), count: columns)
    }
}

/// Lays its content out at the width it is offered, handed down in the same layout pass. Widths reported
/// back into state through a geometry callback measured content sized from them: on the iOS 27.0
/// simulator a tab's first layout reported an infinite width, Home grew without bound and crashed
/// (CALayerInvalidGeometry), and with infinite reports skipped the UI tests stalled at Home. A
/// non-finite offer reaches the content as 0.
struct WidthReader<Content: View>: View {
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { proxy in
            content(proxy.size.width.isFinite ? proxy.size.width : 0)
        }
    }
}
