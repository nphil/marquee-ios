import MarqueeCore
import os
import SwiftUI

/// One press of a remote, as the big screen takes it, on glasses or a TV. This is the only way input
/// reaches `GlassesNavigator.handle(_:)`: the iPhone's own touch surface (`RemoteSurfaceView`) sends it, and
/// another phone's link maps its messages to it. The navigator answers with the haptic cue to play.
enum GlassesInput: Equatable {
    case move(FocusMove)
    case select
    case back
    /// The thumb went down and stayed: the options on a page, the scrubber in the player.
    case holdBegan
    case holdEnded
    /// While held: the thumb has slid `dx` across a `width`-point surface.
    case slide(dx: Double, width: Double)
    /// While held in the player: tilt's fine adjustment, in seconds.
    case nudge(TimeInterval)
    /// The thumb touched down; a coast stops.
    case panBegan
    /// The thumb is `dx`, `dy` points from where it touched down, `at` when (this phone's clock; nil when
    /// not known). Whole pages scroll with it continuously; panels, the player and live TV step.
    case pan(dx: Double, dy: Double, at: TimeInterval?)
    /// The thumb lifted, moving at `vx`, `vy` points a second.
    case panEnded(vx: Double, vy: Double, at: TimeInterval?)
}

/// One tile on a glasses page. The page decides what choosing it does.
struct GlassesTile: Identifiable {
    enum Shape { case poster, landscape, card, key, channel }

    enum Art {
        /// A Plex path, or an absolute image address such as TMDB's.
        case plex(String?)
        case file(URL)
        case symbol(String)
        case channel(LiveChannel)
        case none
    }

    let id: String
    var title: String
    var subtitle: String?
    var art: Art = .none
    /// How much has been watched, 0 to 1.
    var progress: Double?
    /// The title behind the tile, for Play from Start among the options.
    var item: PlexMetadata?
    let select: @MainActor () -> Void
}

struct GlassesRow: Identifiable {
    let id: String
    var title: String?
    var shape: GlassesTile.Shape
    var tiles: [GlassesTile]
}

/// The opened title at the top of a detail page.
struct GlassesHero {
    var title: String
    var meta: String?
    var overview: String?
    var backdrop: String?
}

/// Where a page draws its focus between items, in rows and columns: whole numbers are the items themselves.
struct GlassesGlide: Equatable {
    var row: Double
    var column: Double
}

/// One page on the glasses: its rows and where the focus sits in them.
@MainActor @Observable
final class GlassesPage: Identifiable {
    let id = UUID()
    var title: String
    var hero: GlassesHero?
    private(set) var rows: [GlassesRow] = []
    var focus: FocusGrid
    private(set) var loading = true
    var problem: String?
    /// Search: what has been typed.
    var query = ""
    /// Runs after each focus move, as when a library loads its next page near the end.
    @ObservationIgnored var onMove: (() -> Void)?
    /// Where the page draws its focus while the thumb or a move has it between items; nil at rest, when the
    /// focus itself says. Set by `GlassesScroller` once a frame.
    var glide: GlassesGlide?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(title: String, style: FocusGrid.Style = .shelves) {
        self.title = title
        focus = FocusGrid(style: style)
    }

    func setRows(_ rows: [GlassesRow], loading: Bool = false) {
        self.rows = rows
        focus.update(rows: rows.map(\.tiles.count))
        self.loading = loading
    }

    func failed(_ message: String) {
        problem = message
        loading = false
    }

    var focusedTile: GlassesTile? {
        guard rows.indices.contains(focus.row) else { return nil }
        let tiles = rows[focus.row].tiles
        return tiles.indices.contains(focus.column) ? tiles[focus.column] : nil
    }

    func run(_ work: @escaping @MainActor () async -> Void) {
        tasks.append(Task { await work() })
    }

    func cancel() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }
}

struct GlassesOption: Identifiable {
    let id: String
    var title: String
    var section: String?
    var checked = false
    let run: @MainActor () -> Void
}

/// A list over the page or the player: a title's options, the player's tracks.
@MainActor @Observable
final class GlassesPanel {
    let title: String
    let options: [GlassesOption]
    var focus: Int

    init(title: String, options: [GlassesOption]) {
        self.title = title
        self.options = options
        focus = options.firstIndex(where: \.checked) ?? 0
    }
}

/// The glasses' pages and what the remote does on them (DESIGN §8.9). Data comes through the
/// session's own library, Seerr, downloads and Live TV, as on the phone; only the screens differ.
@MainActor @Observable
final class GlassesNavigator {
    private(set) var pages: [GlassesPage] = []
    private(set) var panel: GlassesPanel?
    private(set) var toast: String?
    /// Live TV playing on the glasses.
    private(set) var live: LivePlaybackModel?
    /// The player's scrub while the thumb holds it.
    private(set) var scrub: Scrub?

