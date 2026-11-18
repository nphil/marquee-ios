import Foundation
import Testing
@testable import MarqueeCore

struct DiagRedactorTests {
    @Test func urlKeepsHostAndPathAndDropsEveryQueryValue() {
        let url = URL(string: "https://user:pw@192-168-1-10.abc.plex.direct:32400/library/metadata/12?X-Plex-Token=secret123&includeChapters=1#frag")!
        #expect(DiagRedactor.redact(url: url) == "https://192-168-1-10.abc.plex.direct:32400/library/metadata/12?X-Plex-Token=…&includeChapters=…")
    }

    @Test func textLosesEverySecretItKnows() {
        let cases: [(String, String)] = [
            ("GET /library?X-Plex-Token=abcDEF123 failed", "GET /library?X-Plex-Token=… failed"),
            ("token=abc123&x=1", "token=…&x=1"),
            ("apikey=0123456789abcdef", "apikey=…"),
            ("api_key: 0123456789abcdef", "api_key: …"),
            ("X-Api-Key: 0123456789abcdef", "X-Api-Key: …"),
            ("Authorization: Bearer tk_abcdefghijklmnopqrstuvwxyz123", "Authorization: Bearer …"),
            ("Authorization: abc123", "Authorization: …"),
            ("sent hlmq_AbC-123_xyz to HomeLabber", "sent hlmq_… to HomeLabber"),
            ("Cookie: connect.sid=s%3Aabc; other=1", "Cookie: …"),
            (#"{"password":"hunter2"}"#, #"{"password":"…"}"#),
            ("see https://bazarr.local:6767/api/movies?apikey=abc&x=2 now", "see https://bazarr.local:6767/api/movies?apikey=…&x=… now"),
        ]
        for (text, expected) in cases {
            #expect(DiagRedactor.redact(text) == expected, "\(text)")
        }
    }

    @Test func ordinaryTextIsUntouched() {
        #expect(DiagRedactor.redact("ratingKey 212 · Gran Dillama") == "ratingKey 212 · Gran Dillama")
    }

    @Test func secretNamedFieldsAreNeverWritten() {
        let fields = DiagHub.format(["token": "abc", "accessToken": "def", "via": "farSeek"])
        #expect(fields == [DiagField("token", "…"), DiagField("accessToken", "…"), DiagField("via", "farSeek")])
    }
}

struct DiagEventTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func lineReadsTimeUptimeCategoryNameIdAndFieldsInOrder() {
        let event = DiagEvent(
            wall: Date(timeIntervalSince1970: 1_800_000_003.123), uptime: 12.344, level: .info, category: .player,
            name: "seek.request", fields: DiagHub.format(["from": 8.0, "to": 35.25, "via": "seekItem", "title": "Gran Dillama"]),
            playback: "p3"
        )
        #expect(event.line(in: utc) == #"08:00:03.123 +12.34s player seek.request id=p3 from=8 to=35.25 via=seekItem title="Gran Dillama""#)
    }

    @Test func levelsOtherThanInfoAreMarked() {
        let event = DiagEvent(wall: Date(timeIntervalSince1970: 0), uptime: 1, level: .warning, category: .offers, name: "skip.missed")
        #expect(event.line(in: utc) == "00:00:00.000 +1s W offers skip.missed")
    }

    @Test func valuesAreFormattedShortly() {
        let missing: Double? = nil
        let fields = DiagHub.format(["yes": true, "none": missing, "some": Optional(2.5), "int": 7, "error": URLError(.timedOut)])
        #expect(fields.map(\.value) == ["yes", "-", "2.5", "7", "NSURLErrorDomain -1001"])
    }
}

