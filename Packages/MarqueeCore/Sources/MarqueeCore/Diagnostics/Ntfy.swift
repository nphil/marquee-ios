import Foundation

/// Where the diagnostic logs go: an ntfy server, a topic on it and, for a server that is not open to
/// everyone, an access token sent as `Authorization: Bearer`.
public struct NtfyConfig: Sendable, Hashable {
    public var server: URL
    public var topic: String
    public var token: String?

    public init(server: URL, topic: String, token: String?) {
        self.server = server
        self.topic = topic
        self.token = token
    }

    public enum Problem: Error, Sendable, Equatable {
        /// Neither https:// nor http://.
        case scheme
        case host
        /// Plain http:// to a host outside the home network.
        case plaintext
        /// ntfy topics are 1 to 64 letters, digits, `-` and `_`.
        case topic
        case token
    }

    /// Checks what was typed into the settings page. The server keeps any base path; an empty token is
    /// allowed, for a server open to everyone.
    public static func parse(server text: String, topic: String, token: String) -> Result<NtfyConfig, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return .failure(.scheme) }
        guard let host = components.host, !host.isEmpty, !host.contains(" "), components.user == nil,
              components.query == nil, components.fragment == nil, var url = components.url else { return .failure(.host) }
        if scheme == "http", !HomeNetwork.contains(host) { return .failure(.plaintext) }
        while url.absoluteString.hasSuffix("/"), let shorter = URL(string: String(url.absoluteString.dropLast())) { url = shorter }
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(topic.count), topic.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return .failure(.topic)
        }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count <= 512, token.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }) else { return .failure(.token) }
        return .success(NtfyConfig(server: url, topic: topic, token: token.isEmpty ? nil : token))
    }

    /// `https://ntfy.example/topic`.
    public var topicURL: URL {
        endpoint(path: "/" + topic)
    }

    /// Recent messages as JSON lines, for reading the logs back.
    public func pollURL(since: String = "12h") -> URL {
        endpoint(path: "/\(topic)/json", query: [URLQueryItem(name: "poll", value: "1"), URLQueryItem(name: "since", value: since)])
    }

    /// Query values are encoded strictly, so a `+` or `&` in a note survives ntfy's form decoding.
    private func endpoint(path: String, query: [URLQueryItem] = []) -> URL {
        PlexURL.make(base: server, path: path, query: query) ?? server
    }

    /// A text message, or with `attachment` a file the message carries. The title, file name and an
    /// attachment's message text go in the query, where ntfy reads UTF-8 that headers cannot carry.
    public func publish(_ message: NtfyMessage) -> PlexRequest {
        var query: [URLQueryItem] = []
        if let title = message.title { query.append(URLQueryItem(name: "title", value: title)) }
        var headers: [String: String] = [:]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let priority = message.priority { headers["Priority"] = String(priority.rawValue) }
        if !message.tags.isEmpty { headers["Tags"] = message.tags.joined(separator: ",") }
        let body: Data
        let method: HTTPMethod
        if let attachment = message.attachment {
            method = .put
            body = attachment.data
            query.append(URLQueryItem(name: "filename", value: attachment.filename))
            if !message.text.isEmpty { query.append(URLQueryItem(name: "message", value: message.text)) }
            headers["Content-Type"] = attachment.contentType
        } else {
            method = .post
            body = Data(message.text.utf8)
            headers["Content-Type"] = "text/plain; charset=utf-8"
        }
        let url = endpoint(path: "/" + topic, query: query)
        return PlexRequest(method: method, url: url, headers: headers, body: body,
                           timeout: message.attachment == nil ? 20 : 120, isIdempotent: false)
    }
}

/// ntfy's priorities; the live log goes at `min` so it never sounds, and problems louder.
public enum NtfyPriority: Int, Sendable {
    case min = 1, low, normal, high, urgent

    /// Ordinary batches stay silent; a warning is a normal notification, an error a high one.
    public static func `for`(_ level: DiagLevel) -> NtfyPriority {
        switch level {
        case .debug, .info, .notice: .min
        case .warning: .normal
        case .error: .high
        }
    }

    /// ntfy tags shown as emoji beside the title.
    public static func tags(for level: DiagLevel) -> [String] {
        switch level {
        case .debug, .info, .notice: []
        case .warning: ["warning"]
        case .error: ["rotating_light"]
        }
    }
}

public struct NtfyMessage: Sendable {
    public struct Attachment: Sendable {
        public var data: Data
        public var filename: String
        public var contentType: String

        public init(data: Data, filename: String, contentType: String) {
            self.data = data
            self.filename = filename
            self.contentType = contentType
        }
    }

    public var title: String?
    public var text: String
    public var priority: NtfyPriority?
    public var tags: [String]
    public var attachment: Attachment?

    public init(title: String?, text: String, priority: NtfyPriority? = nil, tags: [String] = [], attachment: Attachment? = nil) {
        self.title = title
        self.text = text
        self.priority = priority
        self.tags = tags
        self.attachment = attachment
    }
}

/// What an ntfy server's answer means for the sender and for the settings page.
public enum NtfyAnswer: Sendable, Equatable {
    case accepted
    /// 401: the server wants an access token.
    case needsToken
    /// 403: the token may not write to this topic.
    case refused
    /// 413, or a 400 about attachments: the server takes no attachment this large, or none at all.
    case attachmentRefused
    /// 429.
    case rateLimited
    case serverError(Int)
    case unexpected(Int)

    public init(status: Int, body: Data) {
        switch status {
        case 200..<300: self = .accepted
        case 401: self = .needsToken
        case 403: self = .refused
        case 413: self = .attachmentRefused
        case 400 where String(decoding: body, as: UTF8.self).lowercased().contains("attachment"): self = .attachmentRefused
        case 429: self = .rateLimited
        case 500..<600: self = .serverError(status)
        default: self = .unexpected(status)
        }
    }

    /// Worth sending again later: the server was busy or failing, not refusing.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .serverError: true
        default: false
        }
    }
}

extension NtfyConfig {
    /// The file name a report's journal is uploaded under: `marquee-isabels-iphone-20261112-094103.log`.
    public static func reportFilename(device: String, at date: Date, ext: String = "log", calendar: Calendar = .current) -> String {
        let slug = device.lowercased().unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)) ? Character(scalar) : "-"
        }
        var name = String(slug).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        if name.isEmpty { name = "iphone" }
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d%02d%02d-%02d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                           parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        return "marquee-\(name)-\(stamp).\(ext)"
    }
}