    @ObservationIgnored let session: AppSession
    @ObservationIgnored private weak var center: GlassesCenter?
    @ObservationIgnored private var startedFor: ObjectIdentifier?
    @ObservationIgnored private var liveStore: LiveTVStore?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// Cues that come after the press: a request sent or refused.
    @ObservationIgnored var onCue: ((HapticCue) -> Void)?
    @ObservationIgnored private let scroller: GlassesScroller
    @ObservationIgnored private var legacySteps = SwipeSteps()
    @ObservationIgnored private var legacyCoast: Task<Void, Never>?
    @ObservationIgnored private var localLatency = LatencyStats()
    @ObservationIgnored private var linkedLatency = LatencyStats()
    @ObservationIgnored private var latencyShownAt: TimeInterval = 0
    private static let log = Logger(subsystem: "com.nphil.marquee", category: "remote")
    /// How late a touch on this phone's own remote, and on a linked phone's, was when the page applied it
    /// ("p50 8 ms · p95 14 ms"); refreshed about once a second, for Settings and the debug log.
    private(set) var localSummary: String?
    private(set) var linkedSummary: String?

    static let gridColumns = 6
    static let channelColumns = 3
    private static let libraryPage = 60
    private static let searchDelay = Duration.milliseconds(500)
    private static let toastTime = Duration.milliseconds(2500)

    init(session: AppSession, center: GlassesCenter) {
        self.session = session
        self.center = center
        scroller = GlassesScroller(screen: { [weak center] in center?.displayScreen })
        scroller.onLatency = { [weak self] seconds, linked in self?.record(seconds, linked: linked) }
    }

    var page: GlassesPage? { pages.last }

    /// The film or episode playing on the glasses.
    var player: PlayerModel? { session.player.onGlasses ? session.player.active : nil }

    /// Home for the signed-in server; nothing changes while it stays the same.
    func start() {
        guard let library = session.library, startedFor != library.instance else { return }
        startedFor = library.instance
        pages.forEach { $0.cancel() }
        panel = nil
        pages = [homePage()]
    }

    func close() {
        pages.forEach { $0.cancel() }
        pages = []
        panel = nil
        startedFor = nil
        searchTask?.cancel()
        scroller.stop()
        closeLive()
    }

    /// What the phone says and VoiceOver reads: the focused thing.
    var focusTitle: String {
        if let panel, panel.options.indices.contains(panel.focus) { return panel.options[panel.focus].title }
        if let player { return player.title }
        if let live { return live.shown.title }
        return page?.focusedTile?.title ?? page?.title ?? ""
    }

    var focusDetail: String? {
        if let panel { return panel.title }
        if let player { return player.isPlaying ? "Playing" : "Paused" }
        if live != nil { return "Live TV" }
        return page?.focusedTile?.subtitle ?? page?.title
    }

    // MARK: Input

    /// Runs one press of this phone's own remote and returns the cue the phone plays for it.
    func handle(_ input: GlassesInput) -> HapticCue? {
        handle(input, cues: nil)
    }

    /// Runs one press, and for a linked phone's, `cues` takes the cues that follow a pan; a pan from this
    /// phone's own remote cues through `onCue`.
    func handle(_ input: GlassesInput, cues: GlassesScroller.Cue?) -> HapticCue? {
        switch input {
        case .panBegan:
            return panBegan()
        case .pan(let dx, let dy, let time):
            return pan(dx: dx, dy: dy, at: time, cues: cues)
        case .panEnded(let vx, let vy, _):
            return panEnded(vx: vx, vy: vy, cues: cues)
        default:
            interruptPan()
        }
        if let panel { return handle(input, in: panel) }
        if let player { return handle(input, player: player) }
        if let live { return handle(input, live: live) }
        guard let page else { return nil }
        return handle(input, on: page)
    }

    // MARK: Pan

    /// The page the thumb scrolls continuously: the page itself, not a panel, the player or live TV, which
    /// step by whole items.
    private var scrollingPage: GlassesPage? {
        panel == nil && player == nil && live == nil ? page : nil
    }

    private func panBegan() -> HapticCue? {
        legacySteps = SwipeSteps()
        legacyCoast?.cancel()
        legacyCoast = nil
        if let page = scrollingPage { scroller.touchDown(on: page) }
        return nil
    }

    /// Where a pan's cues go: a linked phone's reply, or this phone's own remote.
    private func cueSink(_ cues: GlassesScroller.Cue?) -> GlassesScroller.Cue {
        if let cues { return cues }
        return { [weak self] cue in self?.onCue?(cue) }
    }

    private func pan(dx: Double, dy: Double, at time: TimeInterval?, cues: GlassesScroller.Cue?) -> HapticCue? {
        let sink = cueSink(cues)
        if let page = scrollingPage {
            scroller.pan(dx: dx, dy: dy, at: time, on: page, linked: cues != nil, cue: sink)
            return nil
        }
        if let time { record(ProcessInfo.processInfo.systemUptime - time, linked: cues != nil) }
        for move in legacySteps.moved(dx: dx, dy: dy) {
            if let cue = step(move) { sink(cue) }
        }
        return nil
    }