struct DiagBatcherTests {
    @Test func linesPackInOrderWithinTheLimit() {
        let lines = (0..<10).map { DiagLine(String(repeating: "a", count: 9) + "\($0)", level: $0 == 7 ? .warning : .info) }
        let messages = DiagPacker.pack(lines, limit: 31)
        // Ten 10-byte lines, two to a message: a third and its newline would make 32 bytes.
        #expect(messages.map(\.text) == [
            "aaaaaaaaa0\naaaaaaaaa1", "aaaaaaaaa2\naaaaaaaaa3", "aaaaaaaaa4\naaaaaaaaa5", "aaaaaaaaa6\naaaaaaaaa7", "aaaaaaaaa8\naaaaaaaaa9",
        ])
        #expect(messages.map(\.level) == [.info, .info, .info, .warning, .info])
        #expect(messages.allSatisfy { $0.text.utf8.count <= 31 })
    }

    @Test func aLongLineIsCutOnACharacterBoundary() {
        // "é" is two bytes; a cut at an odd byte would split one.
        let line = String(repeating: "é", count: 50)
        let cut = DiagPacker.clamp(line, toBytes: 20)
        #expect(cut.utf8.count <= 20)
        #expect(cut == String(repeating: "é", count: 8) + "…")
        #expect(DiagPacker.pack([DiagLine(line)], limit: 20).map(\.text) == [cut])
    }

    @Test func bucketBurstsThenRefills() {
        let start = Date(timeIntervalSince1970: 0)
        var bucket = TokenBucket(capacity: 3, refill: 5, now: start)
        let burst = (0..<4).map { _ in bucket.take(now: start) }
        #expect(burst == [true, true, true, false])
        #expect(abs(bucket.wait(now: start.addingTimeInterval(2)) - 3) < 1e-9)
        let later = [bucket.take(now: start.addingTimeInterval(5)), bucket.take(now: start.addingTimeInterval(6))]
        #expect(later == [true, false])
    }

    @Test func backoffDoublesAndHonoursRetryAfter() {
        let now = Date(timeIntervalSince1970: 1000)
        var backoff = DiagBackoff()
        backoff.failed(status: nil, retryAfter: nil, now: now)
        #expect(backoff.notBefore == now.addingTimeInterval(5))
        backoff.failed(status: nil, retryAfter: nil, now: now)
        #expect(backoff.notBefore == now.addingTimeInterval(10))
        backoff.failed(status: 429, retryAfter: "42", now: now)
        #expect(backoff.notBefore == now.addingTimeInterval(42))
        backoff.failed(status: 503, retryAfter: "Thu, 01 Jan 1970 00:20:00 GMT", now: now)
        #expect(backoff.notBefore == Date(timeIntervalSince1970: 1200))
        #expect(!backoff.ready(now: now))
        backoff.succeeded()
        #expect(backoff.ready(now: now) && backoff.failures == 0)
    }

    @Test func repeatsFoldIntoACount() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func event(_ name: String, at second: Double) -> DiagEvent {
            DiagEvent(wall: Date(timeIntervalSince1970: second), uptime: second, level: .info, category: .player, name: name)
        }
        var coalescer = DiagCoalescer()
        var lines: [String] = []
        for second in 0..<4 { lines += coalescer.add(event("stall", at: Double(second)), in: calendar).map(\.text) }
        lines += coalescer.add(event("play", at: 9), in: calendar).map(\.text)
        lines += coalescer.flush(in: calendar).map(\.text)
        #expect(lines == [
            "00:00:00.000 +0s player stall",
            "00:00:03.000 +3s player stall ×3",
            "00:00:09.000 +9s player play",
        ])
    }
}

struct DiagJournalPolicyTests {
    private let policy = DiagJournalPolicy(fileBytes: 100, totalBytes: 250, maxAge: 3600)
    private let now = Date(timeIntervalSince1970: 100_000)

    @Test func aFileRotatesBeforeItOutgrowsItsLimit() {
        #expect(!policy.rotates(currentBytes: 0, adding: 500))
        #expect(!policy.rotates(currentBytes: 60, adding: 40))
        #expect(policy.rotates(currentBytes: 61, adding: 40))
    }

    @Test func oldFilesGoThenTheOldestUntilTheRestFit() {
        let files = [
            DiagJournalPolicy.File(name: "c", bytes: 100, modified: now.addingTimeInterval(-60)),
            DiagJournalPolicy.File(name: "a", bytes: 10, modified: now.addingTimeInterval(-7200)),
            DiagJournalPolicy.File(name: "b", bytes: 100, modified: now.addingTimeInterval(-120)),
            DiagJournalPolicy.File(name: "d", bytes: 100, modified: now),
        ]
        // "a" is older than an hour; then 300 bytes remain, so "b", the oldest, goes too.
        #expect(policy.removals(files, current: "d", now: now) == ["a", "b"])
    }

    @Test func theFileBeingWrittenStays() {
        let files = [DiagJournalPolicy.File(name: "only", bytes: 900, modified: now.addingTimeInterval(-9000))]
        #expect(policy.removals(files, current: "only", now: now).isEmpty)
    }
}

struct SkipCheckTests {
    /// The verdicts for successive checks of `(playhead, advanced, pending)`.
    private func verdicts(_ steps: [(TimeInterval, TimeInterval, Bool)], check: inout SkipCheck) -> [SkipCheck.Verdict] {
        steps.map { check.check(playhead: $0.0, advanced: $0.1, pending: $0.2) }
    }

    @Test func aSkipThatArrivesIsLanded() {
        var check = SkipCheck(target: 35)
        #expect(verdicts([(34.2, 0, false)], check: &check) == [.landed])
    }

