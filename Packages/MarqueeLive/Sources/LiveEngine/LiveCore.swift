import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// Where playback of one stream is.
public enum LivePhase: String, Sendable, Equatable {
    /// Nothing on screen yet.
    case opening
    /// The tuner's slate is on screen, as a still; the clock waits for the station.
    case slate
    /// The station's first picture is on screen, as a still; motion and sound start once enough sound is buffered.
    case picture
    case playing
    /// Out of data: the clock stopped on the last picture until the buffer refills.
    case stalled
}

/// What playback reports besides its phase.
public enum LiveEvent: Sendable, Equatable {
    case phase(LivePhase)
    /// The tuner's slate stands in mid-stream (after a dropout), or the station is back.
    case slateOnScreen(Bool)
    /// The picture's size or scan changed: "720×480i".
    case shape(String)
    case underrun
    /// Playback dropped to the newest picture and restarted its clock.
    case reanchor
    /// The clock's rate changed by 0.5 % or more.
    case servo(Double)
    case audioTracks([LiveAudioTrack])
    /// The picture cannot be decoded or filtered.
    case failed(String)
}

/// One sound of the program: a second language or a description track.
public struct LiveAudioTrack: Sendable, Hashable, Identifiable {
    /// The PID.
    public var id: Int32
    public var language: String?
    public var codec: String
    public var channels: Int32
}

/// Seconds from the request to each milestone.
public struct LiveTimings: Sendable, Equatable {
    public var response: Double?
    public var firstByte: Double?
    /// The tuner's slate first on screen.
    public var slate: Double?
    /// The station's first picture on screen.
    public var picture: Double?
    /// Motion and sound started.
    public var sound: Double?

    public init() {}
}

/// Playback's state for the diagnostics line.
public struct LiveDiagnostics: Sendable, Equatable {
    public var timings = LiveTimings()
    /// "MPEG-2 720×480i bwdif".
    public var video: String?
    /// "AC-3 5.1→2.0".
    public var audio: String?
    public var jitterTarget = JitterTarget.floor
    public var buffered: Double?
    public var rate = 1.0
    /// Pictures dropped: late, corrupt, or behind a re-anchor.
    public var drops = 0
    public var underruns = 0

    public init() {}

    /// "slate 0.21 s · picture 1.62 s · sound 2.18 s · MPEG-2 720×480i bwdif · AC-3 5.1→2.0 · J 0.30 s · buf 0.33 s ·
    /// rate 1.002 · drops 0", leaving out what is not known yet.
    public var line: String {
        func s(_ value: Double) -> String { String(format: "%.2f s", value) }
        var parts: [String] = []
        if let slate = timings.slate { parts.append("slate \(s(slate))") }
        if let picture = timings.picture { parts.append("picture \(s(picture))") }
        if let sound = timings.sound { parts.append("sound \(s(sound))") }
        if let video { parts.append(video) }
        if let audio { parts.append(audio) }
        parts.append("J \(s(jitterTarget))")
        if let buffered { parts.append("buf \(s(buffered))") }
        parts.append(String(format: "rate %.3f", rate))
        parts.append("drops \(drops)")
        if underruns > 0 { parts.append("underruns \(underruns)") }
        return parts.joined(separator: " · ")
    }
}

/// The playback logic of one stream, without threads: the demux side calls `ingest`, the video side calls `step`.
/// Compressed pictures wait in a queue and are decoded about 0.15 s ahead of the clock; sound is decoded as it comes.
/// The first picture, and the station's first picture after the tuner's slate, go on screen at once as stills;
/// the clock starts from that picture when sound reaches it plus the jitter target.
final class LiveCore: @unchecked Sendable {
    /// How far ahead of the clock pictures are decoded.
    static let lead = 0.15
    /// The most compressed picture that waits; more means the clock fell far behind.
    static let queueLimit = 6.0
    /// No sound packet this long after the first picture, or since the last one, and the clock runs on pictures alone.
    /// LumaTuner's slate sends its first silence with its first picture (within 5 ms on 10 channels, 2026-11-07).
    static let silentStart = 1.0

    private enum AudioMode { case unknown, slate, station }

    private enum Role { case normal, stationStart }

