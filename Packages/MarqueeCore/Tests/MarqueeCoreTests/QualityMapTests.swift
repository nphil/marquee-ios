import Foundation
import Testing
@testable import MarqueeCore

/// HomeLabber's quality map as the phone uses it: whose word counts, which scoring a screen reads, and what Auto
/// streams by. The Download menu's own tests are in `DownloadQualityTests`.
struct QualityMapTests {
    typealias Point = QualityMapEntry.Point

    /// A title's measured curve: 480p up to 2.6 Mbit/s, 720p up to 6 and 1080p up to 12.
    static let curve = QualityCurve([
        Point(kbps: 1100, vmaf: 70, height: 480), Point(kbps: 1700, vmaf: 76, height: 480), Point(kbps: 2600, vmaf: 80, height: 480),
        Point(kbps: 3000, vmaf: 84, height: 720), Point(kbps: 4500, vmaf: 90, height: 720), Point(kbps: 6000, vmaf: 93, height: 720),
        Point(kbps: 6600, vmaf: 91, height: 1080), Point(kbps: 9000, vmaf: 95, height: 1080), Point(kbps: 12000, vmaf: 97, height: 1080),
    ])

    // MARK: Curve

    @Test func theCurveIsJoinedInLogBitrateAndHeldFlatOutsideWhatWasMeasured() throws {
        let curve = QualityCurve([Point(kbps: 1000, vmaf: 80, height: 480), Point(kbps: 4000, vmaf: 90, height: 480)])

        // 2000 is halfway from 1000 to 4000 in log-bitrate.
        let middle = try #require(curve.vmaf(height: 480, kbps: 2000))
        #expect(abs(middle - 85) < 1e-9)
        #expect(curve.vmaf(height: 480, kbps: 500) == 80)
        #expect(curve.vmaf(height: 480, kbps: 9000) == 90)
        #expect(curve.vmaf(height: 720, kbps: 2000) == nil)
        #expect(curve.highestKbps(height: 480) == 4000 && curve.heights == [480])
    }

    @Test func aSizesScoreNeverFallsAsItsBitrateRisesAndBadPointsAreDropped() {
        // Two encodes a few percent apart can score the wrong way round.
        let noisy = QualityCurve([
            Point(kbps: 6000, vmaf: 93, height: 720), Point(kbps: 3150, vmaf: 87.6, height: 720), Point(kbps: 3000, vmaf: 88, height: 720),
            Point(kbps: 0, vmaf: 99, height: 720), Point(kbps: 4000, vmaf: .nan, height: 720),
        ])

        #expect(noisy.vmaf(height: 720, kbps: 3150) == 88)
        #expect(noisy.highestKbps(height: 720) == 6000)
        #expect(QualityCurve([]).isEmpty && QualityCurve([]).steps().isEmpty)
    }

    @Test func theBestPictureIsTheHighestScoreTheBudgetBuys() throws {
        let curve = Self.curve

        // Plex makes no size for less than its floor: 1050 kbit/s for 480p.
        #expect(curve.best(withinKbps: 1049) == nil)
        let lowest = try #require(curve.best(withinKbps: 1050))
        #expect(lowest.target.height == 480 && lowest.target.videoKbps == 1050 && lowest.vmaf == 70)
        // 480p stops improving at 2.6 Mbit/s and 720p starts at 2960.
        let top480 = try #require(curve.best(withinKbps: 2959))
        #expect(top480.target.height == 480 && top480.target.videoKbps == 2600)
        let first720 = try #require(curve.best(withinKbps: 2960))
        #expect(first720.target.height == 720 && first720.target.videoKbps == 2960 && first720.vmaf == 84)
        // 1080p is at 91.8 for 7000, below 720p's 93, which it already has for 6000.
        let seven = try #require(curve.best(withinKbps: 7000))
        #expect(seven.target.height == 720 && seven.target.videoKbps == 6000)
        let nine = try #require(curve.best(withinKbps: 9000))
        #expect(nine.target.height == 1080 && nine.target.videoKbps == 9000 && nine.vmaf == 95)
        #expect(curve.best(withinKbps: 50_000)?.target.videoKbps == 12000)
    }