    private func panEnded(vx: Double, vy: Double, cues: GlassesScroller.Cue?) -> HapticCue? {
        if let page = scrollingPage {
            scroller.lifted(vx: vx, vy: vy, on: page)
            return nil
        }
        let sink = cueSink(cues)
        let release = legacySteps.released(vx: vx, vy: vy)
        if let move = release.step, let cue = step(move) { sink(cue) }
        if let coast = release.coast { coastLegacy(coast.move, speed: coast.speed, cues: sink) }
        return nil
    }

    /// One whole item on a panel, the player or live TV.
    private func step(_ move: FocusMove) -> HapticCue? {
        if let panel { return handle(.move(move), in: panel) }
        if let player { return handle(.move(move), player: player) }
        if let live { return handle(.move(move), live: live) }
        return nil
    }

    /// A hard flick keeps stepping after the thumb lifts, slowing as it goes, and stops at an end.
    private func coastLegacy(_ move: FocusMove, speed: Double, cues: @escaping GlassesScroller.Cue) {
        let length = move.isHorizontal ? SwipeSteps.stepAcross : SwipeSteps.stepDown
        let times = SwipeSteps.coast(speed: speed, step: length)
        legacyCoast = Task { [weak self] in
            var clock: TimeInterval = 0
            for time in times {
                try? await Task.sleep(for: .seconds(time - clock))
                clock = time
                guard !Task.isCancelled, let self, let cue = self.step(move) else { return }
                cues(cue)
                if cue == .edge { return }
            }
        }
    }

    /// Any other input ends a pan or coast where it is.
    private func interruptPan() {
        legacyCoast?.cancel()
        legacyCoast = nil
        scroller.interrupt()
    }

    private func record(_ seconds: TimeInterval, linked: Bool) {
        if linked { linkedLatency.add(seconds) } else { localLatency.add(seconds) }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - latencyShownAt >= 1 else { return }
        latencyShownAt = now
        localSummary = localLatency.summary
        linkedSummary = linkedLatency.summary
        #if DEBUG
        Self.log.debug("touch to apply, local \(self.localSummary ?? "-", privacy: .public), linked \(self.linkedSummary ?? "-", privacy: .public)")
        #endif
    }

    private func handle(_ input: GlassesInput, on page: GlassesPage) -> HapticCue? {
        switch input {
        case .move(let move):
            let before = (row: page.focus.row, column: page.focus.column)
            guard page.focus.move(move) == .moved else { return .edge }
            page.onMove?()
            scroller.moved(on: page, from: before)
            return .focusStep
        case .select:
            guard let tile = page.focusedTile else { return .edge }
            tile.select()
            return .select
        case .back:
            guard pages.count > 1 else { return .edge }
            pages.removeLast().cancel()
            return .back
        case .holdBegan:
            openOptions(for: page.focusedTile)
            return .select
        case .holdEnded, .slide, .nudge, .panBegan, .pan, .panEnded:
            return nil
        }
    }

    private func handle(_ input: GlassesInput, in panel: GlassesPanel) -> HapticCue? {
        switch input {
        case .move(.up):
            guard panel.focus > 0 else { return .edge }
            panel.focus -= 1
            return .focusStep
        case .move(.down):
            guard panel.focus < panel.options.count - 1 else { return .edge }
            panel.focus += 1
            return .focusStep
        case .move:
            return .edge
        case .select:
            guard panel.options.indices.contains(panel.focus) else { return .edge }
            let option = panel.options[panel.focus]
            self.panel = nil
            option.run()
            return .select
        case .back:
            self.panel = nil
            return .back
        case .holdBegan, .holdEnded, .slide, .nudge, .panBegan, .pan, .panEnded:
            return nil
        }
    }

    private func handle(_ input: GlassesInput, player model: PlayerModel) -> HapticCue? {
        switch input {
        case .select:
            switch model.offer {
            case .skipIntro: model.skipIntro()
            case .upNext: model.next()
            case .lowerQuality: model.playAtLowerQuality()
            case nil:
                model.togglePlay()
                return .playPause
            }
            return .select
        case .move(let move) where move.isHorizontal:
            model.skip(by: (move == .right ? 1 : -1) * TimeInterval(session.settings.skipInterval))
            return .focusStep
        case .move(.up):
            model.showChrome()
            return .focusStep
        case .move:
            openTracks(model)
            return .select
        case .back:
            session.player.close(model)
            return .back
        case .holdBegan:
            guard model.duration > 0 else { return .edge }
            model.beginScrub()
            model.showChrome()
            scrub = Scrub(at: model.time, duration: model.duration)
            return .select
        case .slide(let dx, let width):
            guard var scrub else { return nil }
            let tick = scrub.slid(dx, of: width)
            self.scrub = scrub
            return Self.cue(for: tick)
        case .nudge(let seconds):
            guard var scrub else { return nil }
            let tick = scrub.nudge(by: seconds)
            self.scrub = scrub
            return Self.cue(for: tick)
        case .holdEnded:
            guard let scrub else { return nil }
            model.endScrub(at: scrub.time)
            self.scrub = nil
            return .select
        case .panBegan, .pan, .panEnded:
            return nil
        }
    }

