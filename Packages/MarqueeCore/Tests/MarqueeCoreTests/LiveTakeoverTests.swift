import Foundation
import Testing

@testable import MarqueeCore

struct LiveTakeoverTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_100)

    private func status(_ entries: String) -> Data {
        Data(#"{"tuners":[],"displaced":[\#(entries)]}"#.utf8)
    }

    @Test func matchesOnlyThisClientWithinTheWindow() throws {
        let recent = 1_800_000_090_000
        let body = status("""
        {"ip":"192.0.2.9","name":"NatePad","by":"Kitchen iPad","byKind":"app","at":\(recent),"channel":"2.1","channelName":"WXXX"},
        {"ip":"192.0.2.8","name":"Nitin’s iPhone","by":"","byKind":"tv","at":\(recent - 5000)},
        {"name":"Nitin’s iPhone","by":"Old","byKind":"app","at":\(recent - 70_000)}
        """)
        let hit = try #require(TunerTakeover.displacement(in: body, clientName: "Nitin’s iPhone", now: now))
        #expect(hit.byKind == .tv && hit.message == "The TV is now using its tuner.")
        let app = try #require(TunerTakeover.displacement(in: body, clientName: " NatePad ", now: now))
        #expect(app.message == "Kitchen iPad is now using the TV tuner.")
        #expect(TunerTakeover.displacement(in: body, clientName: "Other", now: now) == nil)
        #expect(TunerTakeover.displacement(in: body, clientName: "Nitin’s iPhone", now: now.addingTimeInterval(120)) == nil)
    }

    @Test func oldTVsAndOtherDocumentsAnswerNil() {
        #expect(TunerTakeover.displacement(in: Data(#"{"tuners":[]}"#.utf8), clientName: "A", now: now) == nil)
        #expect(TunerTakeover.displacement(in: Data("[{\"VctNumber\":\"2.1\"}]".utf8), clientName: "A", now: now) == nil)
    }

    @Test func namingEncodesAndCutsTheName() {
        let url = URL(string: "http://192.0.2.42:5004/auto/v2.1")!
        #expect(TunerTakeover.naming(url, as: "A+B & C").absoluteString == "http://192.0.2.42:5004/auto/v2.1?device=A%2BB%20%26%20C")
        let long = String(repeating: "x", count: 60)
        #expect(TunerTakeover.naming(url, as: long).query == "device=" + String(repeating: "x", count: 40))
    }
}
