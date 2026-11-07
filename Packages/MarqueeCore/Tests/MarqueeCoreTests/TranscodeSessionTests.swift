import Foundation
import Testing
@testable import MarqueeCore

struct TranscodeSessionTests {
    @Test func ownSessionIsPickedFromTheServersListAndReadLeniently() async throws {
        let (library, _) = PlexLibraryTests.library { _ in
            container(["size": 2, "TranscodeSession": [
                ["key": "/transcode/sessions/someone-else", "speed": 0.8],
                [
                    "key": "/transcode/sessions/s-1", "speed": "2.5", "throttled": "1",
                    "videoDecision": "transcode", "audioDecision": "copy", "transcodeHwFullPipeline": true,
                ],
            ]])
        }

        let session = try #require(try await library.transcodeSession("s-1"))
        let ended = try await library.transcodeSession("s-2")

        #expect(session.speed == 2.5 && session.throttled == true)
        #expect(session.videoDecision == "transcode" && session.audioDecision == "copy")
        #expect(session.hardwareFullPipeline == true)
        #expect(ended == nil)
    }
}
