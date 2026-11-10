import Foundation
import Synchronization

/// A stand-in Plex for the UI tests. When they launch the app with `MARQUEE_FAKE_PLEX` set to a
/// fixtures folder, every request of a session set up through `install(into:)` is answered from that
/// folder and nothing reaches the network. Release builds never activate it.
///
/// Fixture rules (`UITests/FakePlex/README.md` has them with examples):
/// - `plex.tv` reads `plextv/<path>.json`, `discover.provider.plex.tv` reads `discover/<path>.json`,
///   hosts starting with `bazarr`, `seerr` or `speechdock` read their corresponding fixture folders,
///   and any other host reads `pms/<path>.json`.
///   `<path>@<name>=<value>.json` wins for a request with that query item.
/// - After a write (any method but GET) to `/a/b`, `<path>@after=a_b.json` wins over every other
///   fixture of the path; of several, the one for the latest write.
/// - A GET without a JSON fixture serves `<path>.srt` as text when that file exists.
/// - A fixture whose object has `"__status": N` is answered with status N.
/// - `hosts.json` maps a host to the machine identifier its `/identity` reports, or to null for a host
///   that cannot be reached. Unlisted hosts report `fake-server`.
/// - Lists under `MediaContainer.Metadata` honour `type`, `guid`, `unwatched`, `unwatchedLeaves`, `sort`
///   and `X-Plex-Container-Start`/`-Size`. `/hubs/search` keeps the entries whose title contains `query`.
///   Without a fixture, `firstCharacter` is counted from the `all` list beside it and `/library/all`
///   joins the `all` lists of the sections in `library/sections.json`.
/// - Images are files under the folder: `/photo/:/transcode` serves the path of its `url` item, and
///   any URL ending in an image extension serves its own path; TMDB image URLs omit `/t/p/<size>`.
/// - A PMS GET with a `.bin` fixture serves binary data and supports single byte ranges.
/// - A write, or a path with `/:/` in it or under `/actions/`, without a fixture is answered 200 `{}`.
///   A `DELETE` always is, and the title stays in the fixtures.
/// - The server root `/` reads `pms/root.json`.
/// - Every channel's tune reads `pms/livetv/tune.json`.
/// - Scene thumbnails, `/library/parts/<id>/indexes/sd`, read the BIF file `pms/library/parts/<id>/indexes/sd.bif`.
/// - SpeechDock's `POST /api/alignment/windows` times every cue of the window, its words spread evenly
///   over the time the cue shows.
/// - A fixture whose object has `"__anchor": T` has every `beginsAt` and `endsAt` in it moved by
///   `liveEvening` minus T, so the Live TV guide always airs around `liveNow`.
/// - `live.json` holds the Live TV favourites and recent channels the app starts with.
enum FakePlex {
    static let environmentKey = "MARQUEE_FAKE_PLEX"

    static let root: URL? = {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
        #else
        return nil
        #endif
    }()

    static var isActive: Bool { root != nil }

    /// Seconds every answer waits (`-marquee.uitest.latency`, in milliseconds), so a start can be timed
    /// against a server as slow as a real one.
    static let latency: TimeInterval = isActive ? UserDefaults.standard.double(forKey: "marquee.uitest.latency") / 1000 : 0

