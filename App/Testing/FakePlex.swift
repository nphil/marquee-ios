import Foundation

/// A stand-in Plex for the UI tests. When they launch the app with `MARQUEE_FAKE_PLEX` set to a
/// fixtures folder, every request of a session set up through `install(into:)` is answered from that
/// folder and nothing reaches the network. Release builds never activate it.
///
/// Fixture rules (`UITests/FakePlex/README.md` has them with examples):
/// - `plex.tv` reads `plextv/<path>.json`, `discover.provider.plex.tv` reads `discover/<path>.json`,
///   any other host `pms/<path>.json`. `<path>@<name>=<value>.json` wins for a request with that query item.
/// - A fixture whose object has `"__status": N` is answered with status N.
/// - `hosts.json` maps a host to the machine identifier its `/identity` reports, or to null for a host
///   that cannot be reached. Unlisted hosts report `fake-server`.
/// - Lists under `MediaContainer.Metadata` honour `type`, `guid`, `unwatched`, `unwatchedLeaves`, `sort`
///   and `X-Plex-Container-Start`/`-Size`. `/hubs/search` keeps the entries whose title contains `query`.
///   Without a fixture, `firstCharacter` is counted from the `all` list beside it and `/library/all`
///   joins the `all` lists of the sections in `library/sections.json`.
/// - Images are files under the folder: `/photo/:/transcode` serves the path of its `url` item, and
///   any URL ending in an image extension serves its own path.
/// - A write, or an action under `/:/` or `/actions/`, without a fixture is answered 200 `{}`.
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
    override class func canInit(with request: URLRequest) -> Bool { FakePlex.isActive }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let root = FakePlex.root, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch FakePlexRouter(root: root).answer(request) {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .success(let reply):
            let headers = ["Content-Type": reply.contentType, "Content-Length": String(reply.body.count)]
            guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

struct FakePlexRouter {
    struct Reply {
        var status: Int
        var body: Data
        var contentType: String
    }

    let root: URL

    func answer(_ request: URLRequest) -> Result<Reply, URLError> {
        guard let url = request.url, let host = url.host() else { return .failure(URLError(.badURL)) }
        guard let machine = machineIdentifier(for: host) else { return .failure(URLError(.cannotConnectToHost)) }

        let path = url.path(percentEncoded: false)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let method = request.httpMethod ?? "GET"

        if path == "/identity" {
            return .success(json(["MediaContainer": ["size": 0, "machineIdentifier": machine] as [String: Any]]))
        }
        if path == "/photo/:/transcode" {
            return .success(image(at: query.first { $0.name == "url" }?.value ?? ""))
        }
        if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
            return .success(image(at: path))
        }

        let base = prefix(for: host) + path
        if let found = fixture(base, query: query) ?? derived(base, query: query) {
            guard var object = found as? [String: Any] else { return .success(json(found)) }
            let status = object.removeValue(forKey: "__status") as? Int ?? 200
            if path == "/hubs/search", let text = query.first(where: { $0.name == "query" })?.value {
                object = Self.search(object, for: text, limit: query.first { $0.name == "limit" }?.value.flatMap(Int.init))
            } else {
                object = Self.list(object, query: query, paging: Paging(request, query: query))
            }
            return .success(json(object, status: status))
        }
        if method != "GET" || path.hasPrefix("/:/") || path.hasPrefix("/actions/") {
            return .success(json([String: Any]()))
        }
        return .success(json(["MediaContainer": ["size": 0]], status: 404))
    }

    // MARK: Fixtures

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp"]

    private func prefix(for host: String) -> String {
        switch host {
        case "plex.tv": "plextv"
        case "discover.provider.plex.tv": "discover"
        default: "pms"
        }
    }

    /// The identifier `/identity` reports for `host`; nil when the host cannot be reached.
    private func machineIdentifier(for host: String) -> String? {
        guard let hosts = load("hosts.json") as? [String: Any], let entry = hosts[host] else { return "fake-server" }
        return entry as? String
    }

    private func fixture(_ base: String, query: [URLQueryItem]) -> Any? {
        let variants = query.compactMap { item -> String? in
            guard let value = item.value, !value.contains("/") else { return nil }
            return "\(base)@\(item.name)=\(value).json"
        }
        for name in variants + ["\(base).json"] {
            if let object = load(name) { return object }
        }
        return nil
    }

    private func load(_ name: String) -> Any? {
        let relative = String(name.drop { $0 == "/" })
        guard let data = try? Data(contentsOf: root.appending(path: relative)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func derived(_ base: String, query: [URLQueryItem]) -> Any? {
        if base == "pms/library/all" { return libraryWide() }
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