    @Test func aTieGoesToTheCheaperPicture() throws {
        let curve = QualityCurve([
            Point(kbps: 3000, vmaf: 85, height: 720), Point(kbps: 4000, vmaf: 92, height: 720),
            Point(kbps: 6600, vmaf: 92.03, height: 1080), Point(kbps: 9000, vmaf: 96, height: 1080),
        ])

        // 1080p scores 0.03 higher for 2600 kbit/s more: the same picture.
        let step = try #require(curve.best(withinKbps: 6600))
        #expect(step.target.height == 720 && step.target.videoKbps == 4000)
    }

    @Test func theStepsAreTheLooksWorthAMoveBestFirst() throws {
        let steps = Self.curve.steps()
        let best = try #require(steps.first)
        let cheapest = try #require(steps.last)

        #expect(best.target.height == 1080 && best.vmaf >= 97 - QualityScores.enough)
        #expect(cheapest.target.height == 480 && cheapest.target.videoKbps == 1050)
        for (above, below) in zip(steps, steps.dropFirst()) {
            // Within 1.5 of a cheaper step is the same look.
            #expect(above.vmaf >= below.vmaf + QualityScores.enough)
            #expect(above.target.videoKbps > below.target.videoKbps)
        }
        #expect(steps.allSatisfy { $0.target.videoKbps >= TranscodeLadder.floor(height: $0.target.height) })
        #expect(steps.count > 5)
    }

    @Test func aStepIsNamedByItsRateAndSize() {
        #expect(StreamStep(target: DownloadTarget(videoKbps: 3000, height: 720), vmaf: 84).title == "3.1 Mbps 720p")
        #expect(StreamStep(target: DownloadTarget(videoKbps: 11_000, height: 1080), vmaf: 96).title == "11 Mbps 1080p")
        #expect(StreamStep(target: DownloadTarget(videoKbps: 1050, height: 480), vmaf: 70).rateKbps == 1242)
    }

    // MARK: Phone and tablet

    @Test func aPhoneReadsThePhoneScoresOfTheCurveAndFallsBackWhenAnyPointLacksThem() {
        let points = [
            Point(kbps: 3000, vmaf: 80, height: 720, vmafPhone: 90), Point(kbps: 6000, vmaf: 90, height: 720, vmafPhone: 96),
        ]
        let entry = QualityMapEntry(ratingKey: "1", mediaID: "1", tiers: [:], curve: points)

        #expect(entry.curve(for: .phone).map(\.vmaf) == [90, 96])
        #expect(entry.curve(for: .tablet).map(\.vmaf) == [80, 90])
        // One point without a phone score: the standard curve whole, so the two scales never mix.
        var partial = points
        partial[1].vmafPhone = nil
        let older = QualityMapEntry(ratingKey: "1", mediaID: "1", tiers: [:], curve: partial)
        #expect(older.curve(for: .phone).map(\.vmaf) == [80, 90])
        #expect(QualityMapEntry(ratingKey: "1", mediaID: "1", tiers: [:]).curve(for: .phone).isEmpty)
    }

    static let phoneTiers: [DownloadTier: Point] = [
        .high: Point(kbps: 4800, vmaf: 95.1, height: 720), .medium: Point(kbps: 3000, vmaf: 90.2, height: 720),
        .low: Point(kbps: 1700, vmaf: 85.3, height: 480),
    ]

    static func scored(mediaID: String = "1", phone: [DownloadTier: Point]? = QualityMapTests.phoneTiers) -> QualityMapAnswer {
        .scored(QualityMapEntry(ratingKey: "301", mediaID: mediaID, tiers: DownloadQualityTests.entry().tiers, phoneTiers: phone))
    }

