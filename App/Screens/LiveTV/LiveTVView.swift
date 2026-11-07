import MarqueeCore
import SwiftUI

/// The Live TV tab (docs/LIVE-TV.md §6): the chosen server's guide as a now-and-next list in portrait,
/// and as a time grid on its side and at regular width. At accessibility text sizes the list shows in
/// every orientation.
struct LiveTVView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.plexLibrary) private var library
    @Environment(\.theme) private var theme
    @State private var store: LiveTVStore?

    var body: some View {
        ZStack {
            if let store {
                LiveGuideScreen(store: store)
            } else {
                GuideSkeleton(grid: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
        .navigationTitle("Live TV")
        // Each profile keeps its own favourites and recent channels.
        .task(id: StoreKey(library: library?.instance, profile: session.user?.uuid)) {
            guard let library else {
                store = nil
                return
            }
            let store = LiveTVStore(library: library, serverName: session.server?.name ?? "The server", profile: session.user?.uuid)
            self.store = store
            await store.start()
        }
    }

    private struct StoreKey: Hashable {
        let library: ObjectIdentifier?
        let profile: String?
    }
}

private struct LiveGuideScreen: View {
    let store: LiveTVStore

    @Environment(AppSession.self) private var session
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// The time strip's choice; nil is now.
    @State private var slot: Date?
    /// Bumped to bring the grid back to now.
    @State private var anchor = 0
    @State private var nowVisible = true
    @State private var details: ProgrammeSelection?
    @State private var showsRecordings = false
    @State private var playing: LivePlaybackModel?
    /// Watch in the programme sheet: plays once the sheet has gone, so the player can present.
    @State private var watchAfterSheet: LiveChannel?

    /// The grid on its side and at regular width; the list in portrait and at accessibility sizes
    /// (docs/LIVE-TV.md §6.3).
    private var usesGrid: Bool {
        !typeSize.isAccessibilitySize && (horizontalSizeClass == .regular || verticalSizeClass == .compact)
    }

    var body: some View {
        content
            .navigationBarTitleDisplayMode(usesGrid ? .inline : .large)
            .toolbar {
                if store.canRecord {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Recordings", systemImage: "record.circle") { showsRecordings = true }
                            .accessibilityIdentifier("livetv.recordings")
                    }
                }
            }
            .navigationDestination(isPresented: $showsRecordings) { RecordingsView(store: store) }
            .sheet(item: $details, onDismiss: { playAfterSheet() }) { selection in
                ProgrammeSheet(store: store, selection: selection) { channel in
                    watchAfterSheet = channel
                    details = nil
                }
            }
            .fullScreenCover(item: $playing) { model in
                LivePlayerView(model: model, outerTheme: theme, outerScheme: colorScheme) {
                    model.close()
                    playing = nil
                }
            }
            .onAppear { backToNow() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                store.tick()
                backToNow()
            }
            .task {
                // The now line, progress and "left" move every 30 s; a stale guide reloads.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    store.tick()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("livetv.screen")
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading:
            GuideSkeleton(grid: usesGrid)
        case .noDVR:
            EmptyState(
                title: "Live TV isn't set up on \(store.serverName)",
                message: "Set it up in Plex on a computer.",
                systemImage: "antenna.radiowaves.left.and.right.slash"
            )
            .accessibilityIdentifier("livetv.noDVR")
        case .failed(let message):
            EmptyState(
                title: "The guide didn't load",
                message: message,
                systemImage: "exclamationmark.triangle",
                action: EmptyState.Action(title: "Try Again", systemImage: "arrow.clockwise") {
                    Task { await store.refresh() }
                }
            )
            .accessibilityIdentifier("livetv.failed")
        case .ready:
            if usesGrid { grid } else { list }
        }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    notices
                    rows
                } header: {
                    VStack(spacing: 0) {
                        CategoryChips(store: store)
                        TimeStrip(now: store.now, end: store.guide.to, slot: $slot)
                        Rectangle()
                            .fill(theme.edge)
                            .frame(height: 1)
                    }
                    .background(theme.canvas)
                }
            }
        }
        .refreshable { await store.refresh() }
        .accessibilityIdentifier("livetv.list")
    }

    @ViewBuilder
    private var rows: some View {
        let channels = store.channels
        if channels.isEmpty {
            categoryEmpty
        } else {
            let at = slot ?? store.now
            ForEach(channels) { channel in
                let airing = store.guide.airing(on: channel.id, at: at)
                GuideRow(
                    channel: channel,
                    airing: airing,
                    next: store.guide.next(on: channel.id, after: airing?.end ?? at),
                    now: store.now,
                    mark: airing.flatMap { store.mark(for: $0) },
                    canRecord: store.canRecord,
                    isFavourite: store.isFavourite(channel),
                    actions: actions,
                    surface: theme.canvas
                )
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        VStack(spacing: 0) {
            CategoryChips(store: store)
            notices
            if store.channels.isEmpty {
                categoryEmpty
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                GuideGrid(
                    channels: store.channels,
                    guide: store.guide,
                    now: store.now,
                    recordings: store.recordings,
                    canRecord: store.canRecord,
                    favourites: store.favourites,
                    theme: theme,
                    anchor: anchor,
                    actions: actions,
                    nowVisible: $nowVisible
                )
                .overlay(alignment: .bottomTrailing) {
                    if !nowVisible {
                        Button {
                            anchor += 1
                        } label: {
                            Label("Now", systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(.pill)
                        .padding(Space.inset)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
                        .accessibilityHint("Scrolls the guide back to now")
                        .accessibilityIdentifier("livetv.jumpToNow")
                    }
                }
                .animation(reduceMotion ? .linear(duration: 0.12) : .spring(response: 0.26, dampingFraction: 1), value: nowVisible)
            }
        }
    }

    // MARK: Notices

    /// Old guide data, a tuner that stopped answering, or no guide data at all (docs/LIVE-TV.md §6.11).
    @ViewBuilder
    private var notices: some View {
        if let problem = store.refreshProblem {
            GuideNotice(symbol: "exclamationmark.triangle.fill", tint: theme.warning, text: problem + age)
        }
        if let dvr = store.dvr, !dvr.devices.isEmpty, dvr.devices.allSatisfy({ !$0.isAlive }) {
            GuideNotice(symbol: "antenna.radiowaves.left.and.right.slash", tint: theme.warning, text: "The tuner isn't responding.")
        }
        if store.guide.airings.values.allSatisfy(\.isEmpty), !store.guide.channels.isEmpty {
            GuideNotice(symbol: "calendar.badge.exclamationmark", tint: theme.ink2, text: "No guide data yet." + age)
        }
    }

    private var age: String {
        guard let refreshedAt = store.refreshedAt else { return "" }
        return " Last updated \(LiveText.time(refreshedAt))."
    }

    @ViewBuilder
    private var categoryEmpty: some View {
        switch store.category {
        case .favourites:
            CategoryMessage(symbol: "star", title: "No favourites yet", message: "Touch and hold a channel, then choose Add to Favourites.")
        case .recent:
            CategoryMessage(symbol: "clock", title: "Nothing watched yet", message: "Channels you watch show here.")
        case .genre(let filter):
            if store.genreKeys == nil {
                GuideSkeletonRows()
            } else {
                CategoryMessage(symbol: "tv", title: "No \(filter.title) channels", message: "None of the channels carries \(filter.title.lowercased()) right now.")
            }
        case .all:
            CategoryMessage(symbol: "tv", title: "No channels", message: "No tuner has channels turned on. Choose them in Plex on a computer.")
        }
    }

    // MARK: Actions

    private var actions: GuideActions {
        GuideActions(
            play: { channel in play(channel) },
            open: { airing, channel in details = ProgrammeSelection(airing: airing, channel: channel) },
            record: { airing, channel in quickRecord(airing, channel) },
            toggleFavourite: { channel in
                Haptics.selection()
                let adding = !store.isFavourite(channel)
                store.toggleFavourite(channel)
                toasts.show(adding ? "Added \(channel.label) to Favourites" : "Removed \(channel.label) from Favourites")
            }
        )
    }

    /// Record from the guide's menu takes this episode, or the movie, with the server's settings. A
    /// programme offered only as a whole show opens its sheet to choose.
    private func quickRecord(_ airing: LiveAiring, _ channel: LiveChannel) {
        Task {
            do {
                let options = try await store.recordOptions(for: airing)
                guard let option = options.first(where: { $0.kind == .episode }) ?? options.first(where: { $0.kind == .movie }) else {
                    details = ProgrammeSelection(airing: airing, channel: channel)
                    return
                }
                try await store.record(option, values: [:], airing: airing)
                Haptics.success()
                toasts.show(airing.isOn(at: store.now) ? "Recording \(airing.title)" : "\(airing.title) will record")
            } catch {
                Haptics.error()
                toasts.show(LiveText.recordingProblem(error, server: store.serverName))
            }
        }
    }

    /// Opens the live player; a film playing, in Picture in Picture too, stops first.
    private func play(_ channel: LiveChannel) {
        session.player.stopAll()
        playing = LivePlaybackModel(store: store, channel: channel, readsTunerDirectly: session.settings.readsTunerDirectly)
    }

    private func playAfterSheet() {
        guard let channel = watchAfterSheet else { return }
        watchAfterSheet = nil
        play(channel)
    }

    private func backToNow() {
        slot = nil
        anchor += 1
    }
}

// MARK: - Header

/// All, Favourites, Recent and the provider's genres (docs/LIVE-TV.md §6.4).
private struct CategoryChips: View {
    let store: LiveTVStore

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.s2) {
                ForEach(store.categories) { category in
                    SelectChip(title: category.title, isSelected: store.category == category) {
                        Haptics.selection()
                        store.select(category)
                    }
                    .accessibilityIdentifier("livetv.category.\(category.id)")
                }
            }
            .padding(.horizontal, Space.inset)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Channels")
        .accessibilityIdentifier("livetv.categories")
    }
}

/// Now, then each half hour the guide reaches, with Tonight and Tomorrow marking where they start. Plain
/// times over a sliding underline, so the strip reads as a timeline rather than a second row of filters.
private struct TimeStrip: View {
    let now: Date
    let end: Date
    @Binding var slot: Date?
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var underline

    private struct Slot: Identifiable {
        let date: Date
        /// "Tonight" or "Tomorrow" before the first slot of that part of the day.
        let mark: String?
        var id: Date { date }
    }

    private var slots: [Slot] {
        let first = Date(timeIntervalSinceReferenceDate: ((now.timeIntervalSinceReferenceDate / 1800).rounded(.down) + 1) * 1800)
        let last = min(end, now.addingTimeInterval(LiveTVStore.fullSpan))
        var result: [Slot] = []
        var date = first
        var previous = LiveText.day(now, now: now)
        while date < last {
            let day = LiveText.day(date, now: now)
            result.append(Slot(date: date, mark: day != previous ? day : nil))
            previous = day
            date = date.addingTimeInterval(1800)
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    TimeTab(title: "Now", isLive: true, isSelected: slot == nil, underline: underline) {
                        pick(nil)
                    }
                    .accessibilityIdentifier("livetv.slot.now")
                    .id(Date.distantPast)
                    ForEach(Array(slots.enumerated()), id: \.element.id) { index, item in
                        if let mark = item.mark {
                            Text(mark)
                                .textRole(.caption)
                                .foregroundStyle(theme.ink3)
                                .padding(.leading, Space.s3)
                                .accessibilityHidden(true)
                        }
                        TimeTab(title: LiveText.time(item.date), isSelected: slot == item.date, underline: underline) {
                            pick(item.date)
                        }
                        .accessibilityLabel("\(LiveText.day(item.date, now: now)) \(LiveText.time(item.date))")
                        .accessibilityIdentifier("livetv.slot.\(index + 1)")
                    }
                }
                // The first time lines up with the screen inset; each tab carries its own side padding.
                .padding(.horizontal, Space.inset - Space.s3)
                .animation(Motion.spring(reduceMotion: reduceMotion), value: slot)
            }
            .scrollIndicators(.hidden)
            .onChange(of: slot) { _, new in
                if new == nil { proxy.scrollTo(Date.distantPast, anchor: .leading) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Time")
        .accessibilityIdentifier("livetv.times")
    }

    private func pick(_ date: Date?) {
        Haptics.selection()
        slot = date
    }
}

/// One time in the strip: ink over the accent underline when chosen, quieter ink otherwise. Now carries
/// the live dot.
private struct TimeTab: View {
    let title: String
    var isLive = false
    let isSelected: Bool
    let underline: Namespace.ID
    let action: @MainActor () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s1) {
                if isLive {
                    Circle()
                        .fill(theme.live)
                        .frame(width: 6, height: 6)
                }
                Text(title)
                    .textRole(.label)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? theme.ink : theme.ink2)
            .padding(.horizontal, Space.s3)
            .frame(minHeight: Size.target)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Capsule()
                        .fill(theme.accent)
                        .frame(height: 3)
                        .padding(.horizontal, Space.s3)
                        .matchedGeometryEffect(id: "underline", in: underline)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A chip that picks one of a set: solid accent when chosen, outlined otherwise. 32 pt to see, 48 pt to
/// touch (docs/LIVE-TV.md §6.4).
struct SelectChip: View {
    let title: String
    let isSelected: Bool
    let action: @MainActor () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Text(title)
                .textRole(.label)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(isSelected ? theme.accentInk : theme.ink)
                .padding(.horizontal, Space.s3)
                .frame(minHeight: Space.s7)
                .background {
                    Capsule().fill(isSelected ? theme.accent : theme.canvas)
                }
                .overlay {
                    if !isSelected { Capsule().strokeBorder(theme.ink2.opacity(0.6), lineWidth: 1) }
                }
                .frame(minHeight: Size.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.label, value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Notices and placeholders

/// One line about the guide's state above the channels: a symbol in its role colour and a sentence.
private struct GuideNotice: View {
    let symbol: String
    let tint: Color
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .textRole(.label)
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2)
        .background(theme.glass, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(theme.edge, lineWidth: 1)
        }
        .padding(.horizontal, Space.inset)
        .padding(.vertical, Space.s2)
        .accessibilityElement(children: .combine)
    }
}

/// An empty category: a symbol, a title and one line, at the top where the rows would be.
private struct CategoryMessage: View {
    let symbol: String
    let title: String
    let message: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Space.s2) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(theme.ink2)
                .accessibilityHidden(true)
            Text(title)
                .textRole(.headline)
                .foregroundStyle(theme.ink)
            Text(message)
                .textRole(.body)
                .foregroundStyle(theme.ink2)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.s7)
        .padding(.vertical, Space.s8)
        .accessibilityElement(children: .combine)
    }
}