    private struct Queued {
        let packet: Packet
        let pts: Double?
        let dts: Double?
        let key: Bool
        let role: Role
        /// The stream's parameters when they differ from the previous picture's: a new decoder.
        var parameters: CodecParameters?
    }

    let output: any LiveOutput
    let options: VideoOptions
    private let onEvent: @Sendable (LiveEvent) -> Void
    private let startedAt: Double

    // Shared by both sides. Guarded by `lock`.
    private let lock = NSLock()
    private var queue: [Queued] = []
    private var phase = LivePhase.opening
    /// The time the clock starts from; sound before it is dropped.
    private var anchor: Double?
    private var audioEnd: Double?
    /// The first and last decode time of the pictures that came since the last sound, for telling sound that stopped
    /// from data that stopped.
    private var picturesSinceSound: (first: Double, last: Double)?
    private var audioMode = AudioMode.unknown
    private var stationKeyPending = false
    private var newestVideo: Double?
    private var lastVideoDTS: Double?
    /// The stream's clock jumped: the video side starts again from the next intra picture.
    private var timelineJump = false
    /// When the selected sound's last packet came.
    private var audioPacketAt: Double?
    /// When the slate's silence starts and stops on the stream's clock, for what is on screen now.
    private var slateRuns: [(time: Double, slate: Bool)] = []
    private var slateOnScreen = false
    /// The first picture came before any sound: it is reported as the slate, whose silence trails its first picture,
    /// while the clock waits on it as the station's until sound tells which it is.
    private var slateAssumed = false
    private var diagnostics = LiveDiagnostics()
    /// The rate last reported by a `servo` event, so a rate that creeps in small steps is still reported.
    private var reportedRate = 1.0
    private var tracks: [LiveAudioTrack] = []
    private var videoSuspended = false

    // The video side's own.
    private var decoder: VideoDecoder?
    private var filter: VideoFilter?
    private var filterFailed: Set<VideoFilter.Chain> = []
    private var uploadDevice: VideoToolboxDevice?
    private var showNextImmediately = true
    private var needsKey = true
    private var cleanSinceStart = false
    private var skipUntil = 0.0
    private var lastControl = -Double.infinity
    private var firstPictureAt: Double?
    private var jitter = JitterTarget()
    private var servo = ClockServo()
    private var interlacedSeen = false
    private var describedVideo: (PictureShape, Bool, String)?
    /// The newest picture out of the decoder and filter since the last flush.
    private var decodedUpTo: Double?

    // The demux side's own.
    private var audioDecoder: AudioDecoder?
    private var audioStream: Int32 = -1
    private var videoStream: Int32 = -1
    private var describedChannels: Int32 = -1

    init(output: any LiveOutput, options: VideoOptions, startedAt: Double, onEvent: @escaping @Sendable (LiveEvent) -> Void) {
        self.output = output
        self.options = options
        self.startedAt = startedAt
        self.onEvent = onEvent
    }

    var snapshot: LiveDiagnostics { lock.withLock { diagnostics } }
    var currentPhase: LivePhase { lock.withLock { slateAssumed ? .slate : phase } }

    func note(response after: Double) { lock.withLock { diagnostics.timings.response = after } }
    func note(firstByte after: Double) { lock.withLock { diagnostics.timings.firstByte = after } }

    /// Background without picture-in-picture: sound goes on, pictures are dropped until the next intra picture after
    /// they are wanted again.
    func setVideoEnabled(_ enabled: Bool) { lock.withLock { videoSuspended = !enabled } }

    // MARK: - Demux side

    /// The program's sounds, in PMT order, after the demuxer found a new stream.
    func updateStreams(_ context: UnsafeMutablePointer<AVFormatContext>) {
        var found: [LiveAudioTrack] = []
        for index in 0..<Int(context.pointee.nb_streams) {
            guard let stream = context.pointee.streams[index], let parameters = stream.pointee.codecpar,
                  parameters.pointee.codec_type == AVMEDIA_TYPE_AUDIO
            else { continue }
            let language = av_dict_get(stream.pointee.metadata, "language", nil, 0).map { String(cString: $0.pointee.value) }
            found.append(LiveAudioTrack(
                id: stream.pointee.id, language: language,
                codec: String(cString: avcodec_get_name(parameters.pointee.codec_id)),
                channels: parameters.pointee.ch_layout.nb_channels
            ))
        }
        let changed = lock.withLock {
            defer { tracks = found }
            return tracks != found
        }
        if changed { onEvent(.audioTracks(found)) }
    }

