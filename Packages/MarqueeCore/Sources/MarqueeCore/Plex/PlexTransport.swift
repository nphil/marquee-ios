import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends one request and returns the HTTP answer, whatever its status.
/// Throws `NetworkFailure` when no answer arrived and `CancellationError` when the task was cancelled.
public protocol PlexTransport: Sendable {
    func send(_ request: PlexRequest) async throws -> PlexHTTPResponse
}

public struct URLSessionTransport: PlexTransport {
    public let session: URLSession
    private let restricted: RestrictedSession

    public init(session: URLSession = .shared) {
        self.session = session
        self.restricted = RestrictedSession(configuration: session.configuration)
    }

    public func send(_ request: PlexRequest) async throws -> PlexHTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        if request.restrictToOrigin { urlRequest.httpShouldHandleCookies = false }
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let data: Data
            let http: HTTPURLResponse
            if request.restrictToOrigin {
                var redirects = 0
                while true {
                    let (bytes, response) = try await restricted.session.data(for: urlRequest)
                    guard let answer = response as? HTTPURLResponse else { throw NetworkFailure.other }
                    guard [301, 302, 303, 307, 308].contains(answer.statusCode),
                          let location = answer.value(forHTTPHeaderField: "Location"),
                          let current = urlRequest.url,
                          let destination = URL(string: location, relativeTo: current)?.absoluteURL,
                          OriginRedirectDelegate.sameOrigin(request.url, destination) else {
                        data = bytes
                        http = answer
                        break
                    }
                    redirects += 1
                    guard redirects <= 20 else { throw URLError(.httpTooManyRedirects) }
                    if answer.statusCode == 303 ||
                        ((answer.statusCode == 301 || answer.statusCode == 302) && urlRequest.httpMethod == "POST") {
                        urlRequest.httpMethod = "GET"
                        urlRequest.httpBody = nil
                        urlRequest.setValue(nil, forHTTPHeaderField: "Content-Type")
                        urlRequest.setValue(nil, forHTTPHeaderField: "Content-Length")
                    }
                    urlRequest.url = destination
                }
            } else {
                let (bytes, response) = try await session.data(for: urlRequest)
                guard let answer = response as? HTTPURLResponse else { throw NetworkFailure.other }
                data = bytes
                http = answer
            }
            var headers: [String: String] = [:]
            for case let (name as String, value as String) in http.allHeaderFields {
                headers[name] = value
            }
            return PlexHTTPResponse(status: http.statusCode, body: data, headers: headers)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw NetworkFailure(error.code)
        }
    }
}

private final class RestrictedSession: Sendable {
    let session: URLSession

    init(configuration: URLSessionConfiguration) {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: OriginRedirectDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }
}

/// URLSession may otherwise forward custom credential headers and POST bodies to a redirect target.
final class OriginRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let scheme = lhs.scheme?.lowercased(), let otherScheme = rhs.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"), scheme == otherScheme,
              let host = lhs.host?.lowercased(), let otherHost = rhs.host?.lowercased(), host == otherHost else {
            return false
        }
        let defaultPort = scheme == "https" ? 443 : 80
        return (lhs.port ?? defaultPort) == (rhs.port ?? defaultPort)
    }
}

extension NetworkFailure {
    init(_ code: URLError.Code) {
        switch code {
        case .timedOut: self = .timedOut
        case .networkConnectionLost: self = .connectionLost
        case .cannotConnectToHost: self = .cannotConnect
        case .cannotFindHost, .dnsLookupFailed: self = .hostNotFound
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: self = .offline
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            self = .secureConnectionFailed
        default: self = .other
        }
    }
}
