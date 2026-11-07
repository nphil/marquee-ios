# Live TV design

Status: decided. Built: L1, L2, L3 and L6, and of L5 the player gestures, channel card, Quick Guide and last channel (no PiP, Now Playing or AirPlay switch yet). The Plex path is timed against the home server (§1.3); playback on a phone is untested. Scope: the Live TV tab of Marquee for iPhone (iOS 27): guide, channel surfing, live playback and DVR. It works with any source Plex Live TV supports and is tuned first for LumaTuner, the LumaTV plugin that shares the LG TV's antenna tuner as a one-tuner HDHomeRun on port 5004.

Source key used in citations:

- **M** `marquee-ios` at 450fc94. **PB** the player branch at 7aaa2be (`/data/home/marquee-ios-player`).
- **T** `lumaglass`: `docs/plugins/live-tv-tuner.md`, `docs/research/live-tv-capture.md` (capture.md), `docs/research/tuner-slates.md`, `helper/tuner/src/*.rs`.
- **E** `stashy-videoengine` v2.0.0: `docs/ENGINE.md`, `Package.swift`, `scripts/build-ffmpeg.sh`.
- **O** observed on the home Plex Media Server 1.43.5 with GET requests on 2026-11-06, plus the server's log of a Plex for iPhone Live TV session the same day (16:43-16:48, 8 tunes). Call signs are written WXXX.
- **Spec** the OpenAPI document embedded in https://developer.plex.tv/pms/.

## Decisions

1. **One `LiveSource` protocol, two paths.** Direct: the phone reads the tuner's MPEG-TS over HTTP. Plex: the server tunes and serves HLS. Direct is the default on the home network for HDHomeRun-protocol devices; Plex covers everything else (away from home, AirPlay video, other tuner types, failures).
2. **Plex is the only guide and DVR source.** Channels, guide, recording rules and recordings come from Plex's Gracenote EPG. The tuner's own `xmltv.xml` is not used (3.59 MB, no gzip, 2.84 s to first byte; O).
3. **Direct renderer: FFmpeg into sample-buffer layers.** The engine's `FFmpeg` product demuxes and decodes into `AVSampleBufferDisplayLayer` plus `AVSampleBufferAudioRenderer` under one `AVSampleBufferRenderSynchronizer`, in a new `MarqueeLive` package. No on-phone remux to HLS.
4. **Channel change reopens the stream with a warm decoder.** The last picture stays on screen; the tuner's own slates fill the gap. The app draws no spinner over video.
5. **Measure software MPEG-2 first.** Slice L0 measures decode plus deinterlace on the oldest supported iPhone before the renderer is built out.
6. **Guide first.** The Live TV tab opens on the guide: a now/next list in portrait, a grid in landscape and at regular width. In the player, swipe left/right surfs, swipe up opens the Quick Guide, swipe down closes and frees the tuner.

## 1. Plex Live TV API

### 1.1 Endpoints