    private static func cue(for tick: Scrub.Tick) -> HapticCue? {
        switch tick {
        case .none: nil
        case .detent: .scrubDetent
        case .end: .edge
        }
    }

    private func handle(_ input: GlassesInput, live model: LivePlaybackModel) -> HapticCue? {
        switch input {
        case .select:
            model.togglePlay()
            return .playPause
        case .move(let move) where move.isHorizontal:
            model.skip(by: (move == .right ? 1 : -1) * model.skipInterval)
            return .focusStep
        case .move(let move):
            model.surf(by: move == .up ? 1 : -1)
            return .focusStep
        case .back:
            closeLive()
            return .back
        case .holdBegan:
            let options = [
                GlassesOption(id: "live", title: "Go Live") { model.goLive() },
                phoneAppOption(),
                GlassesOption(id: "home", title: "Home") { [weak self] in self?.goHome() },
            ]
            panel = GlassesPanel(title: model.shown.title, options: options)
            return .select
        case .holdEnded, .slide, .nudge, .panBegan, .pan, .panEnded:
            return nil
        }
    }

    // MARK: Panels

    private func openOptions(for tile: GlassesTile?) {
        var options: [GlassesOption] = []
        if let item = tile?.item, item.viewOffset > 0, item.type == .movie || item.type == .episode {
            options.append(GlassesOption(id: "start", title: "Play from Start") { [weak self] in self?.play(item, fromStart: true) })
        }
        options.append(phoneAppOption())
        if pages.count > 1 {
            options.append(GlassesOption(id: "home", title: "Home") { [weak self] in self?.goHome() })
        }
        panel = GlassesPanel(title: tile?.title ?? page?.title ?? "Options", options: options)
    }

    /// Subtitles and audio, then the rest of what the player offers.
    func openTracks(_ model: PlayerModel) {
        var options: [GlassesOption] = []
        if let tracks = model.tracks {
            options.append(GlassesOption(id: "subtitle.off", title: "Off", section: "Subtitles", checked: model.subtitleChoice == .off) {
                model.pickSubtitle(.off)
            })
            for track in tracks.visibleSubtitles {
                options.append(GlassesOption(
                    id: "subtitle.\(track.id)", title: track.label, section: "Subtitles", checked: model.subtitleChoice == .track(track.id)
                ) { model.pickSubtitle(.track(track.id)) })
            }
            for track in tracks.audio {
                options.append(GlassesOption(id: "audio.\(track.id)", title: track.label, section: "Audio", checked: model.audio?.id == track.id) {
                    model.pickAudio(track)
                })
            }
        }
        // The phone's own buttons do nothing over HDMI, so the screen offers the steps; the list stays open.
        for (id, title, step) in [("volume.up", "Volume Up", 1), ("volume.down", "Volume Down", -1)] {
            options.append(GlassesOption(id: id, title: title, section: "Volume") { [weak self] in
                OutputVolume.shared.step(step)
                self?.openTracks(model)
                self?.panel?.focus = self?.panel?.options.firstIndex { $0.id == id } ?? 0
            })
        }
        if model.hasNext {
            options.append(GlassesOption(id: "next", title: "Next Episode", section: "Playback") { model.next() })
        }
        var phone = phoneAppOption()
        phone.section = "Playback"
        options.append(phone)
        panel = GlassesPanel(title: model.title, options: options)
    }

    func closePanel() {
        panel = nil
    }

    private func phoneAppOption() -> GlassesOption {
        GlassesOption(id: "phone", title: "Use the Phone App") { [weak self] in self?.center?.leaveRemote() }
    }

    private func goHome() {
        closeLive()
        while pages.count > 1 { pages.removeLast().cancel() }
    }

