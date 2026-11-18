import Foundation

/// Takes secrets out of text before it is logged: Plex tokens, API keys, bearer tokens, HomeLabber's
/// `hlmq_` tokens, ntfy's `tk_` tokens, cookies and passwords. A URL keeps its scheme, host and path;
/// every query value goes.
public enum DiagRedactor {
    /// What a removed secret is replaced with.
    public static let mark = "…"

    /// Field names whose values are secrets whatever they look like.
    public static func isSecretName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return secretNames.contains(lower) || lower.hasSuffix("token") || lower.hasSuffix("password")
            || lower.hasSuffix("apikey") || lower.hasSuffix("api_key") || lower.hasSuffix("secret")
    }

    private static let secretNames: Set<String> = [
        "authorization", "cookie", "set-cookie", "x-api-key", "api-key", "passwd", "pwd", "connect.sid",
    ]

    /// Scheme, host, port and path; query names with their values removed; no user, password or fragment.
    public static func redact(url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.host != nil else {
            return redact(url.absoluteString)
        }
        return render(components)
    }

    public static func redact(_ text: String) -> String {
        guard mayHoldSecret(text) else { return text }
        var result = text
        result = replaceURLs(in: result)
        for rule in rules {
            result = rule.apply(to: result)
        }
        return result
    }

    // MARK: Private

    /// Words that come with every secret this redactor knows; text without any of them is returned as is,
    /// which keeps the cost of logging ordinary values to one scan.
    private static let triggers = ["token", "key", "auth", "bearer", "hlmq_", "tk_", "cookie", "pass", "pwd", "secret", "://", "sid"]

    private static func mayHoldSecret(_ text: String) -> Bool {
        let lower = text.lowercased()
        return triggers.contains { lower.contains($0) }
    }

    private static func render(_ components: URLComponents) -> String {
        var text = ""
        if let scheme = components.scheme { text += scheme + "://" }
        text += components.host ?? ""
        if let port = components.port { text += ":\(port)" }
        text += components.percentEncodedPath
        if let items = components.percentEncodedQueryItems, !items.isEmpty {
            text += "?" + items.map { $0.value == nil ? $0.name : $0.name + "=" + mark }.joined(separator: "&")
        }
        return text
    }

    private static let urlPattern = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>]+"#)

    private static func replaceURLs(in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = urlPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let span = Range(match.range, in: result) else { continue }
            let found = String(result[span])
            guard let components = URLComponents(string: found), components.host != nil else { continue }
            result.replaceSubrange(span, with: render(components))
        }
        return result
    }

    private struct Rule {
        let pattern: NSRegularExpression
        /// The template the match is replaced with; `$1` keeps the name before the secret.
        let template: String

        init(_ pattern: String, _ template: String) {
            self.pattern = try! NSRegularExpression(pattern: pattern)
            self.template = template
        }

        func apply(to text: String) -> String {
            pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
    }

    private static let rules: [Rule] = [
        // A cookie header runs to the end of its line.
        Rule(#"(?i)\b((?:set-)?cookie\s*[:=]\s*)[^\r\n]+"#, "$1" + mark),
        Rule(#"(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]+"#, "$1" + mark),
        Rule(#"(?i)\b(basic\s+)[A-Za-z0-9+/=]{8,}"#, "$1" + mark),
        Rule(#"(?i)\b(authorization["']?\s*[:=]\s*["']?)(?!bearer\b|basic\b)[^\s,;"'}]+"#, "$1" + mark),
        Rule(#"\bhlmq_[A-Za-z0-9_-]+"#, "hlmq_" + mark),
        Rule(#"\btk_[A-Za-z0-9]{8,}"#, "tk_" + mark),
        Rule(
            #"(?i)\b(x-plex-token|plex-token|access_token|refresh_token|authtoken|token|x-api-key|api[_-]?key|password|passwd|pwd|secret|connect\.sid)(["']?\s*[=:]\s*["']?)[^\s&,;"'}]+"#,
            "$1$2" + mark
        ),
    ]
}