    /// Takes one demuxed packet. Returns true when the video side has work now.
    @discardableResult
    func ingest(_ packet: UnsafeMutablePointer<AVPacket>, stream: UnsafeMutablePointer<AVStream>, now: Double) -> Bool {
        guard let parameters = stream.pointee.codecpar else { return false }
        switch parameters.pointee.codec_type {
        case AVMEDIA_TYPE_VIDEO: return ingestVideo(packet, stream: stream, parameters: parameters)
        case AVMEDIA_TYPE_AUDIO: return ingestAudio(packet, stream: stream, parameters: parameters, now: now)
        default: return false
        }
    }

    private func ingestVideo(
        _ packet: UnsafeMutablePointer<AVPacket>, stream: UnsafeMutablePointer<AVStream>,
        parameters: UnsafeMutablePointer<AVCodecParameters>
    ) -> Bool {
        var newParameters: CodecParameters?
        if stream.pointee.index != videoStream {
            videoStream = stream.pointee.index
            newParameters = try? CodecParameters(copying: parameters)
        }
        let base = stream.pointee.time_base
        let pts = seconds(packet.pointee.pts, base)
        var dts = seconds(packet.pointee.dts, base) ?? pts
        // Without stream info, FFmpeg's fill-in gives a stream's first MPEG-2 picture a DTS of 0 when its PES carries
        // only a PTS, as LumaTuner's slate does (2026-11-07). Reordering never puts a decode time a second off.
        if let pts, let given = dts, abs(pts - given) > 1 { dts = pts }
        let key = packet.pointee.flags & FF.packetKey != 0
        guard let owned = try? Packet() else { return false }
        av_packet_move_ref(owned.pointer, packet)
        return lock.withLock {
            var role = Role.normal
            if stationKeyPending, key {
                role = .stationStart
                stationKeyPending = false
                if phase != .playing, phase != .stalled { anchor = pts }
            }
            if anchor == nil, key, audioMode != .slate, phase == .opening || phase == .picture { anchor = pts }
            var parameters = newParameters
            if let dts, let last = lastVideoDTS, abs(dts - last) > ClockServo.reanchorError {
                // A jump in the stream's clock: what waits belongs to the old timeline. Pictures carry the clock, so
                // this is the jump's one reanchor; sound only follows them.
                let dropped = dropQueued(queue.count)
                parameters = parameters ?? dropped
                newestVideo = nil
                timelineJump = true
            }
            if let dts {
                lastVideoDTS = dts
                picturesSinceSound = (picturesSinceSound?.first ?? dts, dts)
            }
            if let pts { newestVideo = max(newestVideo ?? pts, pts) }
            queue.append(Queued(packet: owned, pts: pts, dts: dts, key: key, role: role, parameters: parameters))
            trimQueue()
            return phase == .opening || phase == .slate || anchor == nil || queue.count == 1 || timelineJump
        }
    }

    /// Keeps the queue under `queueLimit` seconds, dropping from the oldest to the next intra picture.
    private func trimQueue() {
        guard let first = queue.first?.dts, let last = queue.last?.dts, last - first > Self.queueLimit else { return }
        let next = queue.dropFirst().firstIndex { $0.key } ?? queue.count - 1
        if let parameters = dropQueued(next), queue[0].parameters == nil { queue[0].parameters = parameters }
    }

    /// Drops the oldest `count` pictures. Returns the newest decoder parameters among them, which the next picture
    /// must carry: they come only with the first picture of a stream.
    private func dropQueued(_ count: Int) -> CodecParameters? {
        let parameters = queue.prefix(count).last { $0.parameters != nil }?.parameters
        diagnostics.drops += count
        queue.removeFirst(count)
        return parameters
    }

