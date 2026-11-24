import Foundation
import Testing

@testable import MarqueeCore

struct TunerTranscodeTests {
    typealias Profile = TunerTranscode.Profile
    private let everything: (String, Int?) -> Bool = { _, _ in true }
    private let limited = Profile(name: "mobile", codec: "h264", maxHeight: 720, progressive: true)
    private let full = Profile(name: "full", codec: "hevc", maxHeight: nil, progressive: true)

    @Test func theBestProfileKeepsTheResolutionIsProgressiveAndDecodes() {
        let interlaced = Profile(name: "i", codec: "h264", maxHeight: nil, progressive: false)
        let offer = [interlaced, limited, full]
        #expect(TunerTranscode.choose(offer: offer, source: 480, canDecode: everything).0?.name == "mobile")
        // 1080 lines: only the unlimited profile keeps the picture; the interlaced one is skipped.
        #expect(TunerTranscode.choose(offer: offer, source: 1080, canDecode: everything).0?.name == "full")
        #expect(TunerTranscode.choose(offer: offer, source: nil, canDecode: everything).0?.name == "full")
        #expect(TunerTranscode.choose(offer: [limited], source: 1080, canDecode: everything).0 == nil)
        // No HEVC decoder: nothing qualifies, so the original is requested.
        #expect(TunerTranscode.choose(offer: [full], source: 1080, canDecode: { codec, _ in codec == "h264" }).0 == nil)
    }

    @Test func aTvThatPublishesNoProfilesGetsTheBuiltInRuleAndUnknownFieldsAreIgnored() {
        #expect(TunerTranscode.choose(offer: nil, source: 720, canDecode: everything).0?.name == "mobile")
        #expect(TunerTranscode.choose(offer: nil, source: 1080, canDecode: everything).1 == "hd")
        #expect(TunerTranscode.choose(offer: nil, source: nil, canDecode: everything).1 == "unknown")
        #expect(TunerTranscode.offer(in: Data(#"{"holder":null}"#.utf8)) == nil)
        let body = Data(#"{"transcode":{"enabled":true,"future":1,"profiles":[{"name":"full","codec":"HEVC","maxHeight":null,"progressive":true,"kbps":null,"x":[]},{"codec":"h264"}]}}"#.utf8)
        #expect(TunerTranscode.offer(in: body) == [full])
        #expect(TunerTranscode.offer(in: Data(#"{"transcode":{"enabled":false,"profiles":[]}}"#.utf8)) == [])
    }

    @Test func onlyALumaTunerIsAskedHeightsAreLearnedFromUnlimitedTunesAndADeclineLastsTheRun() {
        let memory = TunerTranscode()
        func decide(_ luma: Bool, _ tuner: String, _ channel: String) -> TunerTranscode.Decision {
            memory.decide(isLuma: luma, tuner: tuner, channel: channel, offer: nil, canDecode: everything)
        }
        #expect(decide(false, "tv", "2.1").reason == "not-luma")
        #expect(decide(true, "tv", "2.1").reason == "unknown")
        memory.noted(height: 480, tuner: "tv", channel: "2.1")
        let sd = decide(true, "tv", "2.1")
        #expect(sd.asked && sd.source == 480)
        memory.noted(height: 720, tuner: "tv", channel: "2.1")  // a limited tune's pictures say nothing about the source
        #expect(decide(true, "tv", "2.1").source == 480)
        _ = decide(true, "tv", "7.1")
        memory.noted(height: 1080, tuner: "tv", channel: "7.1")
        #expect(decide(true, "tv", "7.1").reason == "hd")
        memory.decline(tuner: "tv")
        #expect(decide(true, "tv", "2.1").reason == "declined")
        #expect(decide(true, "other", "2.1").reason == "unknown")
    }

    @Test func retriesOnceOnARefusalOrNoPictureButNotOnASharingRefusal() {
        let retries = TunerTranscode.retriesWithoutTranscode
        #expect(retries(true, 400, false, false) && retries(true, 503, false, false) && retries(true, nil, true, false))
        #expect(!retries(true, 503, false, true) && !retries(true, 403, false, false) && !retries(false, 503, true, false))
    }

    @Test func addsTheProfileToTheDeviceQuery() throws {
        let url = try #require(URL(string: "http://tv:5004/auto/v2.1?device=Nitin%27s%20iPhone"))
        #expect(TunerTranscode.asking(url, limited).absoluteString == "http://tv:5004/auto/v2.1?device=Nitin%27s%20iPhone&transcode=mobile")
    }
}