    func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: Self.toastTime)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Opening things

    private func push(_ page: GlassesPage) {
        pages.append(page)
    }

    func play(_ item: PlexMetadata, fromStart: Bool = false) {
        closeLive()
        session.play(item: item, fromStart: fromStart)
    }

    private func open(_ item: PlexMetadata) {
        switch item.type {
        case .movie: push(moviePage(item))
        case .show: push(showPage(item))
        case .season: push(seasonPage(item))
        case .collection: push(collectionPage(item))
        default: play(item)
        }
    }

    private func closeLive() {
        live?.close()
        live = nil
    }

    private func tune(_ channel: LiveChannel, store: LiveTVStore) {
        session.player.stopAll()
        live?.close()
        let session = session
        let model = LivePlaybackModel(
            store: store, channel: channel, readsTunerDirectly: session.settings.readsTunerDirectly,
            skipInterval: TimeInterval(session.settings.skipInterval),
            playbackActive: { session.downloads.setPlaybackActive($0) }
        )
        live = model
        model.start()
    }

    // MARK: Pages

    private func homePage() -> GlassesPage {
        let page = GlassesPage(title: "Home")
        page.run { [weak self, weak page] in
            guard let self, let page, let library = session.library else { return }
            let sections = (try? await library.sections()) ?? []
            let menu = menuRow(sections)
            page.setRows([menu], loading: true)
            do {
                let layout = session.settings.homeRows
                let loaded = try await HomeRows.load(from: library, libraries: layout.shownLibraries, hidden: session.settings.hiddenLibraries)
                let shown = layout.arrange(loaded).filter { $0.shown && !$0.hub.items.isEmpty }
                page.setRows([menu] + shown.map(row))
                // Continue Watching is what most visits are for.
                if shown.first?.isContinueWatching == true { page.focus.focus(row: 1, column: 0) }
            } catch {
                if !Task.isCancelled { page.failed(error.localizedDescription) }
            }
        }
        return page
    }

    /// Search, the libraries and the plugins' places, as cards above Home's rows.
    private func menuRow(_ sections: [PlexLibrarySection]) -> GlassesRow {
        var tiles = [GlassesTile(id: "search", title: "Search", art: .symbol("magnifyingglass")) { [weak self] in
            guard let self else { return }
            push(searchPage())
        }]
        let hidden = session.settings.hiddenLibraries
        for section in sections where (section.type == .movie || section.type == .show) && !hidden.contains(HomeLayout.libraryID(section)) {
            tiles.append(GlassesTile(id: "library.\(section.key)", title: section.title, art: .symbol(section.type == .movie ? "film" : "tv")) { [weak self] in
                guard let self else { return }
                push(libraryPage(section))
            })
        }
        if session.seerr.isEnabled {
            tiles.append(GlassesTile(id: "requests", title: "Requests", art: .symbol("plus.circle")) { [weak self] in
                guard let self else { return }
                push(requestsPage())
            })
        }
        if session.downloads.records.contains(where: { $0.phase == .done }) {
            tiles.append(GlassesTile(id: "downloads", title: "Downloads", art: .symbol("arrow.down.circle")) { [weak self] in
                guard let self else { return }
                push(downloadsPage())
            })
        }
        tiles.append(GlassesTile(id: "live", title: "Live TV", art: .symbol("antenna.radiowaves.left.and.right")) { [weak self] in
            guard let self else { return }
            push(livePage())
        })
        return GlassesRow(id: "menu", title: nil, shape: .card, tiles: tiles)
    }

    private func row(_ row: HomeRow) -> GlassesRow {
        let wide = row.isContinueWatching
        return GlassesRow(id: row.id, title: row.title, shape: wide ? .landscape : .poster, tiles: row.hub.items.map { tile(for: $0, wide: wide) })
    }

    private func tile(for item: PlexMetadata, wide: Bool, inShow: Bool = false) -> GlassesTile {
        let episode = item.type == .episode
        let title = episode && !inShow ? item.grandparentTitle ?? item.title : item.title
        var subtitle: String?
        if episode {
            subtitle = inShow ? Self.runtime(item.duration) : [Self.episodeNumber(item), item.title].compactMap { $0 }.joined(separator: " · ")
        } else if let year = item.year {
            subtitle = String(year)
        }
        let path: String? = if wide {
            episode ? item.thumb ?? item.art : item.art ?? item.thumb
        } else if episode {
            item.grandparentThumb ?? item.parentThumb ?? item.thumb
        } else {
            item.thumb ?? item.parentThumb
        }
        let progress = item.duration > 0 && item.viewOffset > 0 ? Double(item.viewOffset) / Double(item.duration) : nil
        return GlassesTile(id: item.ratingKey, title: title, subtitle: subtitle, art: .plex(path), progress: progress, item: item) { [weak self] in
            self?.open(item)
        }
    }

    private func hero(_ item: PlexMetadata) -> GlassesHero {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if let rating = item.contentRating { parts.append(rating) }
        if item.type == .movie, item.duration > 0 { parts.append(Self.runtime(item.duration)) }
        if item.type == .show, let seasons = item.childCount { parts.append(seasons == 1 ? "1 Season" : "\(seasons) Seasons") }
        if item.type == .season, let show = item.parentTitle { parts.insert(show, at: 0) }
        return GlassesHero(
            title: item.title, meta: parts.isEmpty ? nil : parts.joined(separator: " · "),
            overview: item.summary.isEmpty ? nil : item.summary, backdrop: item.art ?? item.grandparentArt
        )
    }

    private func playActions(_ item: PlexMetadata, label: String? = nil) -> GlassesRow {
        var tiles: [GlassesTile] = []
        if item.viewOffset > 0 {
            tiles.append(GlassesTile(id: "resume", title: "Resume", subtitle: label, art: .symbol("play.fill"), item: item) { [weak self] in
                self?.play(item)
            })
            tiles.append(GlassesTile(id: "start", title: "Play from Start", art: .symbol("arrow.counterclockwise"), item: item) { [weak self] in
                self?.play(item, fromStart: true)
            })
        } else {
            tiles.append(GlassesTile(id: "play", title: "Play", subtitle: label, art: .symbol("play.fill"), item: item) { [weak self] in
                self?.play(item)
            })
        }
        return GlassesRow(id: "actions", title: nil, shape: .card, tiles: tiles)
    }

    private func moviePage(_ item: PlexMetadata) -> GlassesPage {
        let page = GlassesPage(title: item.title)
        page.hero = hero(item)
        page.setRows([playActions(item)], loading: true)
        page.run { [weak self, weak page] in
            guard let self, let page, let library = session.library else { return }
            guard let full = try? await library.metadata(item.ratingKey) else {
                page.setRows(page.rows)
                return
            }
            page.hero = hero(full)
            page.setRows([playActions(full)])
        }
        return page
    }

    private func showPage(_ item: PlexMetadata) -> GlassesPage {
        let page = GlassesPage(title: item.title)
        page.hero = hero(item)
        page.run { [weak self, weak page] in
            guard let self, let page, let library = session.library else { return }
            do {
                async let full = library.metadata(item.ratingKey)
                let seasons = try await library.children(of: item.ratingKey).filter { $0.type == .season }
                let show = (try? await full) ?? item
                page.hero = hero(show)
                var rows: [GlassesRow] = []
                if let next = show.onDeck {
                    rows.append(playActions(next, label: Self.episodeNumber(next)))
                }
                rows.append(GlassesRow(id: "seasons", title: "Seasons", shape: .poster, tiles: seasons.map { tile(for: $0, wide: false) }))
                page.setRows(rows)
            } catch {
                if !Task.isCancelled { page.failed(error.localizedDescription) }
            }
        }
        return page
    }

    private func seasonPage(_ item: PlexMetadata) -> GlassesPage {
        let page = GlassesPage(title: item.parentTitle ?? item.title)
        page.hero = hero(item)
        page.run { [weak self, weak page] in
            guard let self, let page, let library = session.library else { return }
            do {
                let episodes = try await library.children(of: item.ratingKey)
                let tiles = episodes.map { episode in
                    var tile = tile(for: episode, wide: true, inShow: true)
                    tile.title = [Self.episodeNumber(episode), episode.title].compactMap { $0 }.joined(separator: " · ")
                    return tile
                }
                page.setRows([GlassesRow(id: "episodes", title: "Episodes", shape: .landscape, tiles: tiles)])
                if let next = episodes.firstIndex(where: { $0.viewCount == 0 }) { page.focus.focus(row: 0, column: next) }
            } catch {
                if !Task.isCancelled { page.failed(error.localizedDescription) }
            }
        }
        return page
    }

    private func collectionPage(_ item: PlexMetadata) -> GlassesPage {
        let page = GlassesPage(title: item.title, style: .grid)
        page.run { [weak self, weak page] in
            guard let self, let page, let library = session.library else { return }
            do {
                let items = try await library.children(of: item.ratingKey)
                page.setRows(gridRows(items.map { tile(for: $0, wide: false) }, shape: .poster, columns: Self.gridColumns))
            } catch {
                if !Task.isCancelled { page.failed(error.localizedDescription) }
            }
        }
        return page
    }

    private func gridRows(_ tiles: [GlassesTile], shape: GlassesTile.Shape, columns: Int) -> [GlassesRow] {
        stride(from: 0, to: tiles.count, by: columns).map { start in
            let slice = Array(tiles[start..<min(start + columns, tiles.count)])
            return GlassesRow(id: "grid.\(start)", title: nil, shape: shape, tiles: slice)
        }
    }

    /// A library's titles in A–Z order, a page at a time as the focus nears the end.
    private func libraryPage(_ section: PlexLibrarySection) -> GlassesPage {
        let page = GlassesPage(title: section.title, style: .grid)
        let feed = Feed()
        let load: @MainActor () -> Void = { [weak self, weak page] in
            guard let self, let page, let library = session.library, !feed.loading, feed.items.count < feed.total ?? .max else { return }
            feed.loading = true
            page.run { [weak self, weak page] in
                defer { feed.loading = false }
                guard let self, let page else { return }
                do {
                    let next = try await library.items(in: section.key, query: SectionQuery(type: section.type), start: feed.items.count, size: Self.libraryPage)
                    feed.items += next.items
                    feed.total = next.totalSize
                    page.setRows(gridRows(feed.items.map { tile(for: $0, wide: false) }, shape: .poster, columns: Self.gridColumns))
                } catch {
                    if !Task.isCancelled, feed.items.isEmpty { page.failed(error.localizedDescription) }
                }
            }
        }
        page.onMove = { [weak page] in
            guard let page, page.focus.row >= page.rows.count - 2 else { return }
            load()
        }
        load()
        return page
    }

    private final class Feed {
        var items: [PlexMetadata] = []
        var total: Int?
        var loading = false
    }

    /// The letter board, then what the libraries and Seerr found for what was typed.
    private func searchPage() -> GlassesPage {
        let page = GlassesPage(title: "Search")
        page.setRows(keyboardRows(page))
        return page
    }

    private func keyboardRows(_ page: GlassesPage) -> [GlassesRow] {
        GlassesKeyboard.rows.enumerated().map { index, keys in
            GlassesRow(id: "keys.\(index)", title: nil, shape: .key, tiles: keys.map { key in
                let symbol: String? = switch key {
                case .space: "space"
                case .delete: "delete.left"
                case .character: nil
                }
                return GlassesTile(id: "key.\(key.label)", title: key.label, art: symbol.map(GlassesTile.Art.symbol) ?? .none) { [weak self, weak page] in
                    guard let self, let page else { return }
                    page.query = GlassesKeyboard.type(key, into: page.query)
                    search(page)
                }
            })
        }
    }

    private func search(_ page: GlassesPage) {
        searchTask?.cancel()
        let text = page.query.trimmingCharacters(in: .whitespaces)
        let keys = keyboardRows(page)
        guard !text.isEmpty, let library = session.library else {
            page.setRows(keys)
            return
        }
        let client = session.seerr.client
        searchTask = Task { [weak self, weak page] in
            try? await Task.sleep(for: Self.searchDelay)
            guard !Task.isCancelled, let self, let page else { return }
            async let requests = Self.seerrSearch(client, text)
            let hubs = (try? await library.search(text, limit: 20)) ?? []
            var rows = keys
            for hub in hubs {
                let items = hub.items.filter { [.movie, .show, .episode, .collection].contains($0.type) }
                guard !items.isEmpty else { continue }
                rows.append(GlassesRow(id: "hub.\(hub.id)", title: hub.title, shape: .poster, tiles: items.map { tile(for: $0, wide: false) }))
            }
            if let found = await requests, !found.isEmpty {
                rows.append(GlassesRow(id: "seerr", title: "Request", shape: .poster, tiles: found.map(requestTile)))
            }
            guard !Task.isCancelled, page.query.trimmingCharacters(in: .whitespaces) == text else { return }
            page.setRows(rows)
            if rows.count == keys.count { show("Nothing found for “\(text)”") }
        }
    }

    private static func seerrSearch(_ client: SeerrClient?, _ text: String) async -> [SeerrTitle]? {
        guard let client else { return nil }
        return try? await client.search(text)
    }

    private func requestTile(_ title: SeerrTitle) -> GlassesTile {
        let poster = TMDBImage.url(title.posterPath, pixels: Double(GlassesCanvas.poster.width) * 2)?.absoluteString
        return GlassesTile(id: "seerr.\(title.kind).\(title.tmdbID)", title: title.name, subtitle: title.year.map(String.init), art: .plex(poster)) {
            [weak self] in
            guard let self else { return }
            push(requestPage(title))
        }
    }

    private func requestsPage() -> GlassesPage {
        let page = GlassesPage(title: "Requests")
        page.run { [weak self, weak page] in
            guard let self, let page, let client = session.seerr.client else { return }
            var rows: [GlassesRow] = []
            for shelf in SeerrShelf.allCases {
                guard let titles = try? await client.discover(shelf), !titles.isEmpty, !Task.isCancelled else { continue }
                rows.append(GlassesRow(id: shelf.rawValue, title: shelf.title, shape: .poster, tiles: titles.map(requestTile)))
                page.setRows(rows, loading: true)
            }
            if rows.isEmpty { page.failed("Seerr did not answer.") } else { page.setRows(rows) }
        }
        return page
    }

    private func requestPage(_ title: SeerrTitle) -> GlassesPage {
        let page = GlassesPage(title: title.name)
        let backdrop = TMDBImage.url(title.backdropPath, pixels: Double(GlassesCanvas.backdrop.width))?.absoluteString
        page.hero = GlassesHero(
            title: title.name, meta: [title.year.map(String.init), title.kind == .tv ? "Series" : "Movie"].compactMap { $0 }.joined(separator: " · "),
            overview: title.overview.isEmpty ? nil : title.overview, backdrop: backdrop
        )
        page.run { [weak self, weak page] in
            guard let self, let page, let client = session.seerr.client else { return }
            do {
                async let user = client.me()
                async let settings = client.serverSettings()
                let details = try await client.details(title.kind, tmdbID: title.tmdbID)
                let (me, server) = try await (user, settings)
                var tiles: [GlassesTile] = []
                for is4K in [false, true] where details.canRequest(is4K: is4K, user: me, settings: server) {
                    tiles.append(GlassesTile(id: is4K ? "request4k" : "request", title: is4K ? "Request in 4K" : "Request", art: .symbol("plus.circle")) {
                        [weak self] in
                        self?.request(details, is4K: is4K, settings: server)
                    })
                }
                if let library = session.library, case .item(let key) = details.title.media?.plexLink(serverID: library.server.id) {
                    tiles.append(GlassesTile(id: "play", title: "Play", art: .symbol("play.fill")) { [weak self] in
                        guard let self else { return }
                        Task {
                            guard let item = try? await library.metadata(key) else { return }
                            self.play(item)
                        }
                    })
                }
                if tiles.isEmpty {
                    tiles.append(GlassesTile(id: "requested", title: "Already Requested", art: .symbol("checkmark.circle")) {})
                }
                page.setRows([GlassesRow(id: "actions", title: nil, shape: .card, tiles: tiles)])
            } catch {
                guard !Task.isCancelled else { return }
                page.failed((error as? SeerrError).map { SeerrView.text(for: $0) } ?? error.localizedDescription)
            }
        }
        return page
    }

    private func request(_ details: SeerrDetails, is4K: Bool, settings: SeerrServerSettings) {
        let seasons = Set(details.seasonChoices(is4K: is4K, settings: settings).filter(\.isRequestable).map(\.id))
        let order = details.order(seasons: seasons, is4K: is4K, settings: settings)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await session.seerr.request(order)
                show("Requested \(details.title.name)")
                onCue?(.select)
            } catch {
                show((error as? SeerrError).map { SeerrView.text(for: $0) } ?? error.localizedDescription)
                onCue?(.error)
            }
        }
    }

    private func downloadsPage() -> GlassesPage {
        let page = GlassesPage(title: "Downloads", style: .grid)
        let store = session.downloads.store
        let tiles = session.downloads.records.filter { $0.phase == .done }.map { record in
            GlassesTile(
                id: record.id, title: DownloadText.title(record, numbered: true), subtitle: DownloadText.line(record, named: false),
                art: .file(store.posterFile(for: record))
            ) { [weak self] in
                guard let self else { return }
                closeLive()
                session.playDownload(record)
            }
        }
        page.setRows(gridRows(tiles, shape: .poster, columns: Self.gridColumns))
        return page
    }

    /// What was recorded, then every channel with what it airs now.
    private func livePage() -> GlassesPage {
        let page = GlassesPage(title: "Live TV", style: .grid)
        page.run { [weak self, weak page] in
            guard let self, let page, let library = session.library else { return }
            let store = liveStore ?? LiveTVStore(library: library, serverName: session.server?.name ?? "The server", profile: session.user?.uuid)
            liveStore = store
            await store.start()
            switch store.phase {
            case .noDVR:
                page.failed("This server has no DVR.")
                return
            case .failed(let message):
                page.failed(message)
                return
            case .loading, .ready:
                break
            }
            let channels = store.lineup.map { channel in
                GlassesTile(
                    id: "channel.\(channel.id)", title: channel.title,
                    subtitle: store.guide.nowAndNext(on: channel.id, at: store.now).now?.title ?? channel.number, art: .channel(channel)
                ) { [weak self] in self?.tune(channel, store: store) }
            }
            var rows: [GlassesRow] = []
            if let recorded = try? await store.recorded(), !recorded.isEmpty {
                rows.append(GlassesRow(id: "recorded", title: "Recorded", shape: .landscape, tiles: recorded.map { tile(for: $0, wide: true) }))
            }
            rows += gridRows(channels, shape: .channel, columns: Self.channelColumns)
            page.setRows(rows)
        }
        return page
    }

    // MARK: Words

    static func runtime(_ milliseconds: Int) -> String {
        let minutes = milliseconds / 60_000
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    static func episodeNumber(_ item: PlexMetadata) -> String? {
        guard let episode = item.index else { return nil }
        return item.parentIndex.map { "S\($0) · E\(episode)" } ?? "E\(episode)"
    }
}

#if DEBUG
extension GlassesNavigator {
    /// UI tests open one page or panel straight away for its screenshot (fixtures: film 101, show 201,
    /// season 202).
    func openForUITest(_ name: String) async {
        guard let library = session.library else { return }
        switch name {
        case "library":
            if let section = try? await library.sections().first(where: { $0.type == .movie }) { push(libraryPage(section)) }
        case "detail", "show", "season":
            let key = ["detail": "101", "show": "201", "season": "202"][name] ?? "101"
            if let item = try? await library.metadata(key) { open(item) }
        case "search":
            let page = searchPage()
            push(page)
            page.query = "e"
            search(page)
        case "requests":
            push(requestsPage())
        case "request":
            if let title = try? await session.seerr.client?.discover(.trending).first { push(requestPage(title)) }
        case "downloads":
            push(downloadsPage())
        case "live":
            push(livePage())
        case "tracks":
            for _ in 0..<40 {
                if let player, player.tracks != nil {
                    openTracks(player)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        case "options":
            for _ in 0..<40 {
                if let page, page.rows.count > 1 {
                    openOptions(for: page.focusedTile)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        default:
            break
        }
    }
}
#endif
