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

    @Test func takeoverIsExplicitAndNeverShownAsErrorText() {
        let body = Data(#"{"version":1,"error":"takeover_required","takeover":"single-use","holders":[{"name":"Living room TV"}]}"#.utf8)
        func refusal(_ status: Int, _ mime: String) -> TunerRefusal {
            TunerRefusal(status: status, errorHeader: "805 All Tuners In Use", body: body, mimeType: mime)
        }
        #expect(refusal(503, "application/json").challenge?.holders == "Living room TV")
        #expect(!refusal(503, "application/json").text.contains("single-use"))
        #expect(refusal(403, "application/json").challenge == nil)
        #expect(refusal(503, "text/plain").challenge == nil)
        #expect(!refusal(503, "text/plain").text.contains("single-use"))
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