| Purpose | Request | Shape, size, time |
|---|---|---|
| DVRs, devices | `GET /livetv/dvrs` | `Dvr{key, uuid, language, lineupTitle, lineup "lineup://tv.plex.providers.epg.cloud/<id>#…", refreshedAt, epgIdentifier "tv.plex.providers.epg.cloud:5"}`, `Device[]{key, uuid "device://tv.plex.grabbers.hdhomerun/<DeviceID>", uri "http://192.168.1.242:5004", protocol livetv, status alive\|dead, state enabled, lastSeenAt, canTranscode, deviceAuth, deviceId, make, model, modelNumber, tuners "1", ChannelMapping[]{channelKey, deviceIdentifier, enabled, lineupIdentifier}, Setting transcodeProfile}`, `Dvr.Setting[9]` (minVideoQuality, replaceLowerQuality, recordPartials, startOffsetMinutes, endOffsetMinutes, postprocessingScript, comskipEnabled, comskipMethod, ButlerTaskRefreshEpgGuides). 11.2 KB, 2-8 ms (O) |
| Provider | `GET /media/providers` | `tv.plex.providers.epg.cloud:5` (protocols livetv, epgSource Gracenote). Features: grid `/grid` with 16 `GridChannelFilter` genres (`/lineups/dvr/channels?genre=…`), metadata, search `/hubs/search`, promoted `/hubs/discover?promoted=1&includeTypeFirst=1`, timeline `/:/timeline`, subscribe (flavor record). Pivots: What's On, Guide (`view://dvr/guide`), DVR Schedule, Recording Priority (O) |
| Channels | `GET /tv.plex.providers.epg.cloud:5/lineups/dvr/channels` | 53 `Channel{id (hex-hex), vcn "2.1", isHd, thumb, title, callSign, language}`. Logos on provider-static.plex.tv for 51 of 53. 15.9 KB (O) |
| Guide | `GET /tv.plex.providers.epg.cloud:5/grid?type=1,4&sort=beginsAt&endsAt>=T0&beginsAt<=T1` | Airings. 3 h: 247 items, 595 KB raw, 72.5 KB gzip, 0.13 s. 12 h: 894, 217 KB gzip, 0.40 s. 24 h: 1561, 359 KB gzip, 0.74 s (O) |
| What's On | `GET /tv.plex.providers.epg.cloud:5/hubs/discover` | Hubs: What's On Now; Shows, Sports, Movies, Kids, News On Now; New Shows On Tonight; My Upcoming Shows; Recommended; What's On Later and per-genre Later. 0.56 s (O) |
| Tune | `POST /livetv/dvrs/{dvr}/channels/{channelKey}/tune` with `X-Plex-Session-Identifier` | `MediaSubscription[{type 4, MediaGrabOperation[{rolling: true, id "<channelKey>-<session>", key "/media/grabbers/operations/<id>", status inprogress, Metadata{ratingKey, key "/livetv/sessions/<uuid>", Media[{uuid, videoCodec, Part[{key "/livetv/sessions/<uuid>/<session>/index.m3u8", Stream[codec, height, scanType…]}]}]}}]}]` (O, 2026-11-07; the Spec's bare `Metadata` answer was not seen). 21 KB to Plex for iPhone, 119 KB to Marquee; 0.97-2.03 s, median 1.39 s over 8 tunes (O) |
| Sessions | `GET /livetv/sessions`, `/livetv/sessions/{id}` | Idle: size 0, 203 B (O). `/livetv/sessions/{session}/{consumer}/index.m3u8` is what the server's transcoder reads; the consumer is the tune's `X-Plex-Session-Identifier` (the client identifier without one), and a transcode under another name gets 404 "Failed to find consumer" (Spec, O) |
| Record options | `GET /media/subscriptions/template?guid=<airing guid>` | `MediaSubscription[]`: type 4 this episode (`oneShot`), type 2 whole show (library section, location, `onlyNewAirings`, auto-deletion), type 1 movie. Each has `parameters` (`hints[…]&params[airingChannels\|airingTimes\|libraryType\|mediaProviderID]`) and `Setting[]` (minVideoQuality, replaceLowerQuality, recordPartials, start/endOffsetMinutes, lineupChannel, startTimeslot, comskip*, oneShot, remoteMedia) (O) |
| Rules | `GET /media/subscriptions?includeGrabs=1&includeStorage=1`; `POST /media/subscriptions` (targetLibrarySectionID, targetSectionLocationID, type, hints, prefs, params; 409 on conflict); `PUT`/`DELETE /media/subscriptions/{id}` | Spec; the home server has none (O) |
| Scheduled | `GET /media/subscriptions/scheduled` | `MediaGrabOperation{mediaSubscriptionID, status, Metadata}` (Spec). Cancel one airing: `DELETE /media/grabbers/operations/{id}`; not kept over a server restart (Spec) |
| Grabbers | `GET /media/grabbers`, `/media/grabbers/devices`, `/media/grabbers/operations` | Grabbers hdhomerun, tunerservice, stream, download; devices LumaTV (alive) and an older HDHomeRun (dead); operations empty when idle (O) |
| Progress | `GET /:/timeline?key=/livetv/sessions/<uuid>&ratingKey=…&state=playing\|stopped&time&duration&playbackTime&context=live-tv.guide:…&row&col&airingId` | Every 10 s (O) |

`/livetv/dvrs/{key}` answers 404 and `/livetv/epg/channelmap` 400 without further parameters (O). Spec lists 403 responses for the DVR mutations; recording is limited to users allowed to record (§1.4).

Airing fields (O): `ratingKey`, `key` (`/tv.plex.providers.epg.cloud:5/metadata/…`), `guid`, `type` (episode or movie), `title`, `grandparentTitle`, `parentIndex`, `index`, `year`, `summary`, `thumb`, `art`, `grandparentThumb`, `contentRating`, `duration`, `originallyAvailableAt`, `onAir`, `Genre[]`, `Channel[]{id, filter "channel=N", tag}`, `Media[]{id, beginsAt, endsAt, onAir, premiere, audioChannels, videoResolution "480"|"720", channelID, channelIdentifier, channelVcn, channelCallSign, channelTitle "2.1 WXXX (NET)", channelThumb, gridKey, protocol livetv}`. In a 1 h window 83 airings were 480 and 33 were 720 (O).

Grid behaviour (O): `X-Plex-Container-Start/Size` paging works but cuts by airing, about 4 channels per page, so it cannot load row by row. `channelGridKey=` is ignored. `channel=<Media.channelID>` filters (comma-separated means any of; a repeated parameter keeps only the last). Items include simulcast channels that the device does not map; the app keeps only airings whose `channelIdentifier` is an enabled `ChannelMapping.channelKey`.

### 1.2 Identifiers

Checked on all 53 channels (O):

- `Channel.id` = `gridKey` = `ChannelMapping.channelKey` = grid `Media.channelIdentifier` (hex-hex). This is `{channelKey}` in tune.
- `Channel.vcn` = `ChannelMapping.deviceIdentifier` = `Media.channelVcn` = the tuner's `GuideNumber` ("2.1"). This joins Plex to the tuner: the direct URL is `Device.uri + "/auto/v" + vcn`.
- `Media.channelID` (integer) = `Channel[].id`, used only by the grid's `channel=` filter.
- A channel is shown when its `ChannelMapping.enabled` is "1".

### 1.3 How Plex for iPhone plays live (O)

1. `POST …/tune` with the channelKey: 0.97-2.03 s, median 1.39 s.
2. `GET /video/:/transcode/universal/decision?…&directPlay=0&directStream=0&directStreamAudio=1&protocol=hls&fastSeek=1&path=/livetv/sessions/<uuid>&mediaIndex=0&partIndex=0&mediaBufferSize=50000&hasMDE=1&location=lan` 28 ms later, then `start.m3u8` 100 ms after that.
3. The server reads its own `/livetv/sessions/<uuid>/<consumer>/index.m3u8` and `.ts` over loopback and transcodes MPEG-2 to H.264; one HLS segment a second (T capture.md:109).
4. Timeline every 10 s, `state=playing`, `context=live-tv.guide:dvrGuide:all-channels`, `row`, `col`, `airingId`; `ratingKey` is new for every tune.
5. Channel change: a `state=stopped` timeline, then the next tune in the same second. No transcode stop call.

Timing: tune to the first `playing` timeline 2.3-3.4 s (median 2.95 s); `stopped` to the next `playing` 2.9-3.1 s. T capture.md:111 measured tune to first HLS segment at 3.3-4.3 s.

Marquee's own path on 2.1 (720p60 MPEG-2, AC-3 stereo; 2026-11-07, O): tune 0.77-0.88 s, decision 5-7 ms, `start.m3u8` 3-4 ms, then the variant playlist and the first 1 s segment (475 KB) 3.16 s after the tune; the server encodes with `h264_vaapi` at 1280×720. With the transcode reading, the `stopped` timeline emptied `/livetv/sessions` 1.02 s later and the transcode stop answered 404. A grab nobody reads (the transcode never started) kept the tuner through a `stopped` timeline on a 300 s timer; `DELETE /media/grabbers/operations/<id>` emptied the sessions in 0.51 s. Marquee cancels the grab on every stop.

### 1.4 Plex limits that shape the design

- MPEG-2 is always transcoded because AVPlayer has no MPEG-2 decoder, which sets Plex's floor of about 3 s to picture.
- Plex Live TV has no closed captions or alternate audio, cannot record a programme that is being watched on a single tuner, needs Plex Pass to record, and does not let Home members schedule recordings (https://support.plex.tv/articles/115007689648-watching-live-tv/).
- Plex and a phone reading directly compete for LumaTuner's one tuner (§2.3).

## 2. Two paths

### 2.1 Comparison

| | Direct | Plex |
|---|---|---|
| Who tunes | Phone, `GET <uri>/auto/v<vcn>` | Server, `POST …/tune` |
| On the wire | MPEG-TS over HTTP/1.0, no length, `Connection: close` (T server.rs:249, 309); about 19.4 Mb/s for HD (T capture.md:103) | HLS, H.264 transcode (MPEG-2) or direct stream (H.264) |
| First picture on LumaTuner | Tuner slate at once (T live-tv-tuner.md:22); station picture as fast as the tuner delivers (first byte median 1.81 s, 0.93-4.27 s over 59 channels, T capture.md:111) | 2.3-3.4 s, median 2.95 s (O) |
| Channel change | Same-client takeover (T stream.rs:409) plus the TV's retune (0.30-0.35 s, T webos.rs:34-36) | 2.9-3.1 s (O) |
| Captions, extra audio | Yes (EIA-608 in the MPEG-2 picture user data; every audio PID) | No (Plex support article above) |
| Away from home | No | Yes |
| AirPlay video | No [INFERENCE: sample-buffer layers send audio only; the engine's loopback is unreachable from an AirPlay receiver, E ENGINE.md:228] | Yes |
| Cost | Phone CPU: software MPEG-2 decode and deinterlace | Server transcode; phone decodes H.264 in hardware |

### 2.2 Choice rule

`LiveRouteDecider` runs before every tune. First match wins:

1. Settings › Live TV › Playback is "Through Plex" → Plex.
2. The phone is not on the home network (`NetworkPath`), or `GET <uri>/discover.json` fails within 0.5 s (cached 60 s) → Plex.
3. The device's grabber is not HDHomeRun (`Device.uuid` does not start with `device://tv.plex.grabbers.hdhomerun/`) → Plex. Real HDHomeRuns, LumaTuner and the HDHomeRun-emulating IPTV proxies (xTeVe, Threadfin and similar) all pass.
4. AirPlay video is the chosen output → Plex.
5. The lineup says a codec the phone cannot decode (`VideoCodec` not MPEG2/H264/HEVC, or `AudioCodec` not AC3/EAC3/AAC/MPEG) → Plex. LumaTuner sends no codec fields today (T docs.rs:103-111; R3), so absence means "try direct".
6. The lineup marks the channel `DRM=1` → show "Protected channel" (neither path can play it) [INFERENCE for Plex].
7. A Plex recording uses this device now, or starts on it within 2 min and the device has fewer tuners than recordings plus one → Plex.
8. Otherwise → Direct. If Direct fails before the first picture with a network error, no data for 5 s, or a stream the phone cannot decode, the app retries once through Plex and says so in the status line. Tuner refusals do not fall back (§2.3).

### 2.3 One-tuner rules (LumaTuner)

- A new request from the same client replaces that client's stream; another client's running stream keeps the tuner, so the newcomer is refused (T stream.rs:405-409, live-tv-tuner.md:62-66). The phone and the Plex server are different clients, so they cannot share it.
- Every request tunes the TV (T stream.rs:716). The app opens no stream while browsing; there is no pre-buffering of the next channel.
- A request waits up to `release` = 5 s for a stream it took over, or one that has ended, to let go of the TV (T stream.rs:256-257, 298).
- **Recording guard.** While playing direct, the app reads `/media/subscriptions/scheduled` on start and every 60 s. If a Plex recording on the same device starts within 60 s, a banner says "Recording on 7.1 starts in 1 min"; at 5 s before the start (after the DVR's `startOffsetMinutes`) the phone closes its stream and, if the recording is the channel being watched, continues through Plex. Without this, the recording would be refused while the phone holds the tuner.
- **Refusals** come as an `X-HDHomeRun-Error` header with a sentence in the body (T server.rs:221-230; codes in live-tv-tuner.md:24-31). 805 means the TV is busy, e.g. "the TV is in use: Live TV is in front" (T server.rs:528-530). The app shows the tuner's sentence, offers Try Again, and does not try Plex, which would be refused the same way.
- **Slates are the tuner's.** The tuner sends a slate at once (T live-tv-tuner.md:22, 35-53), holds it up to `shape_wait` = 4 s for a channel whose picture shape it has never seen (T stream.rs:264-268), says "weak signal" after 8 s, stands in after a 1.5 s dropout, and ends a stream with a last slate (no signal, TV using its tuner) for 6 s (T stream.rs:263, 271, 279-280, 300-307). The app renders all of these as ordinary video and adds only a one-line status label. H.264 and HEVC stations get no slates (T live-tv-tuner.md:51-53); for those the last picture stays up and the status label says "Tuning 7.1".
- Streaming moves the TV's own last channel (T capture.md:115) (Q4).

### 2.4 Other tuners

- HDHomeRun hardware: same Direct path. `transcode=mobile` on EXTEND models delivers H.264, which VideoToolbox decodes (https://info.hdhomerun.com/info/http_api). More than one tuner allows keeping the previous channel open for 10 s so "last channel" is instant [INFERENCE; later, not in the slices].
- HDHomeRun-emulating IPTV proxies: Direct when the phone can reach the proxy; streams are usually H.264/AAC [INFERENCE]; HTTP redirects are followed.
- Any other grabber (for example `tv.plex.grabbers.tunerservice`): Plex path.

## 3. Renderer

### 3.1 Options

| | A: FFmpeg → sample-buffer layers | B: on-phone remux/transcode → loopback HLS → AVPlayer | C: Plex HLS → AVPlayer |
|---|---|---|---|
| First picture | First decodable frame, shown as a still | After playlist plus 1-2 segments [INFERENCE: +1.5-3 s]; MPEG-2 also needs an on-phone H.264 encode | 2.95 s median (O) |
| Latency | Jitter buffer, 0.3 s target | Segment length × 2-3 | Server segmenting + AVPlayer buffer |
| Battery | Software MPEG-2 decode (L0 measures) | Decode + encode | Hardware H.264 only |
| PiP | Sample-buffer content source, live range (https://developer.apple.com/videos/play/wwdc2021/10290/) | AVPlayerLayer | AVPlayerLayer |
| AirPlay video | No | No (E ENGINE.md:228) | Yes |
| Captions | 608 via FFmpeg | Would need WebVTT segments | None (Plex) |
| Reuse | Engine `FFmpeg` product | Engine `RemuxSession` (E ENGINE.md:41-96) | PB `VideoBackend` (PB VideoBackend.swift:17-34) |

**Choice:** A for the Direct path, C for the Plex path. B is rejected: it adds seconds to every tune and channel change, costs an encode, and still cannot AirPlay video.

The engine's `ByteRangeSource`/`HTTPRangeSource` need 206 range responses (E ENGINE.md:23-33); the tuner sends an endless 200 without length (T server.rs:309), and the engine's `DemuxInput` is internal (E AVIOBridge.swift:55-95). `MarqueeLive` therefore owns a small sequential read callback modelled on the engine's `RunControl` (E AVIOBridge.swift:6-34). The engine package requires iOS 26 (E Package.swift:12), which the app already exceeds.

### 3.2 Pipeline A

1. **Read.** `URLSession` data task into an 8 MB ring (about 3.4 s at 19.4 Mb/s). Redirects followed. No data for 5 s before the first picture is a failure (matches the tuner's own `first_picture`, T stream.rs:258-261).
2. **Demux.** `avformat` mpegts through a non-seekable `AVIOContext` reading the ring; `probesize` 32 KB, no `avformat_find_stream_info` (it waits for content that a live start does not need). Decoders open from the PMT's stream types (LumaTuner: PMT 0x100, video 0x101, audio 0x102 and up; T splice.rs). Interrupt callback tied to the session's cancel flag.
3. **Video.** MPEG-2 in software with slice threads (count set by L0); H.264 and HEVC through VideoToolbox. Decoding starts at a sequence header and intra picture; leading open-GOP pictures (T tuner-slates.md:28-29) and frames flagged corrupt are dropped.
4. **Deinterlace.** SD stations are 720×480i, HD 1280×720p59.94, the fallback slate 1080i (T tuner-slates.md:12-13, 41-43). Interlaced frames go through `bwdif` (CPU) or `hwupload` + `yadif_videotoolbox` (Metal; both are in the engine's FFmpeg build, E build-ffmpeg.sh:37-57); L0 picks one. Output 59.94 fields-as-frames for sports-grade motion unless L0 shows the cost is too high, then 29.97. The filter graph is rebuilt when the picture's size, rate or scan changes (slate to station). Frames leave as IOSurface-backed NV12 `CVPixelBuffer`s in `CMSampleBuffer`s.
5. **Audio.** AC-3 and E-AC-3 (E-AC-3 untested on the tuner, T tuner-slates.md:56-57), AAC and MPEG audio decode, then `swresample` to stereo Float32 48 kHz. The fixed output format means a station switching between 5.1 and 2.0 never flushes the renderer. Extra audio PIDs (second language, description) become an audio menu.
6. **Captions.** EIA-608 pairs from the MPEG-2 picture user data (A/53, exposed by libavcodec as frame side data) through FFmpeg's `ccaption` decoder into the player's existing `TextCue` overlay (PB PlaybackSupport.swift:45-49).
7. **Jitter buffer.** Compressed packets wait in a buffer; video decodes about 100 ms ahead of display. Target depth J starts at 0.30 s, grows ×1.5 on every underrun up to 1.5 s, and shrinks 10 % a minute without underruns back to 0.30 s. This follows SiliconDust's client rules: time-based initial buffering from the first data, a jitter buffer larger than the initial buffer, clock adjusted to the stream (https://info.hdhomerun.com/info/http_api).
8. **Start.** The first decoded picture is enqueued at once with `DisplayImmediately`, so the slate (or the station's first frame) appears as a still. In the stream the station's video leads its own presentation time by 0.46-1.0 s and audio by 0.2-0.3 s (T tuner-slates.md:28-29), so audio for the first picture arrives later than the picture. The synchronizer starts at rate 1 when buffered audio reaches the first picture's time plus J; motion and sound start together [INFERENCE: 0.5-1.0 s after the first still]. A stream with no audio within 0.5 s (slates may be silent [INFERENCE]) runs on the video clock alone.
9. **Clock.** `LiveClockServo` compares buffered seconds with J: rate 0.995-1.005 for small errors, 0.98-1.02 beyond 0.5 s, with the audio renderer's time-pitch algorithm keeping voices natural. More than 2 s off re-anchors (drop to the newest picture and restart the clock). An underrun sets rate 0, keeps the picture, and resumes at J.
10. **Channel change.** The new request goes out first (same-client takeover, T stream.rs:409); the old task is cancelled when the new response's headers arrive. Decoders are flushed, not closed; the filter graph stays if the shape matches; renderers flush while keeping the displayed image, so the old channel's last frame stays until the slate replaces it.
11. **Background.** With PiP: unchanged. Without PiP: audio continues, video packets are dropped, and decoding resumes at the next intra picture on return.

### 3.3 PiP, AirPlay, Now Playing, audio session

- **PiP:** `AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer:playbackDelegate:))`. `timeRangeForPlayback` returns an infinite range (start `-infinity`, duration `+infinity`), which tells the system the content is live (WWDC21 10290). Pause in PiP stops the stream and frees the tuner; play reopens. Skip requests are ignored. PiP starts automatically on leaving the app (as in Channels, https://getchannels.com/releases/). PB builds PiP from an `AVPlayerLayer` only (PB PlayerSurface.swift:39-61) and needs a sample-buffer variant.
- **AirPlay:** audio follows the system route. Choosing an AirPlay video receiver from the route picker switches the session to the Plex path (`allowsExternalPlayback`), one Plex tune of about 3 s.
- **Now Playing:** set by hand: `MPNowPlayingInfoPropertyIsLiveStream = true`, title = programme, artist = "2.1 WXXX", artwork = programme or channel image, no elapsed time. Remote commands: play/pause (stop and reopen), next/previous track = channel up/down; skip and seek disabled. PB's Now Playing is AVPlayer-based (PB NowPlaying.swift:24-82) and is generalised to take a `LiveSource`.
- **Audio session:** `.playback` / `.moviePlayback`, as PB already activates it (PB AudioSession.swift:34); the background audio mode is already declared (M project.yml:60-61). An interruption stops the stream (frees the tuner); its end reopens if the system says to resume. Local-network access and the plain-HTTP exception for LAN addresses are already declared (M project.yml:51-53).

### 3.4 API sketch

```swift
// MarqueeCore/Live — no FFmpeg; built on PlexHTTPClient (docs/core-api.md)
public struct LiveChannel: Identifiable, Hashable, Sendable {
    public let id: String            // channelKey, hex-hex
    public let dvrKey: String
    public let number: String        // vcn, "2.1"
    public let callSign: String
    public let title: String
    public let logo: URL?
    public let isHD: Bool
    public let gridID: Int?          // Media.channelID, for grid ?channel=
    public let device: TunerDevice
}

public struct LiveAiring: Identifiable, Hashable, Sendable {
    public let id: String            // Media.id
    public let channelKey: String
    public let ratingKey: String, guid: String
    public let title: String         // grandparentTitle ?? title
    public let episodeTitle: String?
    public let start: Date, end: Date
    public let isNew: Bool           // premiere
    public let genres: [String]
    public let thumb: URL?
}

public struct TunerDevice: Hashable, Sendable {
    public let uuid: String
    public let uri: URL
    public let tunerCount: Int
    public var speaksHDHomeRun: Bool { uuid.hasPrefix("device://tv.plex.grabbers.hdhomerun/") }
    public func streamURL(_ channel: LiveChannel) -> URL   // uri/auto/v<number>
}

public actor PlexLiveTV {
    public func dvrs() async throws -> [LiveDVR]
    public func channels(_ dvr: LiveDVR) async throws -> [LiveChannel]
    public func guide(_ dvr: LiveDVR, from: Date, to: Date) async throws -> [LiveAiring]
    public func tune(_ channel: LiveChannel) async throws -> PlexLiveSession
    public func recordOptions(_ airing: LiveAiring) async throws -> [RecordOption]
    public func record(_ option: RecordOption) async throws -> RecordingRule
    public func scheduled() async throws -> [ScheduledRecording]
    public func cancel(_ recording: ScheduledRecording) async throws
    public func delete(_ rule: RecordingRule) async throws
}

public struct HDHomeRunClient: Sendable {           // discover.json, lineup.json, lineup_status.json
    public func discover(_ base: URL) async throws -> HDHomeRunDevice
    public func lineup(_ base: URL) async throws -> [HDHomeRunChannel]
}

public enum LiveRoute: Sendable { case direct(URL), plex }
public struct LiveRouteDecider { public func route(_ channel: LiveChannel, _ context: RouteContext) -> LiveRoute }
public actor GuideCache { /* disk JSON per DVR; 3 h window first, then 24 h; re-anchored to now on read */ }
public struct LiveClockServo { public mutating func rate(buffered: Double, target: Double) -> Double }

// Packages/MarqueeLive — depends on the engine's FFmpeg product
@MainActor public final class LiveStreamPlayer {
    public let view: LiveVideoView                     // backed by the AVSampleBufferDisplayLayer
    public private(set) var state: State               // idle, opening, slate, picture, playing, stalled, failed(Failure)
    public var onStateChange: ((State) -> Void)?
    public private(set) var audioTracks: [LiveAudioTrack]
    public private(set) var diagnostics: LiveDiagnostics
    public private(set) var pictureInPicture: LivePictureInPicture?
    public func open(_ url: URL)                       // while another plays: a change, in takeover order
    public func play(_ ring: ByteRing)                 // bytes the caller writes: tests and screenshots
    public func close()
    public func resume()
}
// L7 adds caption cues and audio track selection.

// App — the player talks only to this
@MainActor public protocol LiveSource: AnyObject {
    var state: LiveState { get }
    var status: String? { get }
    var diagnosticsLine: String? { get }
    func play(_ channel: LiveChannel) async
    func stop()
}
// LiveRouter decides each tune (§2.2) and plays it through DirectLiveSource (LiveStreamPlayer) or
// PlexLiveSource (tune + decision + PB VideoBackend).
```

`MarqueeLive` is a separate local package so `MarqueeCore` stays free of FFmpeg and its unit tests stay fast.

## 4. Startup and channel change

### 4.1 Budget

Direct path on LumaTuner; targets are from tap, measured times from the request.

| Step | Target p50 / p90 | Measured (O) | Basis |
|---|---|---|---|
| Request on the wire | 30 / 50 ms | The tuner answers in 0.04-0.11 s; first byte 0.07-0.16 s (34.4: 1.79 s) | Channel, URL and route are decided while the guide is on screen |
| First picture (slate) | 0.30 / 0.50 s | 0.61-0.79 s on 10 channels; R7 would make it about 0.2 s | The tuner sends its slate at once (T live-tv-tuner.md:22) with an intra picture every 0.5 s (T tuner-slates.md:41-43); an SD intra picture decodes in milliseconds [INFERENCE until L0] |
| Station picture | Tuner delivery + at most 0.15 s | 1.53-5.31 s on 10 channels; 2.36-2.86 s live on 2.1 | The TV routes about 0.7 s after the request; the first picture packet comes 0.1-0.7 s after routing, the first whole picture up to 3.0 s (T stream.rs:258-267); first byte median 1.81 s, 0.93-4.27 s (T capture.md:111) |
| Motion and sound | Still + 0.5-1.0 s [INFERENCE] | Still + 0.21-1.22 s | §3.2 step 8 |
| Channel change to slate | 0.35 / 0.60 s | 0.98-1.10 s: the tuner ends the old stream 0.27-0.37 s after the new request and answers it in 0.32-0.41 s | Same-client takeover plus slate |
| Never-seen channel | Slate held up to 4 s | 30.1: slate at 3.35 s, no station within 20 s | `shape_wait` (T stream.rs:264-268); R4 removes it |
| Plex path, for comparison | 2.95 s to playing; change 2.9-3.1 s | | O |

The measured column is LiveEngine on BeastNAS (Linux) with a clock-only output in place of the phone's layers, on the live tuner and on its captures replayed at their recorded arrival times; the phone's own numbers are L4b's receipt. Station picture and playing per channel: 2.1 2.60 / 3.67 s, 5.1 1.92 / 2.81, 11.11 3.65 / 4.28 (1080i), 46.1 2.10 / 3.32 (1080i), 34.4 2.40 / 2.61 (H.264 640×480i, no slate), 2.2 3.60 / 4.56, 36.1 3.16 / 3.95, 69.1 5.31 / 6.12 (1080i), 17.1 2.47 / 3.62, 63.1 1.53 / 2.52. Live change 2.1 → 5.1: connected 0.39 s, slate 1.04 s, picture 3.54 s, playing 4.67 s, no drops.

Soak, 30 min live on 2.1 (MPEG-2 1280×720p, AC-3 5.1 mixed to stereo): no underruns or re-anchors, J held at 0.30 s, buffer 0.29-0.37 s, rate 1.000-1.001, 29 of 107,011 pictures dropped (0.03 %), resident memory 56 MB after the first minute, 60 MB at most, 38 MB at the end.

### 4.2 Work done in parallel

When the Live TV tab appears (not at app launch, so Home's startup is untouched), all at once:

- Cached guide drawn from disk; `GET /livetv/dvrs`, the channel lineup and the grid from 30 min ago to 3 h ahead requested together (2-8 ms, 16 KB, 0.13 s; O); the 24 h guide follows in the background.
- `discover.json` reachability for each HDHomeRun device (0.5 s timeout, cached 60 s), and the scheduled recordings (record glyphs and the guard).
- A `LiveStreamPlayer` is prepared: MPEG-2 decoder context open, 720×480i filter graph built, display layer attached off screen. No network.

On tap, all at once: the player appears with the channel card from cache, the stream request goes out, and the audio session activates. Nothing waits for the audio session. On the Plex path the tune must finish before the decision request (the decision needs the session path); the observed follow-ups are already 28 ms and 100 ms apart (O).

Surfing: a swipe updates the channel card at once and commits the tune 300 ms after the last swipe, so a fast flick across five channels costs one tune. Buttons commit immediately. Guide cells draw text only; logos come from a disk image cache, decoded off the main thread at display size.

### 4.3 Signposts and diagnostics

`OSSignposter` with the app's subsystem and category `LiveTV`, alongside the engine's `VideoEngine` subsystem (E ENGINE.md:126-131):

- Intervals: `live.open`, `live.slate`, `live.picture`, `live.sound`, `live.change`, `plex.tune`, `plex.playing`, `guide.load`, `guide.firstDraw`.
- Events: `shape` (new size, rate or scan), `underrun`, `reanchor`, `servo` (rate change above 0.005), `refusal` (code).

The **Live TV diagnostics** line is one line per tune, shown in Settings › Diagnostics and on long press of the player's status label, and copied on tap:

```
2.1 direct · slate 0.21 s · picture 1.62 s · sound 2.18 s · MPEG-2 720×480i bwdif · AC-3 5.1→2.0 · J 0.30 s · buf 0.33 s · rate 1.002 · drops 0
7.1 plex · tune 1.41 s · playing 3.02 s · H.264 1280×720 · HLS 1 s
```

## 5. LumaTuner requests and questions

The app works without any of these; each makes it faster or clearer.

- **R1 Slate marker.** A mark in slate pictures (picture user data or a private descriptor) so the app can tell a slate from the station: exact station-picture timing in diagnostics and a correct status label. Today a slate is an ordinary MPEG-2 picture [INFERENCE].
- **R2 Status route.** `GET /status.json`: idle or streaming, holder, channel, signal strength and quality, TV in use. The tuner serves only discover, lineup_status, lineup.json/.m3u, xmltv and auto (T server.rs:280-307). With it the app can say "Plex is using the tuner" before trying and run the recording guard without asking Plex.
- **R3 Lineup fields.** `VideoCodec`, `AudioCodec`, `HD`, `DRM` and `Favorite` per channel, as HDHomeRun sends them (https://info.hdhomerun.com/info/http_api; Jellyfin reads the same fields, https://github.com/jellyfin/jellyfin/blob/master/src/Jellyfin.LiveTv/TunerHosts/HdHomerun/Channels.cs). LumaTuner sends GuideNumber, GuideName and URL only (T docs.rs:103-111).
- **R4 No shape wait for clients that cope.** A query flag (for example `?slate=now`) that sends the fallback-shape slate at once for a never-seen channel. The 4 s hold exists because Plex's transcoder restarts on a size change (T stream.rs:264-267); the phone rebuilds its filter graph instead.
- **R5 Holder in refusals.** Name the holder in a refusal (for example `X-LumaTuner-Holder: plex|tv|<address>`), so the app can say "Plex is recording 7.1".
- **R6 Recordings first** (policy for Nitin). Let the Plex server's request take the tuner from another client, ending that stream with the last slate (T stream.rs:279-280). The app's guard covers the phone; this covers every client.
- **R7 Slate PES length.** Set `PES_packet_length` on the slate's video PES packets. With 0 (unbounded), FFmpeg's mpegts demuxer releases a picture only when the next PES starts, and the slate sends two pictures a second, so its first picture shows at 0.61-0.79 s although its bytes arrive by about 0.2 s (O).

- **Q1** Does any station broadcast E-AC-3? The tuner's E-AC-3 path is untested (T tuner-slates.md:56-57); the app decodes both. Answer: none seen; the 10 stations measured all send AC-3 (O).
- **Q2** The tuner tells clients apart by address (`take(peer: IpAddr)`, T stream.rs:409). A phone on Tailscale reaching the LAN through BeastNAS's subnet route may arrive with BeastNAS's address, the same as the Plex server's, and take over a Plex recording instead of being refused [INFERENCE: depends on the subnet router's address translation]. Direct is used on the home network only (§2.2 rule 2).
- **Q3** Does any station broadcast 1080i? Only the fallback slate is 1080i (T tuner-slates.md:41-43); 1080i MPEG-2 is the expensive software case, and L0 tests it either way (E ENGINE.md:186). Answer: yes, 11.11, 46.1 and 69.1 (O).
- **Q4** Should the TV go back to its previous channel after a phone stream? Streaming moves the TV's last channel (T capture.md:115), so the TV's own Live TV later opens on what the phone watched.

## 6. Interface

Fluid and beautiful comes first: the guide scrolls at the display's full rate without hitches, every surface takes its colours, glass, radii and type from the theme tokens and changes live with the theme, and a programme on now starts with one tap.

### 6.1 Place in the app

Tabs: Home · Library · Live TV · Watchlist · Search; Settings opens from the profile button on Home. Until L2 lands the Live TV tab shows an honest empty state ("Live TV is on its way"), never a fake guide. Live TV adds nothing to Home (the push Plex users complained about, https://forums.plex.tv/t/915221).

### 6.2 Borrow and avoid

| App | Borrow | Avoid | Source |
|---|---|---|---|
| YouTube TV | Start/end and time left on the airing now; checkmark when recording; mini guide in the player with the last channel first; channel logo opens that channel's schedule; sort, custom order, hidden channels | Small fixed type; 2 h horizon with no day jump; a long-press card that replaced the live preview and slowed browsing | https://www.androidcentral.com/streaming-tv/youtube-tv/youtube-tvs-new-live-guide-wants-to-look-cleaner-but-one-change-may-annoy-mobile-users, https://michaelsaves.com/streaming/youtube-tv-live-guide-tutorial/ |
| Channels | Progress bars in On Now, Guide and Quick Guide; Quick Guide with the 3 recent channels; jump to last channel; clock in the guide; channel collections; cached guide and station images; automatic PiP on leaving the app | A tap that opens an episode page before playing (the reviewer wanted it to play). Its removal of swipe-to-change concerned the Apple TV remote's touch surface, not phones | https://getchannels.com/releases/, https://www.macworld.com/article/228493 |
| Plex | What's On groupings (On Now by genre) as guide categories | Guide times left stale after the app sat in the background; Live TV pushed onto Home | https://www.plex.tv/blog/its-go-time-the-new-plex-experience-is-here/, https://forums.plex.tv/t/909610, https://forums.plex.tv/t/915221 |
| TiviMate | Scrolling left from now goes back in time, one control returns to now; categories are the way back out | Remote-focus navigation | https://neighborhoodnerd.net/help/tivimate |
| Apple TV app | LIVE badge; jump to live [INFERENCE] | — | — |

### 6.3 Layout by size

- Portrait, compact width: now/next list with a time strip (§6.4).
- Landscape phone: grid (§6.5). Lucent moves navigation to a left rail when the short side is under 500 pt (design-language skill, layout section); the channel column sits right of the rail.
- Regular width (iPhone Duo unfolded): grid in both orientations, channel column 160 pt, 8 pt per minute; tabs adapt to a sidebar (M DESIGN.md:264).
- Accessibility text sizes (AX1 and up): the list in every orientation (§6.6).

### 6.4 Portrait list

```
390 pt ───────────────────────────────────────────────────
Live TV                                    [⏺ Recordings]    display, ink
(All) (Favourites) (Recent) (Sports) (News) (Kids) →         chips, Space.s2 apart
[ Now ]  8:30   9:00   9:30   10:00   Tonight   →            time strip
──────────────────────────────────────────────────────────    edge hairline
▢    Evening News                                    ⏺       row ≥ Size.rowMin
2.1  8:00–8:30 · 12 min left
     ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬───────────                           progress 3 pt
     Next 8:30  Quiz Night
──────────────────────────────────────────────────────────
```

- Side insets `Space.inset` (16); row padding `Space.s3` (12); `Space.s3` between logo and text.
- Logo tile 40×40, radius `Radius.inner(Radius.row, inset: Space.s2)`, fill `glass`; channel number below in `caption`, `ink2`, monospaced digits.
- Programme `headline` `ink`, one line (two at large sizes); times and time left `caption` `ink2`; next airing `label` `ink2`.
- Progress 3 pt capsule, `accent` on `trackOff`, advanced every 30 s without relayout.
- Record glyph trailing (§6.10). Separator `edge` hairline from the text column.
- Chips: height 32 (`Space.s7`) with a 48 pt hit area (`Size.target`); selected solid `accent` with `accentInk`, others outlined in `ink2` (M DESIGN.md:125, 138). Categories: All, Favourites (local, per profile), Recent, then the provider's genre filters.
- Time strip: Now, half hours to 24 h ahead, then Tonight and Tomorrow. A chosen time shows the airing at that time and the one after; tapping such a row opens the programme sheet unless the airing is on now.
- Tap a row on now: plays. Long press: menu (Watch, Record, Details, Favourite). Pull to refresh reloads the guide.

### 6.5 Landscape grid

```
844 × 390 ───────────────────────────────────────────────────────────────────
rail │ Today ▾   8:00            8:30            9:00            9:30   8:18
     │ ┌────────┬──────────────────────┬──────────────────────────┬──────────
     │ │▢   2.1 │ Evening News       ⏺ │ Quiz Night         NEW   │ Movie: …
     │ │   WXXX │ 8:00–8:30 · 12 left  │ 8:30–9:00                │
     │ ├────────┼───────────┬──────────┴───┬──────────────────────┼──────────
     │ │▢   4.1 │ Game Show │ Comedy       │ Late Drama           │
     │ │   WXXX │           │              │                      │
     │ └────────┴───────────┴─────┃────────┴──────────────────────┴──────────
     │                            ┃ now line                       ( ⟲ Now )
```

- Channel column `Size.gridMin` (104) on phones, 160 at regular width; sticky. Time ruler sticky with the clock at its end.
- Scale: 6 pt per minute on phones (30 min = 180 pt), 8 pt per minute at regular width.
- Row height max(`Size.rowMin`, content height at the current text size). Cell gap `Space.s1` (4); cell radius `Radius.control` (14); cell padding `Space.s2` × `Space.s3`.
- Fill: on now `glassRaised`, future `glass`, past none with `ink2` text. Title `label`; time `caption` `ink2`; NEW and LIVE as small chips; record glyph trailing.
- A cell that began before the visible edge pins its title to the screen edge so it stays readable.
- Now line: 2 pt in `live` (M DESIGN.md:131), moved every 30 s by a transform on a decoration view, no relayout. Jump to Now: a 48 pt capsule (`Size.target`) in `accent` with `accentInk`, shown when the now line is off screen; scrolls to 15 min before now.
- Left of now: up to 2 h back, read-only, dimmed. Right: the cached 24 h. The day menu jumps to Tonight 8 PM and Tomorrow.
- Tap a now cell or channel cell: plays. Tap a future cell: programme sheet. Long press: menu.
- Built as a `UICollectionView` with a custom layout (two sticky axes, cells placed by time) inside a representable; SwiftUI's lazy grids place cells in fixed columns, not by time [INFERENCE].
- Re-anchors to now whenever the tab appears or the app returns to the foreground (https://forums.plex.tv/t/909610).

### 6.6 Accessibility

- AX sizes: the list everywhere; titles wrap rather than truncate; channel numbers never truncate.
- VoiceOver: "2.1 WXXX, Evening News, 8 to 8:30 PM, 12 minutes left, recording", with actions Watch, Record, Details. Rows are containers so the rotor moves channel by channel.
- Reduce Motion: the now line jumps; transitions become a 120 ms fade (M DESIGN.md:405-418).
- `live` must reach 3:1 against `canvas` and `glass` in every theme; the theme check only warns today (M check_themes.py:28-33, 170).

### 6.7 Live player

```
┌──────────────────────────────────────────────────────────────────┐
│ ⌄   ▢ 2.1 WXXX · Evening News · 8:00–8:30          CC  ◁))  ⎚    │
│                                                                  │
│              ⏮                ■                ⏭                 │
│                                                                  │
│ ● LIVE   8:00 ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬────── 8:30        ↩ last   ☰ guide │
└──────────────────────────────────────────────────────────────────┘
```

- Player rules of M DESIGN.md:333-363: 56 pt `glass` buttons with 26 pt glyphs, chrome fades after 3 s, swipe down closes. Text over video sits on `scrim` at 0.55 or more (M DESIGN.md:148-150).
- Top: close (`chevron.down`), channel card (logo, "2.1 WXXX", programme, times), captions (`captions.bubble`), audio (`speaker.wave.2`, track menu), AirPlay route picker.
- Centre: previous channel (`backward.end.fill`), stop/play (`stop.fill`/`play.fill`), next channel (`forward.end.fill`). Stop frees the tuner and keeps the last frame.
- Bottom: LIVE chip (`scrim` 0.80 with a `live` dot), programme progress 4 pt (white on white at 0.35) with start and end, last channel (`arrow.uturn.backward`), guide (`list.bullet.rectangle`). No seek bar.
- Status label (bottom left, `caption` on `scrim`) only when it says something: "Tuning 7.1" (stations without slates), "Weak signal", "Playing through Plex", a tuner refusal. Never a spinner over the picture.
- Gestures: swipe left/right surfs (§6.8); swipe up opens the Quick Guide; swipe down closes and frees the tuner; tap toggles chrome; double tap toggles fit and fill.

### 6.8 Channel card

While surfing a card (`Radius.card`, `glassRaised` over `scrim`) follows the finger: logo, number, call sign, programme, progress, next. Each channel passed gives a selection haptic; the tune commits 300 ms after the last swipe. Motion uses the 260 ms spring and the 0.97 / 90 ms press (M DESIGN.md:405-418).

### 6.9 Quick Guide and programme sheet

- **Quick Guide:** swipe up or the guide button opens a sheet (`Radius.sheet`, opaque `sheet` over video, M DESIGN.md:150) at the medium detent while video plays above. First row: the last 3 channels. Below: the §6.4 rows. A tap changes channel and closes the sheet.
- **Programme sheet:** art, title, "S2 E5 · Episode title", "Tonight 8:00–8:30 PM · 2.1 WXXX", summary, badges (NEW, HD). Actions: Watch (on now), Record Episode, Record Series or Record Movie (template types 4, 2, 1), Options (start and end padding, new episodes only). Recording actions are hidden for users who cannot record (Home members, servers without Plex Pass).

### 6.10 Recordings

Recordings (header button) has Scheduled | Recorded. Scheduled lists upcoming airings by day from `/media/subscriptions/scheduled`, swipe to cancel one, with series rules at the top (edit, delete). Recorded lists the newest items in the DVR's target library sections; they are ordinary library items and play in the normal player.

| State | Glyph | Role |
|---|---|---|
| Will record | `record.circle` | `live` |
| Covered by a series rule | `record.circle`, "Series" in the sheet | `live` |
| Recording now | `record.circle.fill`, 1 Hz pulse (still with Reduce Motion) | `live` |
| Conflict, no free tuner | `exclamationmark.triangle.fill` | `warning` |
| Failed | `xmark.octagon.fill` | `danger` |
| Recorded | `checkmark.circle` | `positive` |

### 6.11 Empty and error states

Per M DESIGN.md:444-458:

- No DVR on the server: "Live TV isn't set up on <server>. Set it up in Plex on a computer." No setup on the phone.
- Tuner offline (device `status` dead): channels dimmed, banner "The tuner isn't responding".
- TV busy (805): the tuner's sentence and Try Again.
- No or old guide data: "No guide data yet" with the last refresh time.
- Away from home: plays through Plex; the status label says so once.
- Loading: skeleton rows in list and grid, never a full-screen spinner.

## 7. Slices

Order: L0 → L1 → L2 ∥ L3 ∥ L4a → L4b → L5 ∥ L6 ∥ L7. Each slice carries tests for what it changes.

| Slice | Owns | Acceptance |
|---|---|---|
| L0 Measure | `Packages/MarqueeLive/Bench` (spike, not shipped) | On the oldest supported iPhone: MPEG-2 720×480i and 1080i decode with `bwdif` and with `yadif_videotoolbox`, at 59.94 and 29.97 output; frame rate, CPU and energy from Instruments; the choice written into §3.2. Uses a recorded TS sample; a new capture from the TV takes its only tuner and needs Nitin's OK |
| L1 Core | `Packages/MarqueeCore/Sources/MarqueeCore/Live/*` and tests; Live fixtures in `App/Testing/FakePlex.swift` | Anonymised fixtures of every §1.1 response parse; §1.2 joins hold; one decider test per §2.2 rule; servo and guide-cache re-anchoring tested with a fake clock |
| L2 Guide | `App/Screens/LiveTV/*` (list, time strip, grid layout, cells, programme sheet); tab entry in `RootView` with that file's owner | No hitches in an Instruments scroll trace over a 24 h guide; AX sizes switch to the list; VoiceOver labels; theme switch recolours live |
| L3 Plex path | `App/Player/Live/LiveSource.swift`, `PlexLiveSource.swift`, live chrome | Every channel plays through Plex; channel change works; closing sends the stopped timeline and `/livetv/sessions` empties |
| L4a Renderer | `Packages/MarqueeLive/*` | Plays a recorded LumaTuner TS fixture with slates and a slate-to-station shape change; servo test with a fake clock; flat memory over 30 min |
| L4b Direct | `App/Player/Live/DirectLiveSource.swift`, decider wiring, refusals, recording guard | §4.1 budget met on the phone (diagnostics lines in the receipt); refusal messages; guard releases before a recording |
| L5 Surfing | Player gestures, channel card, Quick Guide, last channel, PiP, Now Playing, AirPlay switch | LT4-LT11 |
| L6 DVR | Programme sheet actions, `App/Screens/LiveTV/Recordings*` | LT15-LT16; record glyphs follow the server |
| L7 Captions and audio | 608 overlay, audio track menu | LT17-LT18 |

### 7.1 On-phone test sheet

Every result goes into the receipt with its diagnostics line.

| # | Do | Expect |
|---|---|---|
| LT1 | Open Live TV cold, then warm | Cached guide at once; fresh guide within 1 s |
| LT2 | Tap an HD channel on now | Slate within 0.3 s, station picture, then motion and sound together |
| LT3 | Tap an SD channel | Deinterlaced, no combing on motion |
| LT4 | Next and previous buttons | Slate within 0.35 s of each press |
| LT5 | Swipe across 5 channels quickly | One tune in the diagnostics |
| LT6 | Last channel | Back to the previous channel |
| LT7 | Quick Guide, pick a recent channel | Channel changes, sheet closes |
| LT8 | Swipe down | Tuner free: Plex tunes at once |
| LT9 | Lock the phone without PiP | Sound continues; picture back within 1 s of unlocking |
| LT10 | Go home while playing | PiP shows live with no scrubber; closing it frees the tuner |
| LT11 | AirPlay to an Apple TV | Switches to Plex; video on the TV |
| LT12 | On cellular | Plays through Plex; status says so |
| LT13 | TV showing its own Live TV | The tuner's 805 sentence with Try Again |
| LT14 | Plex recording due in 2 min on the tuner | Banner at 60 s; phone lets go 5 s before; recording succeeds |
| LT15 | Record an episode | Listed under Scheduled; cancelling removes it |
| LT16 | Record a series | Rule listed; deleting removes it and its airings |
| LT17 | Captions on a captioned channel | Shown on Direct; through Plex the button says captions are unavailable |
| LT18 | Channel with a second audio track | Menu switches tracks |
| LT19 | Largest accessibility text size | List layout, no mid-word truncation, VoiceOver reads cells |
| LT20 | Reduce Motion | Now line jumps; transitions fade |
| LT21 | Change theme with the guide open | Colours change live |
| LT22 | Play for 30 min | Buffer 0.2-0.5 s, rate within ±0.5 %, memory flat |

Out of scope: pause and timeshift, start over, multiview, live previews in the guide, ATSC 3.0 (the TV's tuner is a single ATSC 1.0 tuner, T capture.md:36), CEA-708 captions, guide sources other than Plex.
