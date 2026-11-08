import Foundation

/// SpeechDock, the owner's word-timing service (protocol 1). Marquee names the playing file, its audio and
/// subtitle streams and up to 30 s of cues; SpeechDock reads the audio and the subtitle file from Plex itself
/// and answers with when each word is spoken. It times English sidecar text files only, and refuses a whole
/// file that carries any markup.
public enum SpeechDock {
    public enum OriginProblem: Error, Sendable, Equatable {
        /// Neither https:// nor http://.
        case scheme
        case host
        /// A path, query, fragment or sign-in: the service is addressed by its origin alone.
        case notOrigin
        /// Plain http:// to a host outside the home network.
        case plaintext
    }

    /// The service from what was typed in Settings.
    public static func origin(_ text: String) -> Result<URL, OriginProblem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed), let scheme = parts.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return .failure(.scheme) }
        guard let host = parts.host, !host.isEmpty, !host.contains(" ") else { return .failure(.host) }
        guard parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return .failure(.notOrigin) }
        if scheme == "http", !HomeNetwork.contains(host) { return .failure(.plaintext) }
        var origin = parts
        origin.path = ""
        guard let url = origin.url else { return .failure(.host) }
        return .success(url)
    }

    // MARK: What it can time

    static let codecs: Set<String> = ["srt", "subrip", "webvtt", "mov_text", "text"]
    static let languages: Set<String> = ["en", "eng"]
    /// Containers whose clock starts at 0, so the player's time is the container's.
    static let containers: Set<String> = ["mkv", "mp4", "m4v", "mov", "webm"]

    /// What SpeechDock checks against Plex before it reads anything.
    public struct Identity: Sendable, Equatable, Encodable {
        var server: String
        var ratingKey: String
        var media: String
        var part: String
        var partKey: String
        var audio: String
        var subtitle: String
        var codec: String

        enum CodingKeys: String, CodingKey {
            case server = "server_machine_id", ratingKey = "rating_key", media = "media_id", part = "part_id"
            case partKey = "part_key", audio = "audio_stream_id", subtitle = "subtitle_stream_id", codec = "subtitle_codec"
        }
    }

    /// The identity of a choice SpeechDock can time: an English text sidecar and English audio, in a
    /// one-part file whose container starts at 0. Nil for any other choice.
    public static func identity(server: String, ratingKey: String, media: PlexMedia, audio: Int, subtitle: Int) -> Identity? {
        guard media.parts.count == 1, let part = media.parts.first,
              let container = (part.container ?? media.container)?.lowercased(), containers.contains(container),
              let sound = part.streams.first(where: { $0.id == audio }), languages.contains(sound.languageCode ?? ""),
              let text = part.streams.first(where: { $0.id == subtitle }), languages.contains(text.languageCode ?? ""),
              let codec = text.codec, codecs.contains(codec), text.key == "/library/streams/\(subtitle)" else { return nil }
        let identity = Identity(
            server: server, ratingKey: ratingKey, media: String(media.id), part: String(part.id), partKey: part.key,
            audio: String(audio), subtitle: String(subtitle), codec: codec
        )
        let numbers = [identity.ratingKey, identity.media, identity.part, identity.audio, identity.subtitle]
        guard (1...128).contains(server.count), (1...512).contains(part.key.count), codec.count <= 32,
              numbers.allSatisfy({ (1...20).contains($0.count) && $0.allSatisfy { ("0"..."9").contains($0) } }) else { return nil }
        return identity
    }

    // MARK: The file as SpeechDock reads it

    /// A cue as SpeechDock reads the file: its place in the file, its times in milliseconds and its text.
    public struct Cue: Sendable, Hashable {
        public var ordinal: Int
        public var start: Int
        public var end: Int
        public var text: String

        public init(ordinal: Int, start: Int, end: Int, text: String) {
            self.ordinal = ordinal
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// The cues of a subtitle file read the way SpeechDock reads it, or nil when it would refuse the file:
    /// anything but plain SRT, any markup, or no cues.
    public static func cues(_ data: Data) -> [Cue]? {
        var bytes = data[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let decoded = String(validating: bytes, as: UTF8.self) else { return nil }
        var scalars: [Unicode.Scalar] = []
        var afterReturn = false
        for scalar in decoded.unicodeScalars {
            if scalar == "\r" {
                scalars.append("\n")
            } else if !(scalar == "\n" && afterReturn) {
                scalars.append(scalar)
            }
            afterReturn = scalar == "\r"
        }
        var cues: [Cue] = []
        for block in blocks(trimmed(scalars[...])) {
            let lines = lines(block)
            guard let head = lines.first, !head.starts(with: "WEBVTT".unicodeScalars) else { continue }
            let position = range(of: arrow, in: head[...]) == nil ? 1 : 0
            guard position < lines.count, let times = timing(lines[position][...]), times.end > times.start else { return nil }
            let text = Array(lines[(position + 1)...].joined(separator: ["\n"]))
            guard !text.isEmpty, !text.contains(where: { "<>\\{}".unicodeScalars.contains($0) }) else { return nil }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: text)
            cues.append(Cue(ordinal: cues.count, start: times.start, end: times.end, text: String(view)))
        }
        return cues.isEmpty || cues.count > 100_000 ? nil : cues
    }

    /// The cues worth asking about, by start: SpeechDock times a cue only when the file has it once, no other
    /// cue overlaps it, it lasts at most 15 s and its text is plain English words, each at most once.
    public static func alignable(_ cues: [Cue]) -> [Cue] {
        struct Key: Hashable { var start: Int, end: Int, text: String }
        var counts: [Key: Int] = [:]
        for cue in cues { counts[Key(start: cue.start, end: cue.end, text: cue.text), default: 0] += 1 }
        let sorted = cues.sorted { ($0.start, $0.ordinal) < ($1.start, $1.ordinal) }
        var picked: [Cue] = []
        var reach = Int.min
        for (index, cue) in sorted.enumerated() {
            let overlapsEarlier = reach > cue.start
            let overlapsLater = index + 1 < sorted.count && sorted[index + 1].start < cue.end
            reach = max(reach, cue.end)
            guard !overlapsEarlier, !overlapsLater, counts[Key(start: cue.start, end: cue.end, text: cue.text)] == 1,
                  cue.end - cue.start <= 15_000, isPlainEnglish(cue.text) else { continue }
            picked.append(cue)
        }
        return picked
    }

    /// The next cues to ask about: from the first not yet asked that is showing or still to come at `due` (ms
    /// on the file's clock) and starts within `ahead`, as many as one request may carry. `cues` come from
    /// `alignable`; `offset` moves each cue later on screen, in ms. None beyond SpeechDock's one-hour offset.
    public static func window(_ cues: [Cue], asked: Set<Int>, due: Int, offset: Int, ahead: Int = 20_000) -> [Cue] {
        guard abs(offset) <= 3_600_000 else { return [] }
        // Its times stay within a day, and a cue that is over before the video starts is never seen.
        func fits(_ cue: Cue) -> Bool {
            !asked.contains(cue.ordinal) && cue.end <= 86_400_000 && cue.end + offset > 0 && cue.end + offset <= 86_400_000
        }
        guard let first = cues.firstIndex(where: { $0.end > due && fits($0) }), cues[first].start < due + ahead else { return [] }
        var picked: [Cue] = []
        var bytes = 0
        for cue in cues[first...] where fits(cue) {
            // Alignable cues never overlap, so their ends rise with their starts.
            guard picked.count < 32, cue.end - cues[first].start <= 30_000, bytes + cue.text.utf8.count <= 4_096 else { break }
            picked.append(cue)
            bytes += cue.text.utf8.count
        }
        return picked
    }

    // MARK: Asking

    /// One window of cues, as sent.
    public struct Request: Sendable, Encodable {
        public var id: String
        /// Answers for an earlier generation are stale.
        public var generation: Int
        /// The same for every request of one playback.
        public var playback: String
        public var identity: Identity
        /// SHA-256 of the file as Plex serves it with `?encoding=utf-8&format=srt`, in lowercase hex.
        public var digest: String
        /// Milliseconds the cues show later than the file says.
        public var offset: Int
        public var cues: [Cue]

        public init(id: String, generation: Int, playback: String, identity: Identity, digest: String, offset: Int, cues: [Cue]) {
            self.id = id
            self.generation = generation
            self.playback = playback
            self.identity = identity
            self.digest = digest
            self.offset = offset
            self.cues = cues
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Field.self)
            try c.encode(1, forKey: .protocol)
            try c.encode(id, forKey: .requestID)
            try c.encode(generation, forKey: .generation)
            try c.encode(playback, forKey: .playbackID)
            try c.encode(identity, forKey: .identity)
            try c.encode("sidecar", forKey: .sourceKind)
            try c.encode("source_bytes_sha256", forKey: .hashKind)
            try c.encode(digest, forKey: .digest)
            try c.encode("en", forKey: .language)
            try c.encode("container_pts", forKey: .timeline)
            try c.encode(0, forKey: .origin)
            try c.encode(offset, forKey: .offset)
            try c.encode(cues.map(shows).min() ?? 0, forKey: .windowStart)
            try c.encode((cues.map(\.end).max() ?? 0) + offset, forKey: .windowEnd)
            var list = c.nestedUnkeyedContainer(forKey: .cues)
            for cue in cues {
                var item = list.nestedContainer(keyedBy: CueField.self)
                try item.encode(String(cue.ordinal), forKey: .id)
                try item.encode(cue.ordinal, forKey: .ordinal)
                try item.encode(cue.start, forKey: .authoredStart)
                try item.encode(cue.end, forKey: .authoredEnd)
                try item.encode(shows(cue), forKey: .start)
                try item.encode(cue.end + offset, forKey: .end)
                try item.encode(cue.text, forKey: .text)
            }
        }

        /// When a cue shows, in ms: an early one waits for the video to start.
        private func shows(_ cue: Cue) -> Int {
            max(0, cue.start + offset)
        }

        private enum Field: String, CodingKey {
            case `protocol`, generation, identity, language, timeline, cues
            case requestID = "request_id", playbackID = "playback_id", sourceKind = "subtitle_source_kind"
            case hashKind = "subtitle_hash_kind", digest = "subtitle_source_sha256", origin = "media_origin_pts_ms"
            case offset = "subtitle_offset_ms", windowStart = "window_start_ms", windowEnd = "window_end_ms"
        }

        private enum CueField: String, CodingKey {
            case ordinal, text
            case id = "cue_id", authoredStart = "authored_start_ms", authoredEnd = "authored_end_ms", start = "start_ms", end = "end_ms"
        }
    }

    public struct Answer: Sendable, Equatable {
        public enum Outcome: Sendable, Equatable {
            /// SpeechDock read the window; cues without words keep their estimate.
            case read
            /// Its one worker and its one waiting place are taken: ask again shortly.
            case busy
            /// It could not read the file or the media at all, for the reason it names.
            case refused(String)
        }

        public var outcome: Outcome
        /// Measured times by cue ordinal: when each of the cue's words starts, in seconds after the cue
        /// shows, one per word as `SubtitleReveal.measured` takes them.
        public var words: [Int: [TimeInterval]]
    }

    public enum Failure: Error, Sendable, Equatable {
        case unreachable
        /// The address answered, but not like SpeechDock, or for another request.
        case notSpeechDock
        /// SpeechDock turned the request down with this HTTP status.
        case rejected(Int)
    }

    // MARK: Reading the file

    private static let arrow = Array(" --> ".unicodeScalars)
    private static let lineBreaks: Set<Unicode.Scalar> = ["\n", "\u{0B}", "\u{0C}", "\r", "\u{1C}", "\u{1D}", "\u{1E}", "\u{85}", "\u{2028}", "\u{2029}"]

    /// Python's `str.isspace`, which SpeechDock's reader splits and trims on.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
    }

    private static func trimmed(_ scalars: ArraySlice<Unicode.Scalar>) -> ArraySlice<Unicode.Scalar> {
        guard let first = scalars.firstIndex(where: { !isSpace($0) }), let last = scalars.lastIndex(where: { !isSpace($0) }) else { return [] }
        return scalars[first...last]
    }

    /// Splits at every blank line: a run of white space holding two or more line feeds, from its first line
    /// feed to its last.
    private static func blocks(_ text: ArraySlice<Unicode.Scalar>) -> [ArraySlice<Unicode.Scalar>] {
        var blocks: [ArraySlice<Unicode.Scalar>] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            guard isSpace(text[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < text.endIndex, isSpace(text[end]) { end += 1 }
            let run = text[index..<end]
            if let first = run.firstIndex(of: "\n"), let last = run.lastIndex(of: "\n"), first != last {
                blocks.append(text[start..<first])
                start = last + 1
            }
            index = end
        }
        blocks.append(text[start...])
        return blocks
    }

    /// Python's `str.splitlines`: no empty line after a final break.
    private static func lines(_ block: ArraySlice<Unicode.Scalar>) -> [[Unicode.Scalar]] {
        var lines: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        for scalar in block {
            if lineBreaks.contains(scalar) {
                lines.append(current)
                current = []
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private static func range(of needle: [Unicode.Scalar], in line: ArraySlice<Unicode.Scalar>) -> Range<Int>? {
        guard line.count >= needle.count else { return nil }
        for start in line.startIndex...(line.endIndex - needle.count) where line[start..<(start + needle.count)].elementsEqual(needle) {
            return start..<(start + needle.count)
        }
        return nil
    }

    /// `[HH:]MM:SS,mmm --> [HH:]MM:SS,mmm` (a full stop also separates the milliseconds), in ms.
    private static func timing(_ line: ArraySlice<Unicode.Scalar>) -> (start: Int, end: Int)? {
        guard let split = range(of: arrow, in: line), let start = stamp(line[..<split.lowerBound]),
              let end = stamp(line[split.upperBound...]) else { return nil }
        return (start, end)
    }

    private static func stamp(_ text: ArraySlice<Unicode.Scalar>) -> Int? {
        let fields = text.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3, let last = fields.last, last.count == 6,
              last[last.startIndex + 2] == "," || last[last.startIndex + 2] == "." else { return nil }
        let hours = fields.count == 3 ? fields[0] : ["0", "0"]
        // More than nine digits of hours is no film; refusing it keeps the sum in range.
        guard (2...9).contains(hours.count), let hour = number(hours), fields[fields.count - 2].count == 2,
              let minute = number(fields[fields.count - 2]), let second = number(last.prefix(2)),
              let milli = number(last.suffix(3)), minute <= 59, second <= 59 else { return nil }
        return ((hour * 60 + minute) * 60 + second) * 1000 + milli
    }

    private static func number(_ digits: ArraySlice<Unicode.Scalar>) -> Int? {
        guard !digits.isEmpty else { return nil }
        var value = 0
        for digit in digits {
            guard ("0"..."9").contains(digit) else { return nil }
            value = value * 10 + Int(digit.value - 48)
        }
        return value
    }

    // MARK: Words SpeechDock times

    private static let punctuation: Set<Unicode.Scalar> = [".", ",", "!", "?", ";", ":", "\"", "(", ")", "“", "”", "‘", "’", "…", "—", "–"]

    /// Its word rule: once punctuation is trimmed from both ends, every word is letters A to Z with inner
    /// apostrophes; no word twice, and 1 to 64 of them.
    static func isPlainEnglish(_ text: String) -> Bool {
        guard text.unicodeScalars.count <= 2_048, text.utf8.count <= 4_096 else { return false }
        var seen = Set<String>()
        for token in text.unicodeScalars.split(whereSeparator: isSpace) {
            var lexical = token[...]
            while let first = lexical.first, punctuation.contains(first) { lexical.removeFirst() }
            while let last = lexical.last, punctuation.contains(last) { lexical.removeLast() }
            let pieces = lexical.split(separator: "’", omittingEmptySubsequences: false)
                .flatMap { $0.split(separator: "'", omittingEmptySubsequences: false) }
            guard pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) } }) else { return false }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: lexical.map { $0 == "’" ? "'" : $0 })
            guard seen.insert(String(view).uppercased()).inserted, seen.count <= 64 else { return false }
        }
        return !seen.isEmpty
    }

    // MARK: Reading the answer

    struct Reply: Decodable {
        var requestID: String
        var generation: Int
        var sourceRevision: String?
        var cues: [Timed]

        struct Timed: Decodable {
            var cueID: String
            var status: String
            var reason: String?
            var words: [Word]

            enum CodingKeys: String, CodingKey {
                case status, reason, words
                case cueID = "cue_id"
            }
        }

        struct Word: Decodable {
            var startByte: Int
            var endByte: Int
            var startMs: Int
            var endMs: Int

            enum CodingKeys: String, CodingKey {
                case startByte = "start_byte", endByte = "end_byte", startMs = "start_ms", endMs = "end_ms"
            }
        }

        enum CodingKeys: String, CodingKey {
            case generation, cues
            case requestID = "request_id", sourceRevision = "source_revision"
        }
    }

    static func answer(_ reply: Reply, to request: Request) -> Answer {
        // A window SpeechDock never read comes back with no source revision and one reason for every cue.
        guard reply.sourceRevision != nil else {
            let reason = reply.cues.first?.reason ?? "unknown"
            return Answer(outcome: reason == "alignment_busy" ? .busy : .refused(reason), words: [:])
        }
        let sent = Dictionary(request.cues.map { (String($0.ordinal), $0) }, uniquingKeysWith: { first, _ in first })
        var words: [Int: [TimeInterval]] = [:]
        for timed in reply.cues where timed.status == "aligned" {
            guard let cue = sent[timed.cueID], let starts = measured(timed.words, in: cue, offset: request.offset) else { continue }
            words[cue.ordinal] = starts
        }
        return Answer(outcome: .read, words: words)
    }

    /// When each word starts, in seconds after the cue shows. SpeechDock times every word of a cue it
    /// aligns, each by its whole UTF-8 span, punctuation included; nil unless the words are exactly the
    /// cue's, in order, without overlap and within the time the cue shows.
    private static func measured(_ words: [Reply.Word], in cue: Cue, offset: Int) -> [TimeInterval]? {
        let spans = wordSpans(cue.text)
        guard words.count == spans.count else { return nil }
        let shows = cue.start + offset, hides = cue.end + offset
        var starts: [TimeInterval] = []
        var free = max(0, shows)
        for (word, span) in zip(words, spans) {
            guard word.startByte == span.lowerBound, word.endByte == span.upperBound,
                  word.startMs >= free, word.startMs < word.endMs, word.endMs <= hides else { return nil }
            starts.append(Double(word.startMs - shows) / 1000)
            free = word.endMs
        }
        return starts
    }

    /// The UTF-8 byte range of each run of non-space characters.
    private static func wordSpans(_ text: String) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var start: Int?
        var byte = 0
        for scalar in text.unicodeScalars {
            if isSpace(scalar) {
                if let first = start { spans.append(first..<byte) }
                start = nil
            } else if start == nil {
                start = byte
            }
            byte += UTF8.width(scalar)
        }
        if let first = start { spans.append(first..<byte) }
        return spans
    }
}

