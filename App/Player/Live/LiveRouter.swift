import AVFoundation
import Darwin
import MarqueeCore
import Observation
import os
import UIKit

/// The live player's source. Before every tune it picks the phone's own path to the tuner or a Plex tune
/// (docs/LIVE-TV.md §2.2) and plays through that one. A direct tune that fails before anything of it is on screen,
/// with a network error, no data or a stream the phone cannot decode, is tried once through Plex; a tuner's refusal
/// is not, since Plex would be refused the same way (§2.3).
///
/// While the phone holds a one-tuner device, a Plex recording on it would be refused, so the router reads the
/// schedule every 60 s, says so a minute ahead, and lets go of the tuner 5 s before the recording starts,
/// continuing through Plex when the recording is the channel on screen.
@MainActor @Observable
final class LiveRouter: LiveVideoSource {
    let direct = DirectLiveSource()
    let plex: PlexLiveSource
    /// Settings › Live TV › Playback is "Through Plex".
    var prefersPlex = false
    /// The route of the current tune.
    private(set) var route: LiveRoute?
    /// The source of the current tune; nil before the first.
    private(set) var active: (any LiveVideoSource)?
    private(set) var usesAirPlayVideo = false
    /// The router's own state while it decides, and for a channel neither path can play.
    private var ownState: LiveState?
    /// The router's own status line: a fallback to Plex, or a recording about to take the tuner.
    private var notice: String?

    @ObservationIgnored private let live: PlexLiveTV
    @ObservationIgnored private let tuners = HDHomeRunClient()
    @ObservationIgnored private let container = LiveRouterView()
    /// Bumped by every tune and stop; work started under an older value gives way.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var channel: LiveChannel?
    /// The generation that already fell back to Plex.
    @ObservationIgnored private var fellBack = 0
    @ObservationIgnored private var reachability: [String: (reachable: Bool, at: ContinuousClock.Instant)] = [:]
    @ObservationIgnored private var lineups: [String: [HDHomeRunChannel]] = [:]
    @ObservationIgnored private var dvrs: [LiveDVR] = []
    @ObservationIgnored private var recordings: [ScheduledRecording] = []
    @ObservationIgnored private var isPrepared = false
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var recordingGuard: Task<Void, Never>?

    private static let log = Logger(subsystem: "com.nphil.marquee", category: "LiveTV")
    /// The schedule is read this often while the phone holds the tuner, and a recording this close is announced.
    private static let guardInterval: TimeInterval = 60
    /// The phone lets go of the tuner this long before a recording's grab starts.
    private static let guardMargin: TimeInterval = 5

    init(live: PlexLiveTV, plex: PlexLiveSource) {
        self.live = live
        self.plex = plex
        direct.onFailedBeforePicture = { [weak self] channel, error in self?.fallBack(channel, after: error) }
    }

    // MARK: LiveSource

    var videoView: UIView { container }
    var state: LiveState { ownState ?? active?.state ?? .idle }
    var status: String? { notice ?? active?.status }
    var diagnosticsLine: String? { active?.diagnosticsLine }

    func play(_ channel: LiveChannel) async {
        generation += 1
        let mine = generation
        self.channel = channel
        recordingGuard?.cancel()
        say(nil)
        ownState = .opening
        if !isPrepared { await prepare(devices: [channel.device]) }
        let route = await decide(channel)
        guard mine == generation else { return }
        self.route = route
        Self.log.info("live-route \(channel.number, privacy: .public) \(Self.describe(route), privacy: .public)")
        switch route {
        case .direct:
            await show(direct)
            guard mine == generation else { return }
            ownState = nil
            await direct.play(channel)
            guardRecordings(channel, generation: mine)
        case .plex:
            await show(plex)
            guard mine == generation else { return }
            ownState = nil
            await plex.play(channel)
        case .protectedChannel:
            active?.stop()
            ownState = .failed(.protectedChannel)
        }
    }

    func stop() {
        generation += 1
        recordingGuard?.cancel()
        active?.stop()
        ownState = nil
        say(nil)
    }

    /// Whether an AirPlay video receiver is the chosen output, which only the Plex path can feed; a change while a
    /// channel plays tunes it again on the matching path.
    func setAirPlayVideo(_ on: Bool) async {
        guard on != usesAirPlayVideo else { return }
        usesAirPlayVideo = on
        guard let channel, active != nil, state != .idle else { return }
        await play(channel)
    }