    /// Decodes sound for the selected track, the first in the PMT. Returns true when the video side should look at
    /// the clock: sound decides when a still starts moving and when a stall ends.
    private func ingestAudio(
        _ packet: UnsafeMutablePointer<AVPacket>, stream: UnsafeMutablePointer<AVStream>,
        parameters: UnsafeMutablePointer<AVCodecParameters>, now: Double
    ) -> Bool {
        let pid = stream.pointee.id
        let selected = lock.withLock { tracks.first?.id ?? pid }
        guard pid == selected else { return false }
        if stream.pointee.index != audioStream || audioDecoder?.codecID != parameters.pointee.codec_id {
            audioDecoder = try? AudioDecoder(parameters: parameters)
            audioStream = stream.pointee.index
            describedChannels = -1
        }
        guard let audioDecoder else { return false }
        audioDecoder.noteSource(parameters)
        let description = audioDecoder.sourceChannels == describedChannels ? nil : describeAudio(audioDecoder)
        describedChannels = audioDecoder.sourceChannels
        let base = stream.pointee.time_base
        let silence = SlateSilence.matches(packet)
        let pts = seconds(packet.pointee.pts, base)
        var events: [LiveEvent] = []
        let accepting: Double? = lock.withLock {
            if let description { diagnostics.audio = description }
            // Sound off the pictures' clock is from before a jump in it, or ahead of one the pictures have not made
            // yet (a demuxer holds a picture until the next starts, so sound can show a jump first): it has no place
            // on the clock. Not counting it as sound lets a picture start without it.
            if let pts, let clock = lastVideoDTS, abs(pts - clock) > ClockServo.reanchorError { return nil }
            audioPacketAt = now
            switch (audioMode, silence) {
            case (.slate, false):
                audioMode = .station
                stationKeyPending = true
                if let pts { slateRuns.append((pts, false)) }
            case (.unknown, false):
                audioMode = .station
                confirmStation(events: &events)
            case (.unknown, true), (.station, true):
                audioMode = .slate
                if let pts { slateRuns.append((pts, true)) }
                if phase == .opening || phase == .picture {
                    // What looked like the station's first picture was the slate.
                    anchor = nil
                    if phase == .picture {
                        phase = .slate
                        if slateAssumed {
                            slateAssumed = false
                        } else {
                            diagnostics.timings.slate = diagnostics.timings.picture
                            diagnostics.timings.picture = nil
                            events.append(.phase(.slate))
                        }
                    }
                }
            default:
                break
            }
            let playing = phase == .playing || phase == .stalled
            guard let anchor, playing || !silence else { return nil }
            return anchor
        }
        events.forEach(onEvent)
        guard let anchor = accepting else { return false }
        audioDecoder.decode(packet) { samples, start in
            guard let start else { return }
            let time = Double(start) * base.seconds
            let end = time + Double(samples.count / 2) / Double(AudioDecoder.sampleRate)
            guard end > anchor else { return }
            output.enqueueAudio(samples, time: time)
            lock.withLock {
                audioEnd = max(audioEnd ?? end, end)
                picturesSinceSound = nil
            }
        }
        return lock.withLock { phase == .picture || phase == .stalled }
    }

    private func describeAudio(_ decoder: AudioDecoder) -> String {
        let names = [AV_CODEC_ID_AC3: "AC-3", AV_CODEC_ID_EAC3: "E-AC-3", AV_CODEC_ID_AAC: "AAC", AV_CODEC_ID_MP2: "MP2"]
        let name = names[decoder.codecID] ?? decoder.name
        let layout = switch decoder.sourceChannels {
        case 6: "5.1"
        case 8: "7.1"
        default: "\(decoder.sourceChannels).0"
        }
        return decoder.sourceChannels == 2 || decoder.sourceChannels == 0 ? "\(name) 2.0" : "\(name) \(layout)→2.0"
    }

    // MARK: - Video side

