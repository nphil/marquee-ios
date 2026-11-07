import Foundation
import Testing
@testable import MarqueeCore

struct PlexHTTPClientTests {
    let url = URL(string: "https://plex.tv/api/v2/user")!

    @Test func readIsRetriedOnceAfterADroppedConnection() async throws {
        let transport = FakeTransport { _, earlier in
            if earlier.isEmpty { throw NetworkFailure.connectionLost }
            return json(["ok": true])
        }
        let client = PlexHTTPClient(identity: testIdentity, token: "secret", transport: transport, retryDelay: .zero)

        let response = try await client.send(PlexRequest(url: url))

        #expect(response.status == 200)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[1].headers[PlexHeader.token] == "secret")
        #expect(requests[1].headers[PlexHeader.clientIdentifier] == "client-1")
        #expect(requests[1].url.query("X-Plex-Token") == nil)
    }

    @Test func writesAndTimeoutsAreNotRetried() async throws {
        let transport = FakeTransport { request, _ in
            throw request.method == .post ? NetworkFailure.connectionLost : NetworkFailure.timedOut
        }
        let client = PlexHTTPClient(identity: testIdentity, transport: transport, retryDelay: .zero)

        await #expect(throws: PlexError.unreachable(.connectionLost)) {
            try await client.send(PlexRequest(method: .post, url: url))
        }
        await #expect(throws: PlexError.unreachable(.timedOut)) {
            try await client.send(PlexRequest(url: url))
        }
        #expect(await transport.requests.count == 2)
    }

    @Test func statusCodesBecomeTypedErrors() async throws {
        let transport = FakeTransport { request, _ in
            request.url.path.hasSuffix("401")
                ? json([String: Any](), status: 401)
                : json(["errors": [["code": 1001, "message": "Server busy"]]], status: 503)
        }
        let client = PlexHTTPClient(identity: testIdentity, transport: transport, retryDelay: .zero)

        await #expect(throws: PlexError.unauthorized) {
            try await client.send(PlexRequest(url: url.appending(path: "401")))
        }
        await #expect(throws: PlexError.server(status: 503, message: "Server busy")) {
            try await client.send(PlexRequest(url: url))
        }
    }

    @Test func cancelledReadIsNotRetried() async throws {
        let transport = FakeTransport { _, _ in throw NetworkFailure.connectionLost }
        let client = PlexHTTPClient(identity: testIdentity, transport: transport, retryDelay: .seconds(30))

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.send(PlexRequest(url: url))
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.count == 1)
    }
}
