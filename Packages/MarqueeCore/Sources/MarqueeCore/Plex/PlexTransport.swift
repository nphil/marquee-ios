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

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: PlexRequest) async throws -> PlexHTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw NetworkFailure.other }
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
