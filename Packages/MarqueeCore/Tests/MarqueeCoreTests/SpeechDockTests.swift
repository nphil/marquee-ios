import Foundation
import Testing
@testable import MarqueeCore

struct SpeechDockTests {
    static let identity = SpeechDock.Identity(
        server: "abc", ratingKey: "5", media: "1", part: "7", partKey: "/library/parts/7/1/file.mkv",
        audio: "2", subtitle: "9", codec: "srt"
    )

    static func cue(_ ordinal: Int, _ start: Int, _ end: Int, _ text: String = "Hello there") -> SpeechDock.Cue {
        SpeechDock.Cue(ordinal: ordinal, start: start, end: end, text: text)
    }

    @Test func addressesAreOriginsAndPlainHTTPStaysHome() throws {
        #expect(try SpeechDock.origin(" https://speechdock.example.com/ ").get().absoluteString == "https://speechdock.example.com")
        #expect(try SpeechDock.origin("http://192.168.1.71:8000").get().absoluteString == "http://192.168.1.71:8000")
        #expect(SpeechDock.origin("http://speechdock.example.com") == .failure(.plaintext))
        #expect(SpeechDock.origin("ftp://192.168.1.71") == .failure(.scheme))
        #expect(SpeechDock.origin("https://user:secret@speechdock.example.com") == .failure(.notOrigin))
        #expect(SpeechDock.origin("https://speechdock.example.com/api") == .failure(.notOrigin))
    }

    @Test func onlyAnEnglishTextFileAndEnglishSoundCanBeTimed() throws {
        func media(_ container: String, audio: String = "eng", subtitle: [String: Any]) throws -> PlexMedia {
            try decode(PlexMedia.self, [
                "id": 1, "container": container,
                "Part": [["id": 7, "key": "/library/parts/7/1/file.mkv", "container": container, "Stream": [
                    ["id": 2, "streamType": 2, "languageCode": audio],
                    subtitle,
                ]]],
            ])
        }
        let sidecar: [String: Any] = ["id": 9, "streamType": 3, "languageCode": "eng", "codec": "srt", "key": "/library/streams/9"]
        #expect(SpeechDock.identity(server: "abc", ratingKey: "5", media: try media("mkv", subtitle: sidecar), audio: 2, subtitle: 9) == Self.identity)
        #expect(SpeechDock.identity(server: "abc", ratingKey: "5", media: try media("mkv", audio: "fre", subtitle: sidecar), audio: 2, subtitle: 9) == nil)
        #expect(SpeechDock.identity(server: "abc", ratingKey: "5", media: try media("avi", subtitle: sidecar), audio: 2, subtitle: 9) == nil)
        var embedded = sidecar
        embedded["key"] = nil
        #expect(SpeechDock.identity(server: "abc", ratingKey: "5", media: try media("mkv", subtitle: embedded), audio: 2, subtitle: 9) == nil)
    }

    @Test func theFileIsReadAsSpeechDockReadsItAndMarkupRefusesIt() throws {
        let file = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02.500\r\nHello there\r\nfriend\r\n\r\n00:01:00,000 --> 01:00:01,000\r\nBye\r\n"
        let cues = try #require(SpeechDock.cues(Data(file.utf8)))
        #expect(cues == [Self.cue(0, 1_000, 2_500, "Hello there\nfriend"), Self.cue(1, 60_000, 3_601_000, "Bye")])
        #expect(SpeechDock.cues(Data("1\n00:00:01,000 --> 00:00:02,000\n<i>Hello</i>\n".utf8)) == nil)
        #expect(SpeechDock.cues(Data("1\n00:00:02,000 --> 00:00:01,000\nHello\n".utf8)) == nil)
    }

    @Test func onlyLoneShortCuesOfPlainEnglishWordsAreAskedAbout() {
        let cues = [
            Self.cue(0, 0, 1_000, "Run, now!"),
            Self.cue(1, 2_000, 4_000, "Overlapping"), Self.cue(2, 3_000, 5_000, "Each other"),
            Self.cue(3, 6_000, 22_000, "Too long"),
            Self.cue(4, 23_000, 24_000, "In 1984"),
            Self.cue(5, 25_000, 26_000, "No, no"),
            Self.cue(6, 27_000, 28_000, "Don’t go"),
        ]
        #expect(SpeechDock.alignable(cues).map(\.ordinal) == [0, 6])
    }

    @Test func aWindowStartsAtTheCueOnScreenAndKeepsWithinItsLimits() {
        let dense = (0..<40).map { Self.cue($0, $0 * 500, $0 * 500 + 400) }
        #expect(SpeechDock.window(dense, asked: [1], due: 600, offset: 0).map(\.ordinal) == Array(2...33))
        let sparse = (0..<40).map { Self.cue($0, $0 * 2_000, $0 * 2_000 + 1_500) }
        #expect(SpeechDock.window(sparse, asked: [], due: 0, offset: 0).last?.ordinal == 14)
        #expect(SpeechDock.window(sparse, asked: Set(0..<10), due: 0, offset: 0).isEmpty)
        // A cue that is over before the video starts is never seen.
        #expect(SpeechDock.window(sparse, asked: [], due: 0, offset: -2_000).first?.ordinal == 1)
        #expect(SpeechDock.window(sparse, asked: [], due: 0, offset: 3_600_001).isEmpty)
        let wordy = (0..<3).map { Self.cue($0, $0 * 1_000, $0 * 1_000 + 900, String(repeating: "a", count: 2_000)) }
        #expect(SpeechDock.window(wordy, asked: [], due: 0, offset: 0).count == 2)
    }

