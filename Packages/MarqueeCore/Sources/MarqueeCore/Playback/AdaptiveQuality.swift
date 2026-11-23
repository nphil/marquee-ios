import Foundation

/// The quality setting: Auto, or one fixed ceiling (docs/adaptive-playback.md).
public enum QualitySetting: Sendable, Hashable {
    case auto
    case fixed(VideoQuality)

    /// Auto, then every fixed quality from Original down.
    public static let all: [QualitySetting] = [.auto] + VideoQuality.allCases.map(QualitySetting.fixed)

    /// What a profile saved before Auto existed becomes: a lowered quality stays, Original (the old default,
    /// which cannot be told apart from an untouched setting) becomes Auto.
    public static func saved(legacy: VideoQuality?) -> QualitySetting {
        guard let legacy, legacy != .original else { return .auto }
        return .fixed(legacy)
    }

    /// "Auto", or the fixed quality's title.
    public var title: String {
        switch self {
        case .auto: "Auto"
        case .fixed(let quality): quality.title
        }
    }
}

extension QualitySetting: Codable {
    /// One integer: -1 for Auto, else the fixed quality's raw value.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        if raw == -1 {
            self = .auto
        } else if let quality = VideoQuality(rawValue: raw) {
            self = .fixed(quality)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "No quality \(raw)"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .auto: try container.encode(-1)
        case .fixed(let quality): try container.encode(quality.rawValue)
        }
    }
}

/// A title's picture quality at each rung as VMAF scores (0-100). With scores, Auto climbs no higher than
/// the lowest rung within `enough` points of the best, so a title that looks the same at 8 Mbps does not
/// pull 20. Nothing supplies scores yet.
public struct QualityScores: Sendable, Hashable {
    public var scores: [VideoQuality: Double]
    public static let enough = 1.5

    public init(_ scores: [VideoQuality: Double]) {
        self.scores = scores
    }

    /// The lowest rung of `ladder` (best first) that scores within `enough` of the best; nil without scores.
    func ceiling(in ladder: [VideoQuality]) -> VideoQuality? {
        let scored = ladder.filter { scores[$0] != nil }
        guard let best = scored.compactMap({ scores[$0] }).max() else { return nil }
        return scored.last { scores[$0]! >= best - Self.enough }
    }
}