/// SpeechDock's window endpoint. It reads the media for every request, so the wait is long.
public struct SpeechDockClient: Sendable {
    public let origin: URL
    private let transport: any PlexTransport

    public init(origin: URL, transport: any PlexTransport = URLSessionTransport()) {
        self.origin = origin
        self.transport = transport
    }

    /// SpeechDock's version, from its health check.
    public func health() async throws -> String {
        guard let url = PlexURL.make(base: origin, path: "/health") else { throw SpeechDock.Failure.notSpeechDock }
        let response: PlexHTTPResponse
        do {
            response = try await transport.send(PlexRequest(method: .get, url: url, headers: ["Accept": "application/json"], timeout: 10))
        } catch is NetworkFailure {
            throw SpeechDock.Failure.unreachable
        }
        struct Health: Decodable {
            var status: String
            var version: String
        }
        guard response.status == 200, let health = try? JSONDecoder().decode(Health.self, from: response.body),
              health.status == "ok", !health.version.isEmpty else { throw SpeechDock.Failure.notSpeechDock }
        return health.version
    }

    public func align(_ request: SpeechDock.Request) async throws -> SpeechDock.Answer {
        let body = try JSONEncoder().encode(request)
        // Its limit; the window's text budget keeps every request well inside it.
        guard body.count <= 32_768, let url = PlexURL.make(base: origin, path: "/api/alignment/windows") else {
            throw SpeechDock.Failure.rejected(413)
        }
        let response: PlexHTTPResponse
        do {
            response = try await transport.send(PlexRequest(
                method: .post, url: url, headers: ["Content-Type": "application/json", "Accept": "application/json"],
                body: body, timeout: 60
            ))
        } catch is NetworkFailure {
            throw SpeechDock.Failure.unreachable
        }
        guard response.status == 200 else {
            throw (400..<500).contains(response.status) ? SpeechDock.Failure.rejected(response.status) : SpeechDock.Failure.notSpeechDock
        }
        guard let reply = try? JSONDecoder().decode(SpeechDock.Reply.self, from: response.body),
              reply.requestID == request.id, reply.generation == request.generation else { throw SpeechDock.Failure.notSpeechDock }
        return SpeechDock.answer(reply, to: request)
    }
}