    @Test func aPhoneDownloadsByThePhoneTiersAndATabletByTheStandardOnes() throws {
        let media = try DownloadQualityTests.media()
        let answer = Self.scored()

        let phone = DownloadQualityTests.plan(media, answer: answer, screen: .phone)
        let tablet = DownloadQualityTests.plan(media, answer: answer, screen: .tablet)

        #expect(DownloadQualityTests.summary(phone) == [
            "high 720 4800 h264 vmaf 95.1", "medium 720 3000 h264 vmaf 90.2", "low 480 1700 h264 vmaf 85.3",
        ])
        #expect(DownloadQualityTests.summary(tablet) == ["high 1080 7400 h264 vmaf 95.2", "medium 720 3600 h264 vmaf 90.1"])
    }

    @Test func aPhoneFallsBackToTheStandardTiersWhereTheresNoPhoneScore() throws {
        let media = try DownloadQualityTests.media()
        let standard = DownloadQualityTests.summary(DownloadQualityTests.plan(media, answer: Self.scored(phone: nil), screen: .tablet))

        #expect(DownloadQualityTests.summary(DownloadQualityTests.plan(media, answer: Self.scored(phone: nil), screen: .phone)) == standard)
        // Tier by tier: only Low has a phone score here.
        let partial = Self.scored(phone: [.low: Point(kbps: 1700, vmaf: 85.3, height: 480)])
        #expect(DownloadQualityTests.summary(DownloadQualityTests.plan(media, answer: partial, screen: .phone)) == [
            "high 1080 7400 h264 vmaf 95.2", "medium 720 3600 h264 vmaf 90.1", "low 480 1700 h264 vmaf 85.3",
        ])
    }

    // MARK: Which answers count

    @Test func anAnswerCountsOnlyForTheVersionItIsAbout() throws {
        let media = try DownloadQualityTests.media(id: 7)
        let entry = QualityMapEntry(ratingKey: "301", mediaID: "7", tiers: [:])
        let sibling = QualityMapEntry(ratingKey: "999", mediaID: "7", tiers: [:])

        #expect(QualityMapAnswer.scored(entry).verified(for: media) == .scored(entry))
        // HomeLabber may answer with the scores of the same version under another title: measured all the same.
        #expect(QualityMapAnswer.scored(sibling).verified(for: media) == .scored(sibling))
        #expect(QualityMapAnswer.scored(QualityMapEntry(ratingKey: "301", mediaID: "8", tiers: [:])).verified(for: media) == .unscored)
        #expect(QualityMapAnswer.unscored.verified(for: media) == .unscored)
    }

    @Test func aTooSmallAnswerMustAgreeWithTheVersionItIsAppliedTo() throws {
        // 800 kbit/s of video and 640 of audio.
        let media = try DownloadQualityTests.media(id: 7, kbps: 800)
        func verified(_ kbps: Int?, version mediaID: String?) -> QualityMapAnswer {
            QualityMapAnswer.useOriginal(sourceKbps: kbps, mediaID: mediaID).verified(for: media)
        }

        #expect(verified(nil, version: "7") == .useOriginal(sourceKbps: nil, mediaID: "7"))
        #expect(verified(800, version: "8") == .unscored)
        // Without a version, the bitrate must be this one's, as the file's or the video's.
        #expect(verified(800, version: nil) == .useOriginal(sourceKbps: 800, mediaID: nil))
        #expect(verified(1440, version: nil) == .useOriginal(sourceKbps: 1440, mediaID: nil))
        #expect(verified(20_000, version: nil) == .unscored)
        #expect(verified(nil, version: nil) == .unscored)
    }

    @Test func aMapOnlyDrivesAutoForAMeasuredVersion() throws {
        let media = try DownloadQualityTests.media(id: 1)
        let points = [Point(kbps: 3000, vmaf: 84, height: 720), Point(kbps: 6000, vmaf: 93, height: 720)]
        let entry = QualityMapEntry(ratingKey: "1", mediaID: "1", tiers: [:], curve: points)

        #expect(QualityMapAnswer.scored(entry).curve(for: media, screen: .tablet)?.heights == [720])
        #expect(QualityMapAnswer.scored(QualityMapEntry(ratingKey: "1", mediaID: "2", tiers: [:], curve: points)).curve(for: media, screen: .tablet) == nil)
        #expect(QualityMapAnswer.scored(QualityMapEntry(ratingKey: "1", mediaID: "1", tiers: [:])).curve(for: media, screen: .tablet) == nil)
        #expect(QualityMapAnswer.useOriginal(sourceKbps: nil, mediaID: "1").curve(for: media, screen: .phone) == nil)
        #expect(QualityMapAnswer.unscored.curve(for: media, screen: .phone) == nil)
    }

    // MARK: Too small to convert

    @Test func aFileTooSmallToConvertIsOriginalAtEveryTier() throws {
        let small = try DownloadQualityTests.media(kbps: 800)
        let answer = QualityMapAnswer.useOriginal(sourceKbps: 800, mediaID: nil)

        let plan = DownloadQualityTests.plan(small, answer: answer)

        #expect(plan.options.map(\.quality) == [.original])
        #expect(DownloadTier.allCases.allSatisfy { plan.option(for: .tier($0))?.quality == .original })
        // An original the phone cannot play offline is converted at its own bitrate, as for any unmeasured file.
        let converts = DownloadQualityTests.plan(small, originalPlays: false, answer: answer)
        #expect(DownloadQualityTests.summary(converts) == ["high 480 800 h264 estimated"])
        // An answer for another version, or another bitrate, is not about this file.
        let other = DownloadQualityTests.plan(try DownloadQualityTests.media(), answer: .useOriginal(sourceKbps: 800, mediaID: "9"))
        #expect(other.options.count > 1)
        let wrongRate = DownloadQualityTests.plan(try DownloadQualityTests.media(), answer: .useOriginal(sourceKbps: 800, mediaID: nil))
        #expect(wrongRate.options.count > 1)
    }

    /// A client that answers everything with `body`.
    static func answering(_ body: [String: Any], status: Int = 200) -> HomeLabberClient {
        let data = try! JSONSerialization.data(withJSONObject: body)
        return DownloadQualityTests.client { _ in PlexHTTPResponse(status: status, body: data) }.0
    }

    @Test func theAnswerReadsTooSmallToConvertFrom404() async throws {
        func answer(_ body: [String: Any]) async throws -> QualityMapAnswer {
            try await Self.answering(body, status: 404).answer(server: "m", ratingKey: "1")
        }

        #expect(try await answer(["error": "Smaller than any transcode", "useOriginal": true, "sourceKbps": 900])
            == .useOriginal(sourceKbps: 900, mediaID: nil))
        #expect(try await answer(["useOriginal": true, "sourceKbps": 900, "mediaId": 12]) == .useOriginal(sourceKbps: 900, mediaID: "12"))
        #expect(try await answer(["useOriginal": true]) == .useOriginal(sourceKbps: nil, mediaID: nil))
        #expect(try await answer(["useOriginal": false, "sourceKbps": 900]) == .unscored)
        #expect(try await answer(["error": "Not scored yet"]) == .unscored)
    }

    @Test func theAnswerReadsPhoneTiersAndPhoneScoresAndSurvivesTheirAbsence() async throws {
        func entry(_ extra: [String: Any]) async throws -> QualityMapEntry {
            let base: [String: Any] = ["ratingKey": "301", "mediaId": 1, "tiers": ["high": ["kbps": 7400, "vmaf": 95.2, "height": 1080]]]
            let body = base.merging(extra) { _, new in new }
            let found = try await Self.answering(body).answer(server: "m", ratingKey: "301")
            guard case .scored(let entry) = found else { throw HomeLabberError.notHomeLabber }
            return entry
        }

        let phone = try await entry([
            "phoneTiers": ["high": ["kbps": 4800, "vmaf": 95.1, "height": 720], "low": NSNull()],
            "curve": [["kbps": 3000, "vmaf": 84, "height": 720, "vmafPhone": 91.5], ["kbps": 4800, "vmaf": 90, "height": 720]],
        ])
        #expect(phone.phoneTiers == [.high: Point(kbps: 4800, vmaf: 95.1, height: 720)])
        #expect(phone.curve.map(\.vmafPhone) == [91.5, nil])
        #expect(try await entry(["phoneTiers": NSNull()]).phoneTiers == nil)
        #expect(try await entry([:]).phoneTiers == nil)
    }
}

