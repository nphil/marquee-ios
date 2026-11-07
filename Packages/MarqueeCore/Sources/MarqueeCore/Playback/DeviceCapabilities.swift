import Foundation

/// What the phone and the app's player can play. The app fills it from hardware checks, the current
/// screen and the video engine it ships; the route decision reads nothing else.
public struct DeviceCapabilities: Sendable, Hashable {
    /// HEVC decoding.
    public var hevc: Bool
    /// 10-bit HEVC (Main 10).
    public var hevcMain10: Bool
    /// AV1 hardware decoding (A17 Pro and later).
    public var av1: Bool
    /// The current screen shows HDR. False when mirroring or connected to an SDR screen.
    public var hdrDisplay: Bool
    /// Dolby Vision profiles the player is known to show as Dolby Vision. Profile 5 has no HDR10 base
    /// layer, so without it in this set such files go to the server.
    public var dolbyVisionProfiles: Set<Int>
    /// Audio codecs the player plays as they are (Plex codec names).
    public var nativeAudioCodecs: Set<String>
    /// The on-device remux is available: it repackages a file the player cannot open (MKV, hev1 HEVC)
    /// without re-encoding the video.
    public var canRemux: Bool
    /// The remux converts audio the player cannot play (DTS, TrueHD, Opus, PCM) to AAC.
    public var remuxConvertsAudio: Bool
    /// The remux keeps Dolby Vision metadata, so profile 5 survives it.
    public var remuxKeepsDolbyVision: Bool
    /// The remux carries embedded text subtitles (SRT, ASS) as WebVTT.
    public var remuxCarriesTextSubtitles: Bool
    /// The app draws picture-based subtitles (PGS, VobSub, DVB): embedded ones decoded by the remux,
    /// separate files directly.
    public var drawsImageSubtitles: Bool

    public init(
        hevc: Bool = true,
        hevcMain10: Bool = true,
        av1: Bool = false,
        hdrDisplay: Bool = true,
        dolbyVisionProfiles: Set<Int> = [],
        nativeAudioCodecs: Set<String> = DeviceCapabilities.playerAudioCodecs,
        canRemux: Bool = false,
        remuxConvertsAudio: Bool = false,
        remuxKeepsDolbyVision: Bool = false,
        remuxCarriesTextSubtitles: Bool = false,
        drawsImageSubtitles: Bool = false
    ) {
        self.hevc = hevc
        self.hevcMain10 = hevcMain10
        self.av1 = av1
        self.hdrDisplay = hdrDisplay
        self.dolbyVisionProfiles = dolbyVisionProfiles
        self.nativeAudioCodecs = nativeAudioCodecs
        self.canRemux = canRemux
        self.remuxConvertsAudio = remuxConvertsAudio
        self.remuxKeepsDolbyVision = remuxKeepsDolbyVision
        self.remuxCarriesTextSubtitles = remuxCarriesTextSubtitles
        self.drawsImageSubtitles = drawsImageSubtitles
    }

    /// Audio AVPlayer plays from MP4 and HLS.
    public static let playerAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "alac", "mp3", "flac"]
}
