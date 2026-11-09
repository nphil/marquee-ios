import XCTest

/// Times the player's start against the fake server with every answer held 100 ms, about a real
/// server's round trip, on direct play and on a server transcode. The times come from the Start line
/// of stats for nerds; CI keeps them in `start-timing-direct.txt` and `start-timing-transcode.txt`
/// beside the screenshots. One file per test, because the two can run in different UI test shards and
/// merging the shards' screens keeps only one copy of a repeated file name.
final class PlayerStartTimingTests: XCTestCase {
    @MainActor
    func testDirectPlayStart() throws {
        try timeStarts(route: "direct", arguments: [])
    }

    @MainActor
    func testServerTranscodeStart() throws {
        try timeStarts(route: "transcode", arguments: ["-marquee.uitest.directPlay", "disabled"])
    }
}

private extension XCTestCase {
    @MainActor
    func timeStarts(route: String, arguments: [String]) throws {
        var lines: [String] = []
        for run in 1...3 {
            let app = launch(matchSystem: false, fixedMode: "dark", dark: "rose-pine", arguments: [
                "-marquee.fakeSignedIn", "YES",
                "-marquee.uitest.play", "212",
                "-marquee.uitest.paused", "YES",
                "-marquee.uitest.stats", "YES",
                "-marquee.uitest.latency", "100",
                "-marquee.uitest.frame", "art/caminandes-backdrop.jpg",
            ] + arguments, waitingFor: nil)
            let stats = element("player.stats", in: app)
            let started = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", "(?s).*playing [0-9]+.*"), object: stats)
            XCTAssertEqual(XCTWaiter().wait(for: [started], timeout: 20), .completed, "The \(route) start did not reach playing")
            let label = stats.label
            let start = try XCTUnwrap(label.range(of: "metadata [^,\n]*", options: .regularExpression), "No Start line in \(label)")
            lines.append("\(route) \(run): \(label[start])")
            app.terminate()
        }
        let report = lines.joined(separator: "\n") + "\n"
        add(XCTAttachment(string: report))
        guard let directory = ProcessInfo.processInfo.environment["SCREENS_DIR"] else { return }
        try Data(report.utf8).write(to: URL(fileURLWithPath: directory).appendingPathComponent("start-timing-\(route).txt"))
    }
}
