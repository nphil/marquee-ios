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

    @Test func accountReadsTheSignedInUser() async throws {
        let body = json(["id": 1, "uuid": "u1", "username": "owner", "title": "Owner", "homeAdmin": true, "protected": false])
        let transport = FakeTransport { _, _ in body }

        let user = try await plexTV(transport).account()

        #expect(user.uuid == "u1" && user.title == "Owner" && user.isAdmin && !user.isProtected)
        #expect(await transport.requests(to: "/api/v2/user").count == 1)
    }

    @Test func serversIncludeSharedOnesAfterOwnAndHome() async throws {
        func server(_ id: String, owned: Bool, home: Bool) -> [String: Any] {
            ["provides": "server", "clientIdentifier": id, "owned": owned, "home": home, "connections": [[String: Any]]()]
        }
        let body = json([
            server("friend", owned: false, home: false), server("home", owned: false, home: true),
            ["provides": "player", "clientIdentifier": "phone"], server("own", owned: true, home: false),
        ])

        let servers = try await plexTV(FakeTransport { _, _ in body }).servers()

        #expect(servers.map(\.id) == ["own", "home", "friend"])
    }

    @Test func homeUserSurvivesEncoding() throws {
        let kid = try decode(PlexHomeUser.self, ["id": 9, "uuid": "u9", "title": "Kid", "thumb": "https://plex.tv/a.png", "protected": "1", "restricted": true])

        let copy = try JSONDecoder().decode(PlexHomeUser.self, from: JSONEncoder().encode(kid))

        #expect(copy == kid)
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
