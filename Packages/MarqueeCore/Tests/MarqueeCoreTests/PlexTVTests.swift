import Foundation
import Testing
@testable import MarqueeCore

struct PlexTVTests {
    let expiry = Date(timeIntervalSince1970: 2_000_000_000)

    func plexTV(_ transport: FakeTransport) -> PlexTV {
        PlexTV(http: PlexHTTPClient(identity: testIdentity, transport: transport, retryDelay: .zero))
    }

    @Test func signInReturnsTheTokenOnceTheCodeIsApproved() async throws {
        let transport = FakeTransport { request, earlier in
            let polls = earlier.filter { $0.url.path == "/api/v2/pins/42" }.count
            var pin: [String: Any] = ["id": 42, "code": "abcd"]
            if polls >= 2 { pin["authToken"] = "account-token" }
            return json(pin)
        }
        let tv = plexTV(transport)
        let pin = PlexPIN(id: 42, code: "abcd", expiresAt: expiry)

        let token = try await tv.waitForToken(pin, now: { Date(timeIntervalSince1970: 0) }, sleep: { _ in })

        #expect(token == "account-token")
        #expect(await transport.requests(to: "/api/v2/pins/42").count == 3)
    }

    @Test func signInStopsWhenTheCodeExpires() async throws {
        let transport = FakeTransport { request, _ in
            request.url.path.hasSuffix("/7")
                ? json(["id": 7, "code": "gone"], status: 404)
                : json(["id": 42, "code": "abcd", "expiresAt": "2033-05-18T03:33:20Z"])
        }
        let tv = plexTV(transport)

        await #expect(throws: PlexError.pinExpired) {
            try await tv.waitForToken(PlexPIN(id: 42, code: "abcd"), now: { expiry }, sleep: { _ in })
        }
        await #expect(throws: PlexError.pinExpired) {
            try await tv.waitForToken(PlexPIN(id: 7, code: "gone"), sleep: { _ in })
        }
    }

    @Test func authURLCarriesClientCodeAndProduct() throws {
        let tv = plexTV(FakeTransport { _, _ in json([String: Any]()) })
        let url = tv.authURL(for: PlexPIN(id: 1, code: "abc123"))
        let fragment = try #require(url.absoluteString.split(separator: "#", maxSplits: 1).last)
        let items = try #require(URLComponents(string: String(fragment))?.queryItems)
        let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })

        #expect(url.absoluteString.hasPrefix("https://app.plex.tv/auth#?"))
        #expect(values["clientID"] == "client-1")
        #expect(values["code"] == "abc123")
        #expect(values["context[device][product]"] == "Marquee")
    }

    @Test func homeUsersDecodeFromEitherShape() async throws {
        let user: [String: Any] = ["id": 9, "uuid": "u9", "title": "Kid", "protected": "1", "restricted": true]
        let wrappedBody = json(["users": [user]]), bareBody = json([user])
        let wrapped = plexTV(FakeTransport { _, _ in wrappedBody })
        let bare = plexTV(FakeTransport { _, _ in bareBody })

        let fromWrapped = try await wrapped.homeUsers()
        let fromBare = try await bare.homeUsers()

        #expect(fromWrapped == fromBare)
        #expect(fromWrapped.first?.isProtected == true && fromWrapped.first?.isRestricted == true)
    }

    @Test func wrongProfilePINIsReportedAsSuch() async throws {
        let transport = FakeTransport { request, _ in
            request.url.query("pin") == "1234"
                ? json(["authToken": "kid-token"], status: 201)
                : json(["errors": [["code": 1041, "message": "Invalid PIN"]]], status: 403)
        }
        let tv = plexTV(transport)
        let kid = try decode(PlexHomeUser.self, ["id": 9, "uuid": "u9", "title": "Kid", "protected": true])

        #expect(try await tv.switchHomeUser(kid, pin: "1234") == "kid-token")
        await #expect(throws: PlexError.profilePINRejected) {
            try await tv.switchHomeUser(kid, pin: "0000")
        }
        let request = try #require(await transport.requests.first)
        #expect(request.method == .post && request.url.path == "/api/v2/home/users/u9/switch")
    }
}
