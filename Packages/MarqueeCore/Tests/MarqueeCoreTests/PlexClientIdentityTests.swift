import Foundation
import Testing
@testable import MarqueeCore

struct PlexClientIdentityTests {
    @Test func clientIdentifierIsCreatedOnceAndKept() throws {
        let suite = "marquee.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = PlexClientIdentity.storedClientIdentifier(in: defaults)
        let second = PlexClientIdentity.storedClientIdentifier(in: defaults)

        #expect(UUID(uuidString: first) != nil)
        #expect(first == second)
    }

    @Test func tokenIsSentOnlyWhenPresent() {
        let identity = PlexClientIdentity(
            clientIdentifier: "id", version: "1.0", platformVersion: "27.0",
            device: "iPhone18,1", deviceName: "Phone"
        )
        #expect(identity.headers(token: "secret")[PlexHeader.token] == "secret")
        #expect(identity.headers(token: nil)[PlexHeader.token] == nil)
        #expect(identity.headers(token: "")[PlexHeader.token] == nil)
    }

    @Test func tokenIsStrippedFromURLsKeepingOtherItemsVerbatim() throws {
        let url = try #require(URL(string:
            "https://10-0-0-2.abc.plex.direct:32400/photo/:/transcode?width=300&X-Plex-Token=secret&url=%2Flibrary%2Fmetadata%2F1%2Fthumb"
        ))
        #expect(url.removingPlexToken.absoluteString ==
            "https://10-0-0-2.abc.plex.direct:32400/photo/:/transcode?width=300&url=%2Flibrary%2Fmetadata%2F1%2Fthumb")

        let onlyToken = try #require(URL(string: "https://plex.tv/api/v2/user?x-plex-token=secret"))
        #expect(onlyToken.removingPlexToken.absoluteString == "https://plex.tv/api/v2/user")
    }
}
