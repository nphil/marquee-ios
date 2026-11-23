import Foundation
import Testing
@testable import MarqueeCore

struct SeerrRemovalTests {
    @Test func removeMediaClearsSeerrsRecordOfTheTitle() async throws {
        let (client, transport) = SeerrTests.client { request, _ in
            switch (request.method, request.url.path) {
            case (_, "/api/v1/auth/plex"): SeerrTests.signedIn()
            case (.get, "/api/v1/movie/438631"): json(["id": 438_631, "mediaInfo": ["id": 42, "status": 5]])
            case (.delete, "/api/v1/media/42"): json([:], status: 204)
            default: json([:], status: 500)
            }
        }

        #expect(try await client.removeMedia(.movie, tmdbID: 438_631))

        let delete = try #require(await transport.requests(to: "/api/v1/media/42").first)
        #expect(delete.method == .delete)
        #expect(delete.restrictToOrigin)
    }

    @Test func aSeriesIsLookedUpAsTV() async throws {
        let (client, transport) = SeerrTests.client { request, _ in
            switch (request.method, request.url.path) {
            case (_, "/api/v1/auth/plex"): SeerrTests.signedIn()
            case (.get, "/api/v1/tv/90"): json(["id": 90, "mediaInfo": ["id": 7]])
            default: json([:], status: 204)
            }
        }

        #expect(try await client.removeMedia(.tv, tmdbID: 90))
        #expect(await transport.requests(to: "/api/v1/media/7").count == 1)
    }

    @Test func aTitleSeerrNeverHeldHasNothingToClear() async throws {
        let (known, knownTransport) = SeerrTests.client { request, _ in
            request.url.path == "/api/v1/auth/plex" ? SeerrTests.signedIn() : json(["id": 1])
        }
        #expect(try await known.removeMedia(.movie, tmdbID: 1) == false)
        #expect(await knownTransport.requests.filter { $0.method == .delete }.isEmpty)

        let (unknown, _) = SeerrTests.client { request, _ in
            request.url.path == "/api/v1/auth/plex" ? SeerrTests.signedIn() : json(["message": "Not found"], status: 404)
        }
        #expect(try await unknown.removeMedia(.movie, tmdbID: 2) == false)
    }

    @Test func anAccountThatMayNotManageRequestsIsRefused() async {
        let (client, _) = SeerrTests.client { request, _ in
            switch (request.method, request.url.path) {
            case (_, "/api/v1/auth/plex"): SeerrTests.signedIn()
            case (.get, _): json(["id": 3, "mediaInfo": ["id": 9]])
            default: json(["message": "You do not have permission to access this endpoint"], status: 403)
            }
        }

        await #expect(throws: SeerrError.notAllowed) { try await client.removeMedia(.movie, tmdbID: 3) }
    }
}