    /// Decodes what is due and steers the clock. Returns how long the video side may wait before the next step.
    func step(now: Double) -> Double {
        var events: [LiveEvent] = []
        if lock.withLock({ timelineJump && phase != .opening && phase != .slate }) {
            lock.withLock { reanchor(events: &events) }
        }
        let clock = output.time
        let horizon: Double? = lock.withLock {
            timelineJump = false
            // Before the clock has a start, everything is decoded as it comes: stills go up at once.
            switch phase {
            case .opening, .slate: return nil
            case .picture: return anchor.map { $0 + Self.lead }
            case .playing, .stalled: return clock + Self.lead
            }
        }
        if let horizon {
            // Packets go in until a picture past the horizon comes out. Feeding by the packets' own times lets
            // pictures come out late behind the decoder's delay: frame threads hold one picture each, reordering
            // one or more (34.4's H.264 came out 0.2 s behind and was dropped, 2026-11-07).
            while let item = lock.withLock({ () -> Queued? in
                guard let first = queue.first,
                      (first.dts ?? -Double.infinity) <= horizon || (decodedUpTo ?? -Double.infinity) < horizon
                else { return nil }
                queue.removeFirst()
                return first
            }) {
                process(item, now: now, events: &events)
            }
        } else {
            let work: [Queued] = lock.withLock {
                defer { queue.removeAll(keepingCapacity: true) }
                return queue
            }
            for item in work { process(item, now: now, events: &events) }
        }
        control(now: now, events: &events)
        events.forEach(onEvent)
        return lock.withLock {
            // Only a running clock brings pictures due. Standing still, before the start or in a stall, the side waits
            // for sound, which wakes it as it comes.
            guard phase == .playing, let next = queue.first?.dts else { return 0.1 }
            return min(max(min(next, decodedUpTo ?? next) - Self.lead - clock, 0.002), 0.1)
        }
    }

    private func process(_ item: Queued, now: Double, events: inout [LiveEvent]) {
        if let parameters = item.parameters {
            decoder = nil
            filter = nil
            do {
                decoder = try VideoDecoder(parameters: parameters.pointer, options: options)
            } catch {
                events.append(.failed("\(error)"))
                return
            }
            needsKey = true
        }
        guard let decoder else { return }
        let (suspended, current) = lock.withLock { (videoSuspended, phase) }
        if suspended {
            needsKey = true
            return
        }
        if item.role == .stationStart, current != .playing, current != .stalled {
            // The station follows the slate: a new start from its first picture, with nothing of the slate's in the
            // decoder or the deinterlacer.
            restartPictures()
            needsKey = false
            decoder.flush()
        }
        if needsKey {
            guard item.key else { return }
            needsKey = false
            cleanSinceStart = false
            decoder.flush()
            filter = nil
            decodedUpTo = nil
        }
        decoder.skipsNonReference = now < skipUntil
        do {
            try decoder.decode(item.packet.pointer) { frame in
                try show(frame, now: now, events: &events)
            }
        } catch {
            events.append(.failed("\(error)"))
        }
    }

    /// The next picture out of the decoder goes up at once and starts the clock's wait.
    private func restartPictures() {
        filter = nil
        showNextImmediately = true
        cleanSinceStart = false
        decodedUpTo = nil
    }

    private func show(_ frame: UnsafeMutablePointer<AVFrame>, now: Double, events: inout [LiveEvent]) throws {
        if frame.pointee.flags & FF.frameCorrupt != 0, !cleanSinceStart {
            lock.withLock { diagnostics.drops += 1 }
            return
        }
        cleanSinceStart = true
        if frame.pointee.pts == FF.noPTS { frame.pointee.pts = frame.pointee.best_effort_timestamp }
        try prepareFilter(for: frame, events: &events)
        guard let filter else { return }
        try filter.filter(frame) { out in
            guard out.pointee.pts != FF.noPTS else { return }
            let time = Double(out.pointee.pts) / 90_000
            decodedUpTo = max(decodedUpTo ?? time, time)
            let key = out.pointee.flags & FF.frameKey != 0
            let current = lock.withLock { phase }
            if showNextImmediately {
                showNextImmediately = false
                output.enqueueVideo(out, time: time, immediately: true)
                firstPictureShown(at: time, now: now, events: &events)
            } else if current == .slate {
                // The slate changes only at its intra pictures (every 0.5 s); each goes up at once.
                if key { output.enqueueVideo(out, time: time, immediately: true) }
            } else if current == .playing, time < output.time - 0.02 {
                lock.withLock { diagnostics.drops += 1 }
                skipUntil = now + 1
            } else {
                output.enqueueVideo(out, time: time, immediately: false)
            }
        }
    }