    @Test func nothingIsJudgedWhileASeekIsOnItsWay() {
        var check = SkipCheck(target: 35)
        let steps = Array(repeating: (TimeInterval(12), TimeInterval(1), true), count: 10)
        #expect(verdicts(steps, check: &check) == Array(repeating: .waiting, count: 10))
        #expect(check.played == 0)
    }

    @Test func aMissIsRetriedOnceThenGivenUp() {
        var check = SkipCheck(target: 35)
        let steps: [(TimeInterval, TimeInterval, Bool)] = [(10, 1, false), (11, 1, false), (12, 1, false), (13, 2.5, false), (14, 1, false)]
        #expect(verdicts(steps, check: &check) == [.waiting, .waiting, .retry, .waiting, .missed])
    }

    @Test func theRetryLandingEndsTheCheck() {
        var check = SkipCheck(target: 35)
        let steps: [(TimeInterval, TimeInterval, Bool)] = [(10, 1, false), (11, 1, false), (12, 1, false), (12, 0, true), (35.1, 0, false)]
        #expect(verdicts(steps, check: &check) == [.waiting, .waiting, .retry, .waiting, .landed])
    }
}

struct NtfyTests {
    @Test func settingsParseAndRefuseWhatNtfyWouldNot() {
        let parsed = try? NtfyConfig.parse(server: " https://ntfy.example.net/ ", topic: "marquee-logs", token: " tk_abc ").get()
        #expect(parsed == NtfyConfig(server: URL(string: "https://ntfy.example.net")!, topic: "marquee-logs", token: "tk_abc"))
        #expect(NtfyConfig.parse(server: "ftp://ntfy.example.net", topic: "a", token: "") == .failure(.scheme))
        #expect(NtfyConfig.parse(server: "http://ntfy.example.net", topic: "a", token: "") == .failure(.plaintext))
        #expect((try? NtfyConfig.parse(server: "http://192.168.1.20:8080", topic: "a", token: "").get())?.token == nil)
        #expect(NtfyConfig.parse(server: "https://ntfy.example.net", topic: "bad topic", token: "") == .failure(.topic))
        #expect(NtfyConfig.parse(server: "https://ntfy.example.net", topic: "a", token: "tk with space") == .failure(.token))
    }

    @Test func aBatchIsAPostWithTheTokenAndUTF8InTheQuery() throws {
        let config = NtfyConfig(server: URL(string: "https://ntfy.example.net/base")!, topic: "logs", token: "tk_abc")
        let request = config.publish(NtfyMessage(title: "Marquee 0.1.45 · Isabel’s iPhone", text: "line", priority: .min))
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://ntfy.example.net/base/logs?title=Marquee%200.1.45%20%C2%B7%20Isabel%E2%80%99s%20iPhone")
        #expect(request.headers["Authorization"] == "Bearer tk_abc")
        #expect(request.headers["Priority"] == "1")
        #expect(request.body == Data("line".utf8))
    }

    @Test func aReportIsAPutCarryingTheFile() {
        let config = NtfyConfig(server: URL(string: "https://ntfy.example.net")!, topic: "logs", token: nil)
        let attachment = NtfyMessage.Attachment(data: Data("journal".utf8), filename: "marquee-x.log", contentType: "text/plain")
        let request = config.publish(NtfyMessage(title: nil, text: "a+b & c", tags: ["memo"], attachment: attachment))
        #expect(request.method == .put)
        #expect(request.url.absoluteString == "https://ntfy.example.net/logs?filename=marquee-x.log&message=a%2Bb%20%26%20c")
        #expect(request.headers["Authorization"] == nil)
        #expect(request.headers["Tags"] == "memo")
    }

    @Test func answersAreToldApart() {
        #expect(NtfyAnswer(status: 200, body: Data()) == .accepted)
        #expect(NtfyAnswer(status: 401, body: Data()) == .needsToken)
        #expect(NtfyAnswer(status: 403, body: Data()) == .refused)
        #expect(NtfyAnswer(status: 400, body: Data(#"{"error":"invalid request: attachments not allowed"}"#.utf8)) == .attachmentRefused)
        #expect(NtfyAnswer(status: 429, body: Data()).isTransient)
        #expect(NtfyAnswer(status: 502, body: Data()) == .serverError(502))
    }

    @Test func reportFilenamesAreASCII() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let name = NtfyConfig.reportFilename(device: "Isabel’s iPhone", at: Date(timeIntervalSince1970: 1_800_000_003), calendar: calendar)
        #expect(name == "marquee-isabel-s-iphone-20270115-080003.log")
    }
}