    /// Reads what the decision needs ahead of a tune (§4.2): the DVRs, the scheduled recordings, and each tuner's
    /// reachability; lineups follow in the background. A tune works without it, a little later.
    func prepare(devices: [TunerDevice]) async {
        isPrepared = true
        async let readDVRs = try? live.dvrs()
        async let readSchedule = try? live.scheduled()
        for device in devices where !FakeTuner.isActive && device.speaksHDHomeRun && Self.isOnAttachedNetwork(device.uri) != false {
            guard await isReachable(device), lineups[device.key] == nil else { continue }
            let tuners = tuners
            Task { [weak self] in
                let lineup = try? await tuners.lineup(device.uri)
                self?.lineups[device.key] = lineup
            }
        }
        if let found = await readDVRs { dvrs = found }
        if let found = await readSchedule { recordings = found }
    }

    // MARK: Decision

    private func decide(_ channel: LiveChannel) async -> LiveRoute {
        let device = channel.device
        let home = await isAtHome(device)
        // Earlier rules win, so the tuner is asked only when its answer can matter.
        let reachable = !prefersPlex && home && device.speaksHDHomeRun ? await isReachable(device) : false
        let context = RouteContext(
            prefersPlex: prefersPlex,
            isOnHomeNetwork: home,
            tunerReachable: reachable,
            usesAirPlayVideo: usesAirPlayVideo,
            lineup: lineups[device.key]?.first { $0.number == channel.number },
            dvr: dvrs.first { $0.key == channel.dvrKey },
            recordings: recordings
        )
        return LiveRouteDecider().route(channel, context)
    }

    private func isAtHome(_ device: TunerDevice) async -> Bool {
        if FakeTuner.isActive { return true }
        if let attached = Self.isOnAttachedNetwork(device.uri) { return attached }
        // A tuner by host name: home is where the server answers on its local address.
        return (try? await live.library.connection.connection().isLocal) ?? false
    }

    /// `discover.json` within 0.5 s, cached 60 s. A device that answers with another ID is another network's.
    private func isReachable(_ device: TunerDevice) async -> Bool {
        if FakeTuner.isActive { return true }
        if let known = reachability[device.key], ContinuousClock.now - known.at < .seconds(60) { return known.reachable }
        let answer = try? await tuners.discover(device.uri)
        let reachable = answer.map { found in
            found.deviceID.isEmpty || device.uuid.lowercased().hasSuffix("/" + found.deviceID.lowercased())
        } ?? false
        reachability[device.key] = (reachable, .now)
        return reachable
    }