/// The guide before it arrives: static fills where the chips and rows will be (DESIGN §11), never a
/// spinner.
struct GuideSkeleton: View {
    let grid: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s2) {
                ForEach([44, 92, 72, 64, 80], id: \.self) { width in
                    Capsule().fill(theme.trackOff).frame(width: CGFloat(width), height: Space.s7)
                }
            }
            .padding(.horizontal, Space.inset)
            .frame(height: Size.target)
            if grid {
                GuideSkeletonGrid()
            } else {
                GuideSkeletonRows()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .accessibilityElement()
        .accessibilityLabel("Loading the guide")
        .accessibilityIdentifier("livetv.loading")
    }
}

private struct GuideSkeletonRows: View {
    @Environment(\.theme) private var theme
    private static let widths: [CGFloat] = [180, 140, 200, 120]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { row in
                HStack(alignment: .top, spacing: Space.s3) {
                    RoundedRectangle(cornerRadius: ChannelLogo.radius(side: 40), style: .continuous)
                        .fill(theme.trackOff)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Capsule().fill(theme.trackOff).frame(width: Self.widths[row % Self.widths.count], height: 14)
                        Capsule().fill(theme.trackOff).frame(width: 110, height: 10)
                        Capsule().fill(theme.trackOff).frame(maxWidth: .infinity).frame(height: 3)
                    }
                }
                .padding(.horizontal, Space.inset)
                .padding(.vertical, Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct GuideSkeletonGrid: View {
    @Environment(\.theme) private var theme
    private static let widths: [CGFloat] = [150, 210, 180, 240]

    var body: some View {
        VStack(spacing: Space.s1) {
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: Space.s1) {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(theme.trackOff)
                        .frame(width: Size.gridMin - Space.s1, height: Size.rowMin)
                    ForEach(0..<4, id: \.self) { column in
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .fill(theme.trackOff.opacity(column == 0 ? 1 : 0.6))
                            .frame(width: Self.widths[(row + column) % Self.widths.count], height: Size.rowMin)
                    }
                }
            }
        }
        .padding(.top, Space.s7)
        .padding(.leading, Space.s1)
        .accessibilityHidden(true)
    }
}
