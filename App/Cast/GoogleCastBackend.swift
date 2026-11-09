#if canImport(GoogleCast)
import Foundation
@preconcurrency import GoogleCast
import MarqueeCore

/// Chromecasts through Google's Cast SDK, playing on the Default Media Receiver.
@MainActor
final class GoogleCastBackend: NSObject, CastBackend {
    var onEvent: ((CastEvent) -> Void)?
    private let context: GCKCastContext
    private var found: [String: GCKDevice] = [:]
    private var client: GCKRemoteMediaClient?

    override init() {
        let options = GCKCastOptions(discoveryCriteria: GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID))
        options.startDiscoveryAfterFirstTapOnCastButton = false
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        // The receiver plays on while the phone is locked, and the session is still there on return.
        options.suspendSessionsWhenBackgrounded = false
        GCKCastContext.setSharedInstanceWith(options)
        context = GCKCastContext.sharedInstance()
        super.init()
        context.discoveryManager.add(self)
        context.sessionManager.add(self)
    }

    var mediaSessionID: Int? { client?.mediaStatus?.mediaSessionID }

    func startDiscovery() {
        context.discoveryManager.startDiscovery()
        publishDevices()
    }

    func stopDiscovery() {
        context.discoveryManager.stopDiscovery()
    }

    func connect(_ device: CastDevice) {
        guard let target = found[device.id], context.sessionManager.startSession(with: target) else {
            onEvent?(.disconnected)
            return
        }
    }

    func disconnect(stopping: Bool) {
        context.sessionManager.endSessionAndStopCasting(stopping)
    }

    func load(_ load: CastLoad) {
        guard let client else { return }
        let metadata = GCKMediaMetadata(metadataType: load.isEpisode ? .tvShow : .movie)
        metadata.setString(load.title, forKey: kGCKMetadataKeyTitle)
        if let subtitle = load.subtitle { metadata.setString(subtitle, forKey: kGCKMetadataKeySubtitle) }
        if let poster = load.poster { metadata.addImage(GCKImage(url: poster, width: 480, height: 720)) }
        let media = GCKMediaInformationBuilder(contentURL: load.stream.url)
        media.contentType = load.stream.contentType
        media.streamType = .buffered
        media.streamDuration = load.duration
        media.metadata = metadata
        if load.stream.session != nil {
            // The server's HLS for a Chromecast: H.264 and AAC in MPEG-TS segments.
            media.hlsSegmentFormat = .TS
            media.hlsVideoSegmentFormat = .MPEG2_TS
        }
        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = media.build()
        request.startTime = load.startAt
        request.autoplay = NSNumber(value: load.autoplay)
        client.loadMedia(with: request.build())
    }

    func play() { client?.play() }

    func pause() { client?.pause() }

    func seek(to time: TimeInterval) {
        let options = GCKMediaSeekOptions()
        options.interval = time
        client?.seek(with: options)
    }

    private func publishDevices() {
        let manager = context.discoveryManager
        var devices: [CastDevice] = []
        found = [:]
        for index in 0..<manager.deviceCount {
            let device = manager.device(at: index)
            found[device.deviceID] = device
            devices.append(Self.device(device))
        }
        onEvent?(.devices(devices))
    }

    private func attach(_ client: GCKRemoteMediaClient?) {
        self.client?.remove(self)
        self.client = client
        client?.add(self)
    }

    private static func device(_ device: GCKDevice) -> CastDevice {
        CastDevice(id: device.deviceID, name: device.friendlyName ?? device.modelName ?? "Chromecast", model: device.modelName)
    }

    private static func player(_ status: GCKMediaStatus) -> CastStatus.Player {
        switch status.playerState {
        case .playing: return .playing
        case .paused: return .paused
        case .buffering: return .buffering
        case .loading: return .loading
        case .idle:
            switch status.idleReason {
            case .finished: return .idle(.finished)
            case .cancelled: return .idle(.cancelled)
            case .interrupted: return .idle(.interrupted)
            case .error: return .idle(.error)
            default: return .idle(.none)
            }
        default: return .unknown
        }
    }
}

extension GoogleCastBackend: @preconcurrency GCKDiscoveryManagerListener {
    func didUpdateDeviceList() {
        publishDevices()
    }
}

extension GoogleCastBackend: @preconcurrency GCKSessionManagerListener {
    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        attach(session.remoteMediaClient)
        onEvent?(.connected(Self.device(session.device)))
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: Error) {
        onEvent?(.disconnected)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        attach(nil)
        onEvent?(.disconnected)
    }
}

extension GoogleCastBackend: @preconcurrency GCKRemoteMediaClientListener {
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        guard let mediaStatus else { return }
        onEvent?(.status(CastStatus(
            mediaSessionID: mediaStatus.mediaSessionID,
            player: Self.player(mediaStatus),
            position: mediaStatus.streamPosition,
            rate: Double(mediaStatus.playbackRate)
        )))
    }
}
#endif