/// Auto quality's rung while one video plays (docs/adaptive-playback.md). The app shows it a look at the
/// stream every couple of seconds; a returned rung is a move to make, after which `moved(to:at:)` says where
/// playback ended up. No other move comes in between.
public struct AdaptiveQuality: Sendable {
    public struct Picture: Sendable, Hashable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        fileprivate var shortEdge: Int? {
            width > 0 && height > 0 ? min(width, height) : nil
        }
    }

    public struct Tuning: Sendable {
        /// A rung fits the link when its rate is at most this share of the estimate.
        public var fit = 0.7
        /// The same for a step picked from the title's quality map. Those are the title's own measured rates and the
        /// audio is in them, so the link keeps a quarter in hand for its swings.
        public var mappedFit = 0.75
        /// A wait on the network this long moves down.
        public var stallWait: TimeInterval = 2
        /// Less buffer than this, with the estimate below the rung's rate, moves down.
        public var lowBuffer: TimeInterval = 12
        /// A climb needs this much buffer, the estimate fitting the higher rung for `climbHold`, and `dwell`
        /// since the last move.
        public var climbBuffer: TimeInterval = 10
        public var climbHold: TimeInterval = 10
        public var dwell: TimeInterval = 20
        /// The first drop this soon after a climb doubles the climb's hold, up to `maxClimbHold`; `calm`
        /// without a drop resets it.
        public var flapWindow: TimeInterval = 60
        public var maxClimbHold: TimeInterval = 160
        public var calm: TimeInterval = 300
        public var fastHalfLife: TimeInterval = 3
        public var slowHalfLife: TimeInterval = 10
        /// The start with no reading of the link (`LinkProbe` could not take one).
        public var unmeasuredStart = VideoQuality.mbps4

        public init() {}
    }

    /// One look at the stream.
    public struct Look: Sendable {
        public var now: TimeInterval
        /// The link's speed while data moved since the last look, and for how long it moved; nil when none did.
        public var throughputKbps: Int?
        public var transferSeconds: TimeInterval
        /// Media on the phone ahead of the playhead; nil when unknown.
        public var bufferSeconds: TimeInterval?
        /// How long playback has waited on the network; 0 while it plays.
        public var waitingSeconds: TimeInterval
        public var streamID: UUID?

        public init(
            now: TimeInterval, throughputKbps: Int? = nil, transferSeconds: TimeInterval = 0,
            bufferSeconds: TimeInterval? = nil, waitingSeconds: TimeInterval = 0, streamID: UUID? = nil
        ) {
            self.now = now
            self.throughputKbps = throughputKbps
            self.transferSeconds = transferSeconds
            self.bufferSeconds = bufferSeconds
            self.waitingSeconds = waitingSeconds
            self.streamID = streamID
        }
    }

    /// The rung playing, or being moved to.
    public private(set) var rung: AutoRung
    /// Original, then below the file's rate what Auto may stream at, best first: the steps of the title's quality
    /// curve when HomeLabber has measured it, else the watchable presets.
    public let ladder: [AutoRung]
    public let floor: AutoRung
    /// The ladder is the steps of the title's quality curve rather than the presets, so what the picture on screen
    /// asks of a preset (`view`) has no say in it.
    public var isMapped: Bool { floor.target != nil }
    /// The link cannot sustain the floor: the estimate falls short of its rate, or playback at the floor
    /// waits on the network.
    public private(set) var belowFloor = false
    public let streamID: UUID
    private let mediaKbps: Int?
    /// The highest rung Auto reaches: the lower of `QualityScores`' and the data-saving cap's.
    private let ceiling: AutoRung?
    private let tuning: Tuning
    private var fast: MovingAverage
    private var slow: MovingAverage
    private var moving = false
    private var lastMove: TimeInterval
    private var lastClimb: TimeInterval?
    private var lastDrop: TimeInterval
    private var climbSince: TimeInterval?
    private var climbHold: TimeInterval

    /// - Parameters:
    ///   - linkKbps: the link to the server as recently measured (`LinkMemory`).
    ///   - cap: the highest quality to play at while saving data, if saving.
    ///   - map: the title's quality curve on this screen (`QualityMapAnswer.curve(for:screen:)`). With it Auto
    ///     streams at the best-looking size and bitrate the link carries, in place of the presets; `scores`,
    ///     `source` and `view` then have no say, as the curve already knows what the title gains from more.
    public init(
        mediaKbps: Int?, linkKbps: Int?, cap: VideoQuality? = nil, scores: QualityScores? = nil, map: QualityCurve? = nil,
        tuning: Tuning = Tuning(), source: Picture? = nil, view: Picture? = nil, streamID: UUID = UUID(), now: TimeInterval
    ) {
        let mediaKbps = mediaKbps.flatMap { $0 > 0 ? $0 : nil }
        // A step that costs as much as the file saves nothing.
        let steps = (map?.steps() ?? []).filter { step in mediaKbps.map { step.rateKbps < $0 } ?? true }
        let ladder: [AutoRung]
        if steps.isEmpty {
            let sourceEdge = source?.shortEdge
            let minimum: VideoQuality = (sourceEdge ?? 1080) >= 1080 && (view?.shortEdge ?? 720) >= 1080 ? .mbps8 : .mbps4
            ladder = ([VideoQuality.original] + VideoQuality.allCases.filter { preset in
                guard let rate = preset.maxBitrateKbps else { return false }
                // A small original cannot gain detail from a higher-resolution transcode.
                guard (sourceEdge ?? 720) >= 720, rate >= minimum.rawValue else { return false }
                return mediaKbps.map { rate < $0 } ?? true
            }).map(AutoRung.preset)
        } else {
            ladder = [AutoRung.original] + steps.map(AutoRung.mapped)
        }
        self.ladder = ladder
        floor = ladder.last!
        self.streamID = streamID
        self.mediaKbps = mediaKbps
        self.tuning = tuning
        let capped = cap.flatMap { cap -> AutoRung? in
            guard let limit = cap.maxBitrateKbps, let frame = cap.frame else { return nil }
            return ladder.first { rung in
                guard let target = rung.target else { return (rung.quality.maxBitrateKbps ?? .max) <= limit }
                return target.maxVideoBitrateKbps <= limit && target.height <= frame.height
            } ?? ladder.last!
        }
        let scored = steps.isEmpty ? scores?.ceiling(in: ladder.map(\.quality)).map(AutoRung.preset) : nil
        ceiling = [scored, capped].compactMap { $0 }.max { (ladder.firstIndex(of: $0) ?? 0) < (ladder.firstIndex(of: $1) ?? 0) }
        fast = MovingAverage(halfLife: tuning.fastHalfLife)
        slow = MovingAverage(halfLife: tuning.slowHalfLife)
        lastMove = now
        lastDrop = now
        climbHold = tuning.climbHold
        rung = .original
        if let linkKbps, linkKbps > 0 {
            rung = fitting(Double(linkKbps))
            belowFloor = rate(of: floor).map { Double($0) > Double(linkKbps) * share(of: floor) } ?? false
            return
        }
        // With no reading of the link, a low rung starts fast and the climb follows.
        rung = climbable.first { (rate(of: $0) ?? .max) <= tuning.unmeasuredStart.rawValue }
            ?? climbable.last!
    }

    /// The link estimate in kbit/s: the lower of a fast and a slow moving average; nil before any data moved.
    public var estimateKbps: Int? {
        guard let fast = fast.value, let slow = slow.value else { return nil }
        return Int(min(fast, slow))
    }

    /// Takes in one look; returns the rung to move to, or nil to stay.
    public mutating func observe(_ look: Look) -> AutoRung? {
        guard !moving, look.streamID == nil || look.streamID == streamID, look.now.isFinite else { return nil }
        if let kbps = look.throughputKbps, kbps > 0, look.transferSeconds > 0, look.transferSeconds.isFinite {
            fast.add(Double(kbps), weight: look.transferSeconds)
            slow.add(Double(kbps), weight: look.transferSeconds)
        }
        if look.now - lastDrop >= tuning.calm { climbHold = tuning.climbHold }
        let estimate = estimateKbps.map(Double.init)
        // A wait at the floor counts whatever the estimate says: no data moves while it lasts, so the
        // estimate is from before it.
        belowFloor = (rung == floor && look.waitingSeconds >= tuning.stallWait)
            || (estimate.flatMap { estimate in rate(of: floor).map { Double($0) > estimate * share(of: floor) } } ?? false)

        let behind = estimate.flatMap { estimate in rate(of: rung).map { estimate < Double($0) } } ?? false
        if look.waitingSeconds >= tuning.stallWait || (behind && (look.bufferSeconds ?? .infinity) < tuning.lowBuffer) {
            climbSince = nil
            guard let lower = step(below: rung) else { return nil }
            // At least one step down; further when the estimate fits only a lower rung.
            let fit = estimate.map { fitting($0, in: ladder) }
            if let lastClimb, look.now - lastClimb <= tuning.flapWindow {
                climbHold = min(climbHold * 2, tuning.maxClimbHold)
                self.lastClimb = nil
            }
            lastDrop = look.now
            return move(to: fit.map { isBetter(lower, than: $0) ? $0 : lower } ?? lower)
        }

        guard let estimate, (look.bufferSeconds ?? 0) >= tuning.climbBuffer, isBetter(fitting(estimate), than: rung) else {
            climbSince = nil
            return nil
        }
        let since = climbSince ?? look.now
        climbSince = since
        guard look.now - since >= climbHold, look.now - lastMove >= tuning.dwell else { return nil }
        lastClimb = look.now
        return move(to: fitting(estimate))
    }

    /// The move is over: playback runs at `rung`, the one asked for or, when the move failed, the one before.
    public mutating func moved(to rung: AutoRung, at now: TimeInterval) {
        self.rung = rung
        moving = false
        lastMove = now
        climbSince = nil
    }

    private mutating func move(to target: AutoRung) -> AutoRung {
        rung = target
        moving = true
        climbSince = nil
        return target
    }

    /// The ladder from the ceiling down.
    private var climbable: [AutoRung] {
        guard let ceiling, let start = ladder.firstIndex(of: ceiling) else { return ladder }
        return Array(ladder[start...])
    }

    /// The best rung that fits the link, else the lowest.
    private func fitting(_ estimate: Double) -> AutoRung {
        fitting(estimate, in: climbable)
    }

    private func fitting(_ estimate: Double, in rungs: [AutoRung]) -> AutoRung {
        rungs.first { rung in rate(of: rung).map { Double($0) <= estimate * share(of: rung) } ?? false } ?? rungs.last!
    }

    /// The rung's rate: the file's for Original, which is unknown when the server did not say.
    private func rate(of rung: AutoRung) -> Int? {
        switch rung {
        case .preset(.original): mediaKbps
        case .preset(let quality): quality.maxBitrateKbps
        case .mapped(let step): step.rateKbps
        }
    }

    /// The share of the link the rung may take (`Tuning.fit`, `Tuning.mappedFit`).
    private func share(of rung: AutoRung) -> Double {
        rung.target == nil ? tuning.fit : tuning.mappedFit
    }

    private func step(below rung: AutoRung) -> AutoRung? {
        guard let index = ladder.firstIndex(of: rung), index + 1 < ladder.count else { return nil }
        return ladder[index + 1]
    }

    private func isBetter(_ a: AutoRung, than b: AutoRung) -> Bool {
        guard let i = ladder.firstIndex(of: a), let j = ladder.firstIndex(of: b) else { return false }
        return i < j
    }
}

/// An exponentially weighted moving average over samples weighted by duration, corrected for its start at
/// zero.
private struct MovingAverage: Sendable {
    let halfLife: TimeInterval
    private var sum = 0.0
    private var weight = 0.0

    init(halfLife: TimeInterval) {
        self.halfLife = halfLife
    }

    mutating func add(_ sample: Double, weight: TimeInterval) {
        let kept = pow(0.5, weight / halfLife)
        sum = sample * (1 - kept) + sum * kept
        self.weight += weight
    }

    var value: Double? {
        weight > 0 ? sum / (1 - pow(0.5, weight / halfLife)) : nil
    }
}