    /// 9 PM today while active: where an anchored fixture's T lands.
    static let liveEvening: Date? = isActive ? Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: Date()) : nil

    /// The time the Live TV guide is drawn at while active, so its screenshots never move.
    static var liveNow: Date? { liveEvening?.addingTimeInterval(41 * 60) }

    /// Live TV lists to start with, by name (`favourites`, `recents`), from `live.json`.
    static let liveSeeds: [String: [String]] = {
        guard let root, let data = try? Data(contentsOf: root.appending(path: "live.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }()

    /// Routes every request of sessions made from `configuration` to the fixtures while active.
    static func install(into configuration: URLSessionConfiguration) {
        #if DEBUG
        guard isActive else { return }
        configuration.protocolClasses = [FakePlexProtocol.self]
        configuration.urlCache = nil
        #endif
    }
}

#if DEBUG
final class FakePlexProtocol: URLProtocol {
    private var delay: Timer?

    override class func canInit(with request: URLRequest) -> Bool { FakePlex.isActive }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard FakePlex.latency > 0 else { return answer() }
        // A timer on this thread's run loop rather than a sleep, so requests made together wait together.
        let timer = Timer(timeInterval: FakePlex.latency, target: self, selector: #selector(answer), userInfo: nil, repeats: false)
        RunLoop.current.add(timer, forMode: .common)
        delay = timer
    }

    override func stopLoading() {
        delay?.invalidate()
        delay = nil
    }

    @objc private func answer() {
        guard let root = FakePlex.root, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch FakePlexRouter(root: root).answer(request) {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .success(let reply):
            let headers = ["Content-Type": reply.contentType, "Content-Length": String(reply.body.count)].merging(reply.headers) { _, value in value }
            guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

struct FakePlexRouter {
    struct Reply {
        var status: Int
        var body: Data
        var contentType: String
        var headers: [String: String] = [:]
    }

    let root: URL

    func answer(_ request: URLRequest) -> Result<Reply, URLError> {
        guard let url = request.url, let host = url.host() else { return .failure(URLError(.badURL)) }
        guard let machine = machineIdentifier(for: host) else { return .failure(URLError(.cannotConnectToHost)) }

        let path = url.path(percentEncoded: false)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let method = request.httpMethod ?? "GET"
        if path == "/api/alignment/windows", prefix(for: host) == "speechdock" {
            guard let reply = Self.aligned(Self.body(of: request)) else { return .success(json([String: Any](), status: 400)) }
            return .success(json(reply))
        }

        if path == "/identity" {
            return .success(json(["MediaContainer": ["size": 0, "machineIdentifier": machine] as [String: Any]]))
        }
        if path == "/photo/:/transcode" {
            return .success(image(at: query.first { $0.name == "url" }?.value ?? ""))
        }
        if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
            if host == "image.tmdb.org" {
                let components = path.split(separator: "/", omittingEmptySubsequences: true)
                guard components.count >= 4, components[0] == "t", components[1] == "p" else {
                    return .success(Reply(status: 404, body: Data(), contentType: "text/plain"))
                }
                return .success(image(at: "/" + components.dropFirst(3).joined(separator: "/")))
            }
            return .success(image(at: path))
        }
        // Scene thumbnails are a binary BIF file beside the JSON fixtures.
        if path.hasPrefix("/library/parts/"), path.hasSuffix("/indexes/sd") {
            let bif = root.appending(path: "pms" + path + ".bif")
            guard let data = try? Data(contentsOf: bif) else { return .success(json(["MediaContainer": ["size": 0]], status: 404)) }
            return .success(Reply(status: 200, body: data, contentType: "application/octet-stream"))
        }

        if method != "GET" { Self.wrote(path) }
        if path == "/:/scrobble" || path == "/:/unscrobble", let key = query.first(where: { $0.name == "key" })?.value {
            Self.watchedWrites.withLock { $0.append(WatchedWrite(key: key, watched: path == "/:/scrobble")) }
        }
        // The fixtures keep a deleted title, as a server lists one until its trash is emptied.
        if method == "DELETE" {
            return .success(json([String: Any]()))
        }
        let base = prefix(for: host) + (path == "/" ? "/root" : path)
        if method == "GET", prefix(for: host) == "pms", let data = file("\(base).bin") {
            return .success(Self.binary(data, range: request.value(forHTTPHeaderField: "Range")))
        }
        if let found = fixture(base, query: query) ?? derived(base, query: query) {
            guard var object = found as? [String: Any] else { return .success(json(found)) }
            let status = object.removeValue(forKey: "__status") as? Int ?? 200
            if let anchor = object.removeValue(forKey: "__anchor") as? Int, let evening = FakePlex.liveEvening,
               let moved = Self.shifted(object, by: Int(evening.timeIntervalSince1970) - anchor) as? [String: Any] {
                object = moved
            }
            if prefix(for: host) == "pms" { object = Self.withWatchedWrites(object) }
            if path == "/hubs/search", let text = query.first(where: { $0.name == "query" })?.value {
                object = Self.search(object, for: text, limit: query.first { $0.name == "limit" }?.value.flatMap(Int.init))
            } else {
                object = Self.list(object, query: query, paging: Paging(request, query: query))
            }
            return .success(json(object, status: status))
        }
        if method != "GET" || path.contains("/:/") || path.hasPrefix("/actions/") {
            return .success(json([String: Any]()))
        }
        if let text = file("\(base).srt") {
            return .success(Reply(status: 200, body: text, contentType: "text/plain; charset=utf-8"))
        }
        return .success(json(["MediaContainer": ["size": 0]], status: 404))
    }

    /// The paths written to so far as `a_b` for `/a/b`, latest last, each once.
    private static let writes = Mutex<[String]>([])

    private static func wrote(_ path: String) {
        let name = path.split(separator: "/").joined(separator: "_")
        writes.withLock { names in
            names.removeAll { $0 == name }
            names.append(name)
        }
    }

    // MARK: Watched state

    private struct WatchedWrite {
        let key: String
        let watched: Bool
    }

    /// What `/:/scrobble` and `/:/unscrobble` were asked, latest last.
    private static let watchedWrites = Mutex<[WatchedWrite]>([])

    /// The titles of `object` as the server would list them after those writes: a title takes the latest
    /// write for itself, its season or its show, and a title just marked watched leaves Continue Watching.
    /// The fixtures themselves never change.
    private static func withWatchedWrites(_ object: [String: Any]) -> [String: Any] {
        let writes = watchedWrites.withLock { $0 }
        guard !writes.isEmpty, var container = object["MediaContainer"] as? [String: Any] else { return object }

        func latest(_ item: [String: Any]) -> Bool? {
            let keys = ["ratingKey", "parentRatingKey", "grandparentRatingKey"].compactMap { item[$0] as? String }
            return writes.last { keys.contains($0.key) }?.watched
        }
        func applied(_ items: [[String: Any]], leavingWhenWatched: Bool) -> [[String: Any]] {
            items.compactMap { item in
                guard let watched = latest(item) else { return item }
                if watched, leavingWhenWatched { return nil }
                var item = item
                if let leaves = item["leafCount"] as? Int, leaves > 0 {
                    item["viewedLeafCount"] = watched ? leaves : 0
                } else {
                    item["viewCount"] = watched ? max(item["viewCount"] as? Int ?? 0, 1) : 0
                }
                item["viewOffset"] = nil
                return item
            }
        }
        if let items = container["Metadata"] as? [[String: Any]] {
            container["Metadata"] = applied(items, leavingWhenWatched: false)
        }
        if let hubs = container["Hub"] as? [[String: Any]] {
            container["Hub"] = hubs.map { hub in
                var hub = hub
                guard let items = hub["Metadata"] as? [[String: Any]] else { return hub }
                let kept = applied(items, leavingWhenWatched: (hub["hubIdentifier"] as? String) == "home.continue")
                hub["Metadata"] = kept
                hub["size"] = kept.count
                return hub
            }
        }
        var result = object
        result["MediaContainer"] = container
        return result
    }

    // MARK: Fixtures

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp"]

    private func prefix(for host: String) -> String {
        switch host {
        case "plex.tv": "plextv"
        case "discover.provider.plex.tv": "discover"
        case _ where host.hasPrefix("bazarr"): "bazarr"
        case _ where host.hasPrefix("seerr"): "seerr"
        case _ where host.hasPrefix("speechdock"): "speechdock"
        default: "pms"
        }
    }

    /// The identifier `/identity` reports for `host`; nil when the host cannot be reached.
    private func machineIdentifier(for host: String) -> String? {
        guard let hosts = load("hosts.json") as? [String: Any], let entry = hosts[host] else { return "fake-server" }
        return entry as? String
    }

    private func fixture(_ base: String, query: [URLQueryItem]) -> Any? {
        let after = Self.writes.withLock { $0.reversed().map { "\(base)@after=\($0).json" } }
        let variants = query.compactMap { item -> String? in
            guard let value = item.value, !value.contains("/") else { return nil }
            return "\(base)@\(item.name)=\(value).json"
        }
        for name in after + variants + ["\(base).json"] {
            if let object = load(name) { return object }
        }
        return nil
    }

    private func load(_ name: String) -> Any? {
        file(name).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    private func file(_ name: String) -> Data? {
        let relative = String(name.drop { $0 == "/" })
        return try? Data(contentsOf: root.appending(path: relative))
    }

    private func derived(_ base: String, query: [URLQueryItem]) -> Any? {
        if base == "pms/library/all" { return libraryWide() }
        if base.hasPrefix("pms/livetv/dvrs/"), base.hasSuffix("/tune") { return load("pms/livetv/tune.json") }
        guard base.hasSuffix("/firstCharacter"),
              let all = load(String(base.dropLast("firstCharacter".count)) + "all.json") as? [String: Any]
        else { return nil }
        return Self.firstCharacters(all, query: query)
    }

    /// `/library/all`: every section's list together.
    private func libraryWide() -> [String: Any]? {
        guard let sections = load("pms/library/sections.json") as? [String: Any],
              let directories = (sections["MediaContainer"] as? [String: Any])?["Directory"] as? [[String: Any]]
        else { return nil }
        let items = directories.flatMap { directory -> [[String: Any]] in
            guard let key = directory["key"] as? String,
                  let all = load("pms/library/sections/\(key)/all.json") as? [String: Any]
            else { return [] }
            return (all["MediaContainer"] as? [String: Any])?["Metadata"] as? [[String: Any]] ?? []
        }
        return ["MediaContainer": ["size": items.count, "Metadata": items] as [String: Any]]
    }

    /// The A–Z counts of a grid, from its list.
    private static func firstCharacters(_ all: [String: Any], query: [URLQueryItem]) -> [String: Any] {
        let byTitle = query.filter { $0.name != "sort" } + [URLQueryItem(name: "sort", value: "titleSort")]
        let listed = list(all, query: byTitle, paging: nil)
        let items = (listed["MediaContainer"] as? [String: Any])?["Metadata"] as? [[String: Any]] ?? []
        var counts: [(character: String, size: Int)] = []
        for item in items {
            let title = (item["titleSort"] as? String) ?? (item["title"] as? String) ?? ""
            let first = title.first.map { $0.isLetter ? String($0).uppercased() : "#" } ?? "#"
            if counts.last?.character == first { counts[counts.count - 1].size += 1 } else { counts.append((first, 1)) }
        }
        let directories = counts.map { ["key": $0.character, "title": $0.character, "size": $0.size] as [String: Any] }
        return ["MediaContainer": ["size": directories.count, "Directory": directories] as [String: Any]]
    }

    private static func binary(_ data: Data, range: String?) -> Reply {
        guard let range else { return Reply(status: 200, body: data, contentType: "application/octet-stream") }
        let parts = range.hasPrefix("bytes=") ? range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false) : []
        guard parts.count == 2, !data.isEmpty else {
            return Reply(status: 416, body: Data(), contentType: "application/octet-stream", headers: ["Content-Range": "bytes */\(data.count)"])
        }
        let start: Int
        let end: Int
        if parts[0].isEmpty, let suffix = Int(parts[1]), suffix > 0 {
            start = max(0, data.count - suffix)
            end = data.count - 1
        } else if let first = Int(parts[0]), first >= 0, first < data.count,
                  parts[1].isEmpty || Int(parts[1]).map({ $0 >= first }) == true {
            start = first
            end = min(Int(parts[1]) ?? data.count - 1, data.count - 1)
        } else {
            return Reply(status: 416, body: Data(), contentType: "application/octet-stream", headers: ["Content-Range": "bytes */\(data.count)"])
        }
        return Reply(status: 206, body: data.subdata(in: start..<(end + 1)), contentType: "application/octet-stream", headers: ["Content-Range": "bytes \(start)-\(end)/\(data.count)"])
    }

    private func image(at path: String) -> Reply {
        let local = URL(string: path).map { $0.path(percentEncoded: false) } ?? path
        let relative = String(local.drop { $0 == "/" })
        guard !relative.isEmpty, let data = try? Data(contentsOf: root.appending(path: relative)) else {
            return Reply(status: 404, body: Data(), contentType: "text/plain")
        }
        return Reply(status: 200, body: data, contentType: relative.hasSuffix(".png") ? "image/png" : "image/jpeg")
    }

    private func json(_ object: Any, status: Int = 200) -> Reply {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return Reply(status: status, body: body, contentType: "application/json")
    }

    /// SpeechDock's answer to a window: each cue's words spread evenly over the time it shows.
    private static func aligned(_ body: Data?) -> [String: Any]? {
        guard let body, let window = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let id = window["request_id"] as? String, let generation = window["generation"] as? Int,
              let cues = window["cues"] as? [[String: Any]] else { return nil }
        let timed: [[String: Any]] = cues.compactMap { cue in
            guard let cueID = cue["cue_id"] as? String, let start = cue["start_ms"] as? Int, let end = cue["end_ms"] as? Int,
                  let text = cue["text"] as? String else { return nil }
            let spans = wordSpans(text)
            let step = spans.isEmpty ? 0 : (end - start) / spans.count
            let words: [[String: Int]] = spans.enumerated().map { index, span in
                ["start_byte": span.lowerBound, "end_byte": span.upperBound, "start_ms": start + index * step, "end_ms": start + (index + 1) * step]
            }
            return ["cue_id": cueID, "status": "aligned", "words": words]
        }
        return ["request_id": id, "generation": generation, "source_revision": "fake", "cues": timed]
    }

    /// The UTF-8 byte range of each run of non-space characters.
    private static func wordSpans(_ text: String) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var start: Int?
        var byte = 0
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
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

    /// A request's body: a URL protocol sees an uploaded body as a stream.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static let timeKeys: Set<String> = ["beginsAt", "endsAt"]

    /// `value` with every `beginsAt` and `endsAt` in it moved by `delta` seconds, as numbers or strings.
    private static func shifted(_ value: Any, by delta: Int) -> Any {
        if let object = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, entry) in object {
                if timeKeys.contains(key), let seconds = entry as? Int {
                    result[key] = seconds + delta
                } else if timeKeys.contains(key), let text = entry as? String, let seconds = Int(text) {
                    result[key] = String(seconds + delta)
                } else {
                    result[key] = shifted(entry, by: delta)
                }
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { shifted($0, by: delta) }
        }
        return value
    }

    // MARK: Lists

    private struct Paging {
        var start: Int
        var size: Int

        init?(_ request: URLRequest, query: [URLQueryItem]) {
            func value(_ name: String) -> Int? {
                request.value(forHTTPHeaderField: name).flatMap { Int($0) }
                    ?? query.first { $0.name == name }?.value.flatMap { Int($0) }
            }
            guard let start = value("X-Plex-Container-Start"), let size = value("X-Plex-Container-Size") else { return nil }
            self.start = start
            self.size = size
        }
    }

    private static let typeCodes = ["1": "movie", "2": "show", "3": "season", "4": "episode", "18": "collection"]

    /// Filters, sorts and pages `MediaContainer.Metadata` the way a server does for these parameters.
    private static func list(_ object: [String: Any], query: [URLQueryItem], paging: Paging?) -> [String: Any] {
        guard var container = object["MediaContainer"] as? [String: Any],
              var items = container["Metadata"] as? [[String: Any]]
        else { return object }
        for item in query {
            guard let value = item.value else { continue }
            switch item.name {
            case "type":
                if let type = typeCodes[value] { items = items.filter { ($0["type"] as? String) == type } }
            case "guid":
                items = items.filter { ($0["guid"] as? String) == value }
            case "unwatched" where value == "1":
                items = items.filter { ($0["viewCount"] as? Int ?? 0) == 0 }
            case "unwatchedLeaves" where value == "1":
                items = items.filter { ($0["viewedLeafCount"] as? Int ?? 0) < ($0["leafCount"] as? Int ?? 0) }
            case "sort":
                items = sorted(items, by: value)
            default:
                break
            }
        }
        container["totalSize"] = items.count
        if let paging {
            let start = min(max(paging.start, 0), items.count)
            items = Array(items[start..<min(start + max(paging.size, 0), items.count)])
            container["offset"] = start
        }
        container["size"] = items.count
        container["Metadata"] = items
        var result = object
        result["MediaContainer"] = container
        return result
    }

    /// `field` or `field:desc`. Items without the field sort first, as if it were empty.
    private static func sorted(_ items: [[String: Any]], by sort: String) -> [[String: Any]] {
        let parts = sort.split(separator: ":")
        let field = String(parts.first ?? "")
        let descending = parts.dropFirst().first == "desc"
        func key(_ item: [String: Any]) -> Any? {
            field == "titleSort" ? (item["titleSort"] ?? item["title"]) : item[field]
        }
        func less(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
            guard let left = key(lhs) else { return key(rhs) != nil }
            guard let right = key(rhs) else { return false }
            if let left = left as? String, let right = right as? String {
                return left.localizedStandardCompare(right) == .orderedAscending
            }
            if let left = left as? NSNumber, let right = right as? NSNumber {
                return left.doubleValue < right.doubleValue
            }
            return false
        }
        return items.sorted { descending ? less($1, $0) : less($0, $1) }
    }

    /// Keeps the entries of each search group whose title contains `text`, and the groups left with any.
    private static func search(_ object: [String: Any], for text: String, limit: Int?) -> [String: Any] {
        guard var container = object["MediaContainer"] as? [String: Any],
              let hubs = container["Hub"] as? [[String: Any]]
        else { return object }
        func matches(_ entry: [String: Any]) -> Bool {
            ["title", "tag", "grandparentTitle"].contains { field in
                (entry[field] as? String)?.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        container["Hub"] = hubs.compactMap { hub -> [String: Any]? in
            var hub = hub
            var total = 0
            for field in ["Metadata", "Directory"] {
                guard let entries = hub[field] as? [[String: Any]] else { continue }
                let kept = Array(entries.filter(matches).prefix(limit ?? .max))
                hub[field] = kept
                total += kept.count
            }
            guard total > 0 else { return nil }
            hub["size"] = total
            return hub
        }
        return ["MediaContainer": container]
    }
}
#endif