    /// Builds the filter graph for the picture's shape, falling back to `bwdif` when the preferred chain fails.
    private func prepareFilter(for frame: UnsafeMutablePointer<AVFrame>, events: inout [LiveEvent]) throws {
        let shape = PictureShape(frame)
        if let filter, filter.shape.width != shape.width || filter.shape.height != shape.height {
            interlacedSeen = false
        }
        if frame.pointee.flags & FF.frameInterlaced != 0 { interlacedSeen = true }
        if filter?.shape != shape {
            filter = nil
            if options.deinterlacer == .yadifVideoToolbox, !shape.isHardware, uploadDevice == nil {
                uploadDevice = VideoToolboxDevice()
            }
            let candidates = VideoFilter.Chain.candidates(for: shape, options: options, canUpload: uploadDevice != nil)
            var lastError: (any Error)?
            for chain in candidates where !filterFailed.contains(chain) {
                do {
                    filter = try VideoFilter(
                        first: frame, frameRate: decoder?.frameRate ?? AVRational(num: 30_000, den: 1001), chain: chain,
                        framePerField: options.framePerField, device: chain == .gpuUpload ? uploadDevice?.pointer : nil
                    )
                    break
                } catch {
                    filterFailed.insert(chain)
                    lastError = error
                }
            }
            if filter == nil { throw lastError ?? LiveEngineError.unsupportedCodec("no filter for \(shape)") }
        }
        guard let filter else { return }
        if let described = describedVideo, described.0 == shape, described.1 == interlacedSeen { return }
        let names = [AV_CODEC_ID_MPEG2VIDEO: "MPEG-2", AV_CODEC_ID_H264: "H.264", AV_CODEC_ID_HEVC: "HEVC"]
        let name = decoder.map { names[$0.codecID] ?? $0.name } ?? "?"
        let scan = interlacedSeen ? "i" : "p"
        var text = "\(name) \(shape)\(scan)"
        if interlacedSeen { text += " \(filter.description)" }
        if shape.isHardware, !interlacedSeen { text += " VT" }
        describedVideo = (shape, interlacedSeen, text)
        lock.withLock { diagnostics.video = text }
        events.append(.shape("\(shape)\(scan)"))
    }

    /// The first picture of a start, a station after its slate, or a re-anchor is on screen.
    private func firstPictureShown(at time: Double, now: Double, events: inout [LiveEvent]) {
        let elapsed = now - startedAt
        firstPictureAt = now
        lock.withLock {
            if audioMode == .slate, phase == .opening {
                phase = .slate
                diagnostics.timings.slate = diagnostics.timings.slate ?? elapsed
                events.append(.phase(.slate))
                return
            }
            anchor = time
            let was = phase
            phase = .picture
            if audioMode == .unknown, !tracks.isEmpty {
                slateAssumed = true
                diagnostics.timings.slate = diagnostics.timings.slate ?? elapsed
                events.append(.phase(.slate))
            } else {
                diagnostics.timings.picture = diagnostics.timings.picture ?? elapsed
                // A re-anchor reported the phase when it stopped the clock.
                if was != .picture { events.append(.phase(.picture)) }
            }
        }
    }

    /// What was taken for the slate was the station's first picture. Called with `lock` held.
    private func confirmStation(events: inout [LiveEvent]) {
        guard slateAssumed else { return }
        slateAssumed = false
        diagnostics.timings.picture = diagnostics.timings.slate
        diagnostics.timings.slate = nil
        events.append(.phase(.picture))
    }

    // MARK: - Clock