// MARK: - The shared lookup

/// The clock the cache reads, moved by hand.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date {
        lock.withLock { time }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { time = time.addingTimeInterval(seconds) }
    }
}

struct QualityMapCacheTests {
    private static func entryBody() -> [String: Any] {
        ["ratingKey": "1", "mediaId": 1, "tiers": ["high": ["kbps": 7400, "vmaf": 95.2, "height": 1080]]]
    }

    private static func client(token: String = "hlmq_0123456789abcdef0123", _ answer: @escaping FakeTransport.Handler) -> (HomeLabberClient, FakeTransport) {
        let transport = FakeTransport(answer)
        let config = HomeLabberConfig(address: URL(string: "https://homelabber.example.net")!, token: token)
        return (HomeLabberClient(config: config, transport: transport), transport)
    }

    @Test func oneRequestServesEveryoneAskingAboutATitle() async throws {
        let gate = Gate()
        let (client, transport) = Self.client { _, _ in
            await gate.wait()
            return json(Self.entryBody())
        }
        let cache = QualityMapCache()

        async let first = cache.answer(client, server: "m", ratingKey: "1")
        async let second = cache.answer(client, server: "m", ratingKey: "1")
        await gate.open()
        let answers = await [first, second, cache.answer(client, server: "m", ratingKey: "1")]

        #expect(answers.allSatisfy { if case .scored = $0 { true } else { false } })
        #expect(await transport.requests.count == 1)
    }

