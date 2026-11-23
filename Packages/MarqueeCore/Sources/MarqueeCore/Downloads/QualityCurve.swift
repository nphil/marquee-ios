import Foundation

/// One picture a stream can be asked for under a quality map: a video bitrate at a size, and the VMAF the
/// title scores there.
public struct StreamStep: Sendable, Hashable {
    /// What the server is asked for. A download's `DownloadTarget` serves a stream as well: both are a bitrate at a size.
    public let target: DownloadTarget
    public let vmaf: Double

    public init(target: DownloadTarget, vmaf: Double) {
        self.target = target
        self.vmaf = vmaf
    }

    /// What the stream asks of the link: its video and its audio.
    public var rateKbps: Int { target.videoKbps + DownloadTarget.audioKbps }

    /// "3.2 Mbps 720p", read like `VideoQuality.title`.
    public var title: String {
        let mbps = rateKbps >= 10_000 ? "\(Int((Double(rateKbps) / 1000).rounded()))" : "\(Double(rateKbps / 100) / 10)"
        return "\(mbps) Mbps \(target.height)p"
    }

    /// Scores closer than this are a tie, which the cheaper step wins: HomeLabber rounds a score to hundredths and
    /// two encodes of one bitrate differ by more than that.
    private static let tie = 0.05

    /// The higher score; for a tie the lower bitrate, then the larger picture.
    fileprivate func isBetter(than other: StreamStep) -> Bool {
        if abs(vmaf - other.vmaf) > Self.tie { return vmaf > other.vmaf }
        if target.videoKbps != other.target.videoKbps { return target.videoKbps < other.target.videoKbps }
        return target.height > other.target.height
    }
}

/// A title's picture quality against video bitrate, as HomeLabber measured it for one screen
/// (`QualityMapEntry.curve(for:)`): at each size, the VMAF reached at a few bitrates. VMAF grows about with the
/// logarithm of the bitrate, so the points are joined in log-bitrate, and nothing is guessed past the measured
/// range: outside it a size's curve is held flat at its nearest point. Two encodes a few percent apart can score
/// in the wrong order by chance, so a size's score never falls as its bitrate rises.
///
/// The scores are all taken against the source's picture at its own size (at most 1080p), so one score means
/// one look at every size, and the best one at a bitrate is the best picture the bitrate buys.
public struct QualityCurve: Sendable, Hashable {
    /// Each size's points, bitrate rising and score never falling.
    private let sizes: [Int: [QualityMapEntry.Point]]

    public init(_ points: [QualityMapEntry.Point]) {
        var grouped: [Int: [QualityMapEntry.Point]] = [:]
        for point in points where point.kbps > 0 && point.vmaf.isFinite {
            grouped[point.height, default: []].append(point)
        }
        sizes = grouped.mapValues { found in
            var best = -Double.infinity
            return found.sorted { $0.kbps < $1.kbps }.map { point in
                best = max(best, point.vmaf)
                return QualityMapEntry.Point(kbps: point.kbps, vmaf: best, height: point.height)
            }
        }
    }

    public var isEmpty: Bool { sizes.isEmpty }

    /// The sizes the curve covers, smallest first.
    public var heights: [Int] { sizes.keys.sorted() }

    /// The highest bitrate measured at `height`; more adds nothing, as the curve is flat past it.
    public func highestKbps(height: Int) -> Int? {
        sizes[height]?.last?.kbps
    }

    /// The score at `kbps` for `height`: joined in log-bitrate between points, flat outside them; nil for a size
    /// without points.
    public func vmaf(height: Int, kbps: Int) -> Double? {
        guard let points = sizes[height], let first = points.first, let last = points.last else { return nil }
        guard kbps > first.kbps else { return first.vmaf }
        guard kbps < last.kbps else { return last.vmaf }
        // `kbps` is inside the range, so one pair of neighbours holds it.
        for (below, above) in zip(points, points.dropFirst()) where kbps <= above.kbps {
            let along = (log(Double(kbps)) - log(Double(below.kbps))) / (log(Double(above.kbps)) - log(Double(below.kbps)))
            return below.vmaf + along * (above.vmaf - below.vmaf)
        }
        return last.vmaf
    }

    /// The best picture whose video bitrate is at most `budgetKbps`: for each size, the bitrate it may have is the
    /// budget, or its last measured point where that is lower; the highest score wins, a tie going to the lower
    /// bitrate and then the larger picture. A size is left out when the budget is under the least Plex makes it
    /// at (`TranscodeLadder.floor`), since Plex would send a smaller picture; nil when that leaves none.
    public func best(withinKbps budgetKbps: Int) -> StreamStep? {
        var winner: StreamStep?
        for height in heights {
            guard let top = highestKbps(height: height) else { continue }
            let kbps = min(budgetKbps, top)
            guard kbps >= TranscodeLadder.floor(height: height), let score = vmaf(height: height, kbps: kbps) else { continue }
            let step = StreamStep(target: DownloadTarget(videoKbps: kbps, height: height), vmaf: score)
            if winner.map({ step.isBetter(than: $0) }) ?? true { winner = step }
        }
        return winner
    }

    /// Budgets of the next step are this much larger than the last.
    private static let spacing = 1.05

    /// The pictures Auto moves between, best first. They are what `best(withinKbps:)` gives for budgets from the
    /// least a size is made at up to the highest bitrate measured, kept only where the picture looks at least
    /// `minGain` better than the last one kept below it: a title that looks the same at 9 Mbit/s as at 12 gets no
    /// step at 12, and a steep stretch gets a step wherever the score has risen enough to be worth a new stream.
    public func steps(minGain: Double = QualityScores.enough) -> [StreamStep] {
        let covered = heights
        guard let lowest = covered.map(TranscodeLadder.floor(height:)).min(), let highest = covered.compactMap(highestKbps(height:)).max() else {
            return []
        }
        var found: [StreamStep] = []
        var budget = Double(lowest)
        while true {
            let kbps = min(Int(budget.rounded()), highest)
            if let step = best(withinKbps: kbps), !found.contains(step) { found.append(step) }
            if kbps >= highest { break }
            budget *= Self.spacing
        }
        var kept: [StreamStep] = []
        for step in found.sorted(by: { ($0.target.videoKbps, $1.vmaf) < ($1.target.videoKbps, $0.vmaf) }) {
            if let last = kept.last, step.vmaf < last.vmaf + minGain { continue }
            kept.append(step)
        }
        return kept.reversed()
    }
}