    @Test func aRequestCarriesTheCuesAsTheyShow() throws {
        let request = SpeechDock.Request(
            id: "r1", generation: 2, playback: "p1", identity: Self.identity, digest: String(repeating: "a", count: 64),
            offset: -1_500, cues: [Self.cue(0, 1_000, 2_500), Self.cue(1, 3_000, 4_000)]
        )
        struct Sent: Decodable {
            struct Cue: Decodable { var cueId: String, authoredStartMs: Int, startMs: Int, endMs: Int, text: String }
            struct Identity: Decodable { var partKey: String, subtitleStreamId: String }
            var `protocol`: Int, requestId: String, playbackId: String, subtitleOffsetMs: Int, windowStartMs: Int, windowEndMs: Int
            var identity: Identity
            var cues: [Cue]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let sent = try decoder.decode(Sent.self, from: JSONEncoder().encode(request))
        #expect(sent.protocol == 1 && sent.requestId == "r1" && sent.playbackId == "p1" && sent.subtitleOffsetMs == -1_500)
        #expect(sent.windowStartMs == 0 && sent.windowEndMs == 2_500)
        let first = try #require(sent.cues.first)
        #expect(first.cueId == "0" && first.authoredStartMs == 1_000 && first.startMs == 0 && first.endMs == 1_000 && first.text == "Hello there")
        #expect(sent.identity.partKey == "/library/parts/7/1/file.mkv" && sent.identity.subtitleStreamId == "9")
    }

    @Test func measuredWordsMustBeTheCuesOwn() async throws {
        let request = SpeechDock.Request(
            id: "r1", generation: 2, playback: "p1", identity: Self.identity, digest: String(repeating: "a", count: 64),
            offset: 500, cues: [Self.cue(0, 1_000, 3_000, "Hello there."), Self.cue(1, 4_000, 6_000, "Hello there.")]
        )
        func word(_ bytes: Range<Int>, _ start: Int, _ end: Int) -> [String: Any] {
            ["start_byte": bytes.lowerBound, "end_byte": bytes.upperBound, "start_ms": start, "end_ms": end]
        }
        let reply = json(["request_id": "r1", "generation": 2, "source_revision": "x", "cues": [
            ["cue_id": "0", "status": "aligned", "words": [word(0..<5, 1_600, 2_000), word(6..<12, 2_100, 2_900)]],
            // "there" without its full stop is not SpeechDock's word for this cue.
            ["cue_id": "1", "status": "aligned", "words": [word(0..<5, 4_600, 5_000), word(6..<11, 5_100, 5_900)]],
        ]])
        let transport = FakeTransport { request, _ in
            request.url.path == "/health" ? json(["status": "ok", "version": "0.5.1"]) : reply
        }
        let client = SpeechDockClient(origin: URL(string: "http://192.168.1.71:8000")!, transport: transport)
        #expect(try await client.health() == "0.5.1")
        let answer = try await client.align(request)
        #expect(answer.outcome == .read && answer.words == [0: [0.1, 0.6]])

        let busy = SpeechDock.Reply(requestID: "r1", generation: 2, sourceRevision: nil, cues: [
            .init(cueID: "0", status: "estimated", reason: "alignment_busy", words: []),
        ])
        #expect(SpeechDock.answer(busy, to: request).outcome == .busy)
    }

    @Test func anAddressThatIsNotSpeechDockStopsTheAsking() async throws {
        let request = SpeechDock.Request(
            id: "r1", generation: 2, playback: "p1", identity: Self.identity, digest: String(repeating: "a", count: 64),
            offset: 0, cues: [Self.cue(0, 1_000, 3_000)]
        )
        let origin = URL(string: "http://192.168.1.71:8000")!
        let down = SpeechDockClient(origin: origin, transport: FakeTransport { _, _ in throw NetworkFailure.cannotConnect })
        await #expect(throws: SpeechDock.Failure.unreachable) { try await down.health() }
        let other = SpeechDockClient(origin: origin, transport: FakeTransport { request, _ in
            request.url.path == "/health" ? json(["status": "ok"]) : json(["request_id": "r0", "generation": 2, "cues": []])
        })
        await #expect(throws: SpeechDock.Failure.notSpeechDock) { try await other.health() }
        await #expect(throws: SpeechDock.Failure.notSpeechDock) { try await other.align(request) }
        let refusing = SpeechDockClient(origin: origin, transport: FakeTransport { _, _ in json(["detail": "Invalid"], status: 422) })
        await #expect(throws: SpeechDock.Failure.rejected(422)) { try await refusing.align(request) }
    }
}
