import Foundation
@testable import MarqueeCore

/// Answers requests from a closure and records them. The closure also sees the requests sent before,
/// so a script can change its answer once something happened.
actor FakeTransport: PlexTransport {
    typealias Handler = @Sendable (_ request: PlexRequest, _ earlier: [PlexRequest]) async throws -> PlexHTTPResponse

    private let handler: Handler
    private(set) var requests: [PlexRequest] = []

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: PlexRequest) async throws -> PlexHTTPResponse {
        let earlier = requests
        requests.append(request)
        return try await handler(request, earlier)
    }

    func requests(to path: String) -> [PlexRequest] {
        requests.filter { $0.url.path == path }
    }
}

/// Opened once; everyone waiting continues.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

func json(_ object: Any, status: Int = 200) -> PlexHTTPResponse {
    PlexHTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
}

func container(_ fields: [String: Any]) -> PlexHTTPResponse {
    json(["MediaContainer": fields])
}

func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}

extension URL {
    func query(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

let testIdentity = PlexClientIdentity(
    clientIdentifier: "client-1", version: "1.0", platformVersion: "27.0", device: "iPhone18,1", deviceName: "Phone"
)