    private func control(now: Double, events: inout [LiveEvent]) {
        let clock = output.time
        lock.withLock {
            // Sound sets the buffer's depth while there is any, since the clock runs on it. It counts as gone once a
            // second of pictures came without it: while nothing comes at all, its buffer is what runs out.
            let soundGone = audioEnd == nil || picturesSinceSound.map { $0.last - $0.first >= 1 } ?? false
            let newest = soundGone ? (newestVideo ?? audioEnd) : audioEnd
            switch phase {
            case .opening, .slate:
                break
            case .picture:
                guard let anchor else { break }
                let target = jitter.seconds
                let soundReady = (audioEnd ?? -Double.infinity) >= anchor + target
                let lastSound = max(audioPacketAt ?? -Double.infinity, firstPictureAt ?? now)
                let silent = tracks.isEmpty || now - lastSound >= Self.silentStart
                let picturesReady = (newestVideo ?? -Double.infinity) >= anchor + target
                guard soundReady || (silent && picturesReady) else { break }
                output.setRate(1, time: anchor)
                confirmStation(events: &events)
                servo.reset()
                phase = .playing
                diagnostics.rate = 1
                reportedRate = 1
                diagnostics.timings.sound = diagnostics.timings.sound ?? now - startedAt
                lastControl = now
                events.append(.phase(.playing))
            case .playing:
                guard let newest else { break }
                let buffered = newest - clock
                if buffered < 0.05 {
                    output.setRate(0, time: nil)
                    jitter.underrun(at: now)
                    servo.reset()
                    phase = .stalled
                    diagnostics.underruns += 1
                    diagnostics.rate = 0
                    events.append(.underrun)
                    events.append(.phase(.stalled))
                    break
                }
                jitter.update(at: now)
                guard now - lastControl >= 0.1 else { break }
                lastControl = now
                switch servo.update(buffered: buffered, target: jitter.seconds) {
                case .keep: break
                case .rate(let rate):
                    output.setRate(rate, time: nil)
                    // In the servo's 0.1 % steps, so the 0.5 % between 1 and its bound is not lost to rounding.
                    if (abs(rate - reportedRate) * 1000).rounded() >= 5 {
                        reportedRate = rate
                        events.append(.servo(rate))
                    }
                    diagnostics.rate = rate
                case .reanchor:
                    reanchor(events: &events)
                }
                diagnostics.buffered = servo.buffered
            case .stalled:
                guard let newest, newest - clock >= jitter.seconds else { break }
                output.setRate(1, time: nil)
                diagnostics.rate = 1
                reportedRate = 1
                phase = .playing
                lastControl = now
                events.append(.phase(.playing))
            }
            diagnostics.jitterTarget = jitter.seconds
            updateSlateOnScreen(clock: clock, events: &events)
        }
    }

    /// Drops to the newest intra picture and starts the clock again from it. Called with `lock` held.
    private func reanchor(events: inout [LiveEvent]) {
        if let newestKey = queue.lastIndex(where: { $0.key }) {
            diagnostics.drops += newestKey
            queue.removeFirst(newestKey)
            anchor = queue.first?.pts
        } else {
            anchor = nil
        }
        newestVideo = queue.compactMap(\.pts).max()
        phase = .picture
        slateAssumed = false
        audioEnd = nil
        timelineJump = false
        servo.reset()
        output.setRate(0, time: nil)
        output.flush(keepingImage: true)
        decoder?.flush()
        restartPictures()
        needsKey = true
        diagnostics.rate = 0
        events.append(.reanchor)
        events.append(.phase(.picture))
    }

    /// Whether the slate's silence is what plays now. Called with `lock` held.
    private func updateSlateOnScreen(clock: Double, events: inout [LiveEvent]) {
        guard phase == .playing || phase == .stalled else { return }
        while slateRuns.count > 1, slateRuns[1].time <= clock { slateRuns.removeFirst() }
        let onScreen = slateRuns.first.map { $0.time <= clock && $0.slate } ?? false
        guard onScreen != slateOnScreen else { return }
        slateOnScreen = onScreen
        events.append(.slateOnScreen(onScreen))
    }
}

/// An owned copy of a stream's codec parameters.
final class CodecParameters: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<AVCodecParameters>

    init(copying source: UnsafePointer<AVCodecParameters>) throws {
        guard let pointer = avcodec_parameters_alloc() else { throw LiveEngineError.outOfMemory }
        self.pointer = pointer
        guard avcodec_parameters_copy(pointer, source) >= 0 else { throw LiveEngineError.outOfMemory }
    }

    deinit {
        var freed: UnsafeMutablePointer<AVCodecParameters>? = pointer
        avcodec_parameters_free(&freed)
    }
}