    /// Whether the tuner's address is on a network one of the phone's own interfaces is attached to; nil for a host
    /// name. A tuner reached through a VPN's route into the home network is away: the tuner would see the VPN router's
    /// address, which may be the Plex server's, and let the phone take over a recording (§5 Q2).
    nonisolated static func isOnAttachedNetwork(_ uri: URL) -> Bool? {
        guard let host = uri.host() else { return nil }
        var target = in_addr()
        guard inet_pton(AF_INET, host, &target) == 1 else { return nil }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return false }
        defer { freeifaddrs(list) }
        var entry = list
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            let flags = Int32(bitPattern: current.pointee.ifa_flags)
            // VPN tunnels are point-to-point.
            guard flags & IFF_UP != 0, flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  let address = current.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let netmask = current.pointee.ifa_netmask
            else { continue }
            let own = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if own & mask == target.s_addr & mask { return true }
        }
        return false
    }

    // MARK: Switching

    /// Puts `next` on screen. The source before it stops first, and a Plex session lets go of the tuner before the
    /// phone asks for it: a one-tuner device refuses a second client.
    private func show(_ next: any LiveVideoSource) async {
        if let current = active, current !== next {
            current.stop()
            if current === plex { await plex.finishEnding() }
        }
        active = next
        container.show(next.videoView)
    }

    private func fallBack(_ channel: LiveChannel, after error: LiveError) {
        guard active === direct, fellBack != generation else { return }
        fellBack = generation
        let mine = generation
        if case .network = error {
            reachability[channel.device.key] = (false, .now)
        }
        Self.log.info("live-fallback \(channel.number, privacy: .public) \(String(describing: error), privacy: .public)")
        recordingGuard?.cancel()
        ownState = .opening
        say("Couldn't play from the tuner; playing through Plex", for: .seconds(8))
        Task {
            await show(plex)
            guard mine == generation else { return }
            route = .plex(.tunerUnreachable)
            ownState = nil
            await plex.play(channel)
        }
    }

    // MARK: Recording guard

    private func guardRecordings(_ channel: LiveChannel, generation mine: Int) {
        recordingGuard?.cancel()
        recordingGuard = Task { [weak self] in
            var wait = Duration.zero
            while !Task.isCancelled {
                try? await Task.sleep(for: wait)
                guard let self, mine == self.generation, !Task.isCancelled,
                      let next = await self.checkRecordings(channel, generation: mine)
                else { return }
                wait = next
            }
        }
    }

    /// How long until the next look at the schedule; nil once the tuner is handed over.
    private func checkRecordings(_ channel: LiveChannel, generation mine: Int) async -> Duration? {
        if let found = try? await live.scheduled() { recordings = found }
        guard mine == generation, active === direct else { return nil }
        guard let grab = nextGrab(on: channel) else { return .seconds(Self.guardInterval) }
        let lead = grab.at.timeIntervalSinceNow - Self.guardMargin
        if lead <= 0 {
            handOver(to: grab.recording, watching: channel)
            return nil
        }
        if lead <= Self.guardInterval {
            say("Recording on \(grab.recording.channelNumber ?? channel.device.name) starts in 1 min")
        }
        return .seconds(min(lead, Self.guardInterval))
    }

    /// The first recording that would find every tuner of `channel`'s device taken with the phone's stream counted,
    /// and when its grab starts: the DVR starts early by its `startOffsetMinutes`.
    private func nextGrab(on channel: LiveChannel) -> (recording: ScheduledRecording, at: Date)? {
        let device = channel.device
        let dvr = dvrs.first { $0.key == channel.dvrKey }
        let early = TimeInterval(dvr?.startOffsetMinutes ?? 0) * 60
        let now = Date()
        let onDevice = recordings
            .filter { recording in
                guard recording.isUpcoming, recording.end > now else { return false }
                guard let key = recording.channelKey, let dvr else { return true }
                return dvr.device(device, carries: key)
            }
            .map { (recording: $0, at: $0.start.addingTimeInterval(-early)) }
            .sorted { $0.at < $1.at }
        return onDevice.first { grab in
            let busy = onDevice.filter { $0.at <= grab.at && $0.recording.end > grab.at }.count
            return busy + 1 > device.tunerCount
        }
    }

    private func handOver(to recording: ScheduledRecording, watching channel: LiveChannel) {
        let number = recording.channelNumber ?? channel.number
        Self.log.info("live-guard \(channel.number, privacy: .public) recording \(number, privacy: .public)")
        if recording.channelKey == channel.id {
            // Plex shares its recording's tuner with a viewer of the same channel.
            say("Recording \(number) now; playing through Plex", for: .seconds(8))
            let mine = generation
            Task {
                await show(plex)
                guard mine == generation else { return }
                route = .plex(.recording)
                await plex.play(channel)
            }
        } else {
            direct.stop()
            say("Stopped for the recording on \(number)")
        }
    }

    // MARK: Status

    private func say(_ text: String?, for duration: Duration? = nil) {
        noticeTask?.cancel()
        notice = text
        guard let duration else { return }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, !Task.isCancelled else { return }
            self.notice = nil
        }
    }

    private static func describe(_ route: LiveRoute) -> String {
        switch route {
        case .direct: "direct"
        case .plex(let reason): "plex \(reason)"
        case .protectedChannel: "protected"
        }
    }
}

/// Holds the active source's picture. Hosts set `contentMode`, which reaches the picture as its video gravity.
private final class LiveRouterView: UIView {
    private weak var shown: UIView?

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var contentMode: UIView.ContentMode {
        didSet { shown.map(apply) }
    }

    func show(_ view: UIView) {
        guard view !== shown else { return }
        shown?.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
        shown = view
        apply(to: view)
    }

    private func apply(to view: UIView) {
        let gravity: AVLayerVideoGravity = switch contentMode {
        case .scaleAspectFill: .resizeAspectFill
        case .scaleToFill: .resize
        default: .resizeAspect
        }
        switch view.layer {
        case let layer as AVPlayerLayer: layer.videoGravity = gravity
        case let layer as AVSampleBufferDisplayLayer: layer.videoGravity = gravity
        default: view.contentMode = contentMode
        }
    }
}