    @Test func aTitleNotMeasuredYetIsAskedAgainAfterTenMinutes() async {
        let clock = TestClock()
        let (client, transport) = Self.client { _, earlier in
            earlier.isEmpty ? json(["error": "Not scored yet"], status: 404) : json(Self.entryBody())
        }
        let cache = QualityMapCache(now: { clock.now() })

        #expect(await cache.answer(client, server: "m", ratingKey: "1") == .unscored)
        clock.advance(599)
        #expect(await cache.answer(client, server: "m", ratingKey: "1") == .unscored)
        #expect(await transport.requests.count == 1)
        clock.advance(2)
        let measured = await cache.answer(client, server: "m", ratingKey: "1")
        #expect(await transport.requests.count == 2)
        // A measured title is kept for the session.
        clock.advance(36_000)
        #expect(await cache.answer(client, server: "m", ratingKey: "1") == measured)
        #expect(await transport.requests.count == 2)
    }

    @Test func aFailedRequestSilencesEveryTitleForAMinute() async {
        let clock = TestClock()
        let (client, transport) = Self.client { _, _ in throw NetworkFailure.offline }
        let cache = QualityMapCache(now: { clock.now() })

        #expect(await cache.answer(client, server: "m", ratingKey: "1") == .unscored)
        #expect(await cache.answer(client, server: "m", ratingKey: "2") == .unscored)
        #expect(await transport.requests.count == 1)
        clock.advance(61)
        #expect(await cache.answer(client, server: "m", ratingKey: "2") == .unscored)
        #expect(await transport.requests.count == 2)
    }

    @Test func aNewTokenOrNoClientStartsOver() async {
        let (first, firstTransport) = Self.client { _, _ in json(Self.entryBody()) }
        let (second, secondTransport) = Self.client(token: "hlmq_another0123456789abcdef") { _, _ in json(Self.entryBody()) }
        let cache = QualityMapCache()

        _ = await cache.answer(first, server: "m", ratingKey: "1")
        _ = await cache.answer(second, server: "m", ratingKey: "1")
        #expect(await firstTransport.requests.count == 1)
        #expect(await secondTransport.requests.count == 1)
        // The plugin is off: nothing is asked, and what was kept for the last client is gone.
        #expect(await cache.answer(nil, server: "m", ratingKey: "1") == .unscored)
        _ = await cache.answer(second, server: "m", ratingKey: "1")
        #expect(await secondTransport.requests.count == 2)
    }
}
