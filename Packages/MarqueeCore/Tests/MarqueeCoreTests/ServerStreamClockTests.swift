import Foundation
import Testing
@testable import MarqueeCore

struct ServerStreamClockTests {
    /// Isabel's episode (2026-11-20): a copied picture asked to start at 208.7 s, whose segment listed at
    /// 200 s begins with the keyframe at 198.198 s, stamped 208.198 with Plex's 10 s base.
    @Test func originComesFromTheFirstFrameOfTheSegmentPlaybackStartsIn() async throws {
        let master = try #require(URL(string: "https://10-0-0-2.abc.plex.direct:32400/video/:/transcode/universal/start.m3u8?offset=208.7"))
        let playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-START:TIME-OFFSET=208.7\n"
            + (0..<30).map { String(format: "#EXTINF:10, nodesc\n%05d.ts\n", $0) }.joined()
        let (library, transport) = PlexLibraryTests.library { request in
            switch request.url.lastPathComponent {
            case "index.m3u8": PlexHTTPResponse(status: 200, body: Data(playlist.utf8))
            case "00020.ts": PlexHTTPResponse(status: 206, body: Self.videoPacket(pts: 208.198))
            default: PlexHTTPResponse(status: 404, body: Data())
            }
        }

        let origin = try #require(try await library.serverStreamOrigin(master: master, session: "s1", startingAt: 208.7))

        #expect(abs(origin - -1.802) < 0.001)
        let read = try #require(await transport.requests(to: "/video/:/transcode/universal/session/s1/base/00020.ts").first)
        #expect(read.headers["Range"] == "bytes=0-65535")
        #expect(await transport.requests(to: "/video/:/transcode/universal/start.m3u8").isEmpty)
    }

    /// A segment not made yet holds only Plex's table packet: no frame, no measure.
    @Test func aSegmentWithoutAFrameGivesNoOrigin() async throws {
        let master = try #require(URL(string: "https://10-0-0-2.abc.plex.direct:32400/video/:/transcode/universal/start.m3u8"))
        let (library, _) = PlexLibraryTests.library { request in
            request.url.lastPathComponent == "index.m3u8"
                ? PlexHTTPResponse(status: 200, body: Data("#EXTINF:10,\n00000.ts\n#EXTINF:10,\n00001.ts\n".utf8))
                : PlexHTTPResponse(status: 206, body: Data([0x47, 0x40, 0x00, 0x10] + [UInt8](repeating: 0xFF, count: 184)))
        }

        #expect(try await library.serverStreamOrigin(master: master, session: "s1", startingAt: 12) == nil)
    }

    /// One transport stream packet starting a video PES stamped `pts` seconds.
    static func videoPacket(pts: Double) -> Data {
        let ticks = Int64((pts * 90_000).rounded())
        var bytes: [UInt8] = [0x47, 0x41, 0x00, 0x10, 0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x80, 0x05]
        bytes += [
            UInt8(0x21 | ((ticks >> 29) & 0x0E)), UInt8((ticks >> 22) & 0xFF), UInt8(((ticks >> 14) & 0xFE) | 1),
            UInt8((ticks >> 7) & 0xFF), UInt8(((ticks << 1) & 0xFE) | 1),
        ]
        bytes += [UInt8](repeating: 0xFF, count: 188 - bytes.count)
        return Data(bytes)
    }
}
