import CryptoKit
import Foundation
import MarqueeCore

/// Measured word timing for Reveal as Spoken (DESIGN §8.7). SpeechDock times the English text file
/// showing, one window of cues ahead of the playhead at a time; the overlay takes its times over the
/// estimate cue by cue.
@MainActor
final class WordTiming {
    let identity: SpeechDock.Identity
    var origin: URL { client.origin }
    private let client: SpeechDockClient
    private let changed: @MainActor () -> Void
    /// The same for every request of one playback.
    private let playback = UUID().uuidString
    private var digest = ""
    /// The cues SpeechDock can time, once the file is read.
    private var cues: [SpeechDock.Cue] = []
    private var generation = 0
    /// The subtitle offset the measured times are for, in ms.
    private var offset = 0
    private var asked: Set<Int> = []
    /// Measured word starts, by when their cue starts on the file's clock, in ms.
    private var starts: [Int: [TimeInterval]] = [:]
    private var task: Task<Void, Never>?
    private var waitsUntil = Date.distantPast
    private var stopped = false

    init(
        client: SpeechDockClient, identity: SpeechDock.Identity, path: String, library: PlexLibrary, session: URLSession,
        changed: @escaping @MainActor () -> Void
    ) {
        self.client = client
        self.identity = identity
        self.changed = changed
        // SpeechDock reads the file from Plex itself and checks by its digest that it is the same file.
        task = Task { [weak self] in
            let data = try? await PlexFetch.data(path, library: library, session: session)
            self?.read(data)
        }
    }

    /// When each word of the cue starting at `start` (the file's clock, in seconds) starts, in seconds
    /// after the cue shows; nil until SpeechDock has timed it.
    func starts(at start: TimeInterval) -> [TimeInterval]? {
        starts[Int((start * 1000).rounded())]
    }

    /// Asks about the next window unless an answer is awaited. `due` is the file's clock and `offset` the
    /// subtitle offset, in seconds.
    func ask(due: TimeInterval, offset seconds: TimeInterval) {
        let offset = Int((seconds * 1000).rounded())
        if offset != self.offset, !cues.isEmpty {
            // Measured times count from when a cue shows, which the offset moves: earlier answers are stale.
            self.offset = offset
            generation += 1
            asked = []
            starts = [:]
            task?.cancel()
            task = nil
        }
        guard !stopped, task == nil, !cues.isEmpty, Date.now >= waitsUntil else { return }
        let window = SpeechDock.window(cues, asked: asked, due: Int((due * 1000).rounded()), offset: offset)
        guard !window.isEmpty else { return }
        let request = SpeechDock.Request(
            id: UUID().uuidString, generation: generation, playback: playback, identity: identity, digest: digest,
            offset: offset, cues: window
        )
        let client = client
        task = Task { [weak self] in
            let answer = try? await client.align(request)
            self?.receive(answer, for: request)
        }
    }

    func stop() {
        stopped = true
        task?.cancel()
        task = nil
    }

    private func read(_ data: Data?) {
        task = nil
        guard !stopped, let data, let all = SpeechDock.cues(data) else { return stop() }
        cues = SpeechDock.alignable(all)
        guard !cues.isEmpty else { return stop() }
        digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        changed()
    }

    private func receive(_ answer: SpeechDock.Answer?, for request: SpeechDock.Request) {
        guard !stopped, request.generation == generation else { return }
        task = nil
        // Unreachable, or not SpeechDock: the estimate stays for this file.
        guard let answer else { return stop() }
        switch answer.outcome {
        case .read:
            asked.formUnion(request.cues.map(\.ordinal))
            for cue in request.cues {
                if let words = answer.words[cue.ordinal] { starts[cue.start] = words }
            }
            changed()
        case .busy:
            // Its one worker and its one waiting place are taken.
            waitsUntil = .now + 2
        case .refused:
            stop()
        }
    }
}
