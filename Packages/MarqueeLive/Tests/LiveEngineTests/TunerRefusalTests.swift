import Foundation
import Testing
@testable import LiveEngine

struct TunerRefusalTests {
    @Test func busyWithLumaTunersSentence() {
        let refusal = TunerRefusal(
            status: 503, errorHeader: "805 All Tuners In Use",
            body: Data("the TV is in use: Live TV is in front\n".utf8)
        )
        #expect(refusal.code == 805)
        #expect(refusal.reason == "All Tuners In Use")
        #expect(refusal.isBusy)
        #expect(refusal.text == "the TV is in use: Live TV is in front")
    }

    @Test func protectedChannelFromAnHTMLBody() {
        let refusal = TunerRefusal(
            status: 403, errorHeader: "811 Content Protected",
            body: Data("<html><body><h1>Content Protected</h1></body></html>".utf8)
        )
        #expect(refusal.isProtected)
        #expect(!refusal.isBusy)
        #expect(refusal.text == "Content Protected")
    }

    @Test func bare503IsBusy() {
        let refusal = TunerRefusal(status: 503, errorHeader: nil, body: Data())
        #expect(refusal.isBusy)
        #expect(refusal.text == "The tuner is busy.")
    }
}
