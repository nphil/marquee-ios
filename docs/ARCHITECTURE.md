# Architecture

Marquee for iPhone is three layers and one external engine. Each boundary exists for a reason that shows up in how the work is built and tested; this file records those reasons so they are not rediscovered. Working rules are in `AGENTS.md`; the public API of the bottom layer is in `docs/core-api.md`.

```
App/                    SwiftUI screens, session, player model, theme      (iOS, CI only)
  |  uses
  +-- Packages/MarqueeLive   direct tuner playback: LiveEngine, MarqueeLive (iOS only)
  +-- VideoEngine            stashy-videoengine 2.0.1: on-device remux, FFmpeg (external)
  +-- Packages/MarqueeCore   Plex client, rules, decisions   (Foundation only, Linux-testable)
```

## MarqueeCore: everything that does not draw

MarqueeCore holds the Plex client, the choice of server address, library calls, audio and subtitle rules, and the playback and live route decisions. It imports Foundation (and Observation for `PagedLoader`); `Security` appears only in `KeychainStore`, which compiles on Apple platforms only.

Reasons:

- **No local Mac.** The App target builds and runs UI tests only on a GitHub Actions macOS runner, and the `app` job takes about an hour. Keeping logic out of it gives a 30-second loop: `swift test --build-system native` on Linux runs the whole Core suite. The package declares macOS only so the same tests run on the CI host too.
- **Decisions are pure functions.** `PlaybackRouteDecider.decide`, `LiveRouteDecider.route`, `SubtitlePicker.decide`, `AudioPicker.pick`, `ConnectionRanking`, `HomeLayout.arrange` and `LiveRecordings.mark` take values and return values. The App performs the effect (start a stream, probe an address). A rule change is then a Linux test, and a route is explained in plain words (`RouteReason`) rather than reconstructed from logs.
- **Plex is lenient input.** Plex sends `"1"`, `1` or `true` for one field and omits others, and server versions differ. Models make every field optional and decode through `LenientDecoding`, so a bad field never drops an item.
- **No token in anything that persists.** `PlexError` carries no token or URL; image URLs are built without a token so they are stable cache keys; `URL.removingPlexToken` is the one way to put a URL in a log. Only playback and transcode URLs carry the token, because AVPlayer cannot send headers, and they are never logged or cached.
- **One address at a time, chosen by probing.** A server lists local, remote and relay addresses, and the right one changes with the network. `PlexServerConnection` probes them all in parallel (`/identity`, no token), ranks local over remote over relay and https over http, gives better tiers a short grace period, and reuses only a remembered local address without a probe. `PlexLibrary` moves a read to another address once when the chosen one stops answering and never repeats a write.
- **Per-item work is async and `Sendable`.** `PlexHTTPClient` is an actor that adds identity and token headers and decodes off the actor; `PagedLoader` is the one `@MainActor @Observable` type, for grid paging, with generations so a late page from an old query is dropped.

## MarqueeLive: a second package for a different platform constraint

Live TV can bypass Plex and read an HDHomeRun-protocol tuner on the home network (`docs/LIVE-TV.md` §2). That needs FFmpeg decoding into sample-buffer layers, which the video engine ships for iOS only. So:

- `LiveEngine` (demuxer, decoders, byte ring, playout servo, tuner connection) imports no AVFoundation, which keeps it testable without a device UI and portable to a scratch package.
- `MarqueeLive` adds the AVFoundation side: `LiveStreamPlayer`, the sample-buffer output and the Picture in Picture and Now Playing types.
- `LiveFixtures` is a synthetic tuner and transport stream used by the engine's tests and linked into Debug app builds, so the Live TV screenshots play something without a real tuner.
- Its tests run on an iOS simulator through `xcodebuild` (the `live` CI job), not `swift test`.

The direct path exists to avoid a server transcode for a one-tuner antenna feed; Plex stays the only source of guide and DVR data, and the fallback when the direct path fails, when away from home, or under AirPlay video.

## App: session, screens, player

### Session and server content

`AppSession` is the single `@Observable` owner of sign-in state, the chosen server, the active Home profile, per-profile settings and the player. The root view switches on its `state`. Secrets (account token, server list with per-server tokens) live in the Keychain; the chosen server, active profile, last working address, profile settings and integrations live in UserDefaults through `SessionStorage`. UI-test launches keep secrets in memory and wipe a dedicated defaults suite, so one test's settings never leak into the next screenshot.

Screens do not own fetch logic scattered across views:

- `Remote<Value>` and `RemoteContent` (`App/Browse/Remote.swift`) hold one screen's server content: nothing until the first answer, then the last good answer kept through later failures with an offline banner and its age. A load that a newer one overtook changes nothing.
- `LoadKey` makes a screen's task restart when the library instance changes (sign-in again, profile or server switch), on Retry, or on a screen-specific input.
- `LibraryChanges` is the record of what this app changed on the server. A confirmed watched, watchlist or deletion change bumps a revision, and every screen that shows the title refreshes it. Deletions are also held as `DeletedTitles`, because Plex lists a deleted title until its trash is emptied and a refetch would bring it back. A deleted title that was on the Watchlist is also kept off the Watchlist screen for the session.

### Caches

- `ImagePipeline` (actor): decoded bitmaps in memory, resized files on disk, at the pixel size the view draws, so scrolling back and relaunching never refetch and no cell decodes while scrolling. Keys exclude the token and the address and include the server, so `forget(_:server:)` can evict a deleted title's art.
- `GuideCache` (actor, Core): the last Live TV guide per server and DVR, loaded re-anchored to now, so the tab draws at once and still shows something with the server away.
- Track memory (UserDefaults): audio and subtitle choices per server, profile and show, described by language and kind, because stream ids differ in every episode.

### Player

`PlayerModel` is one playback: route, stream, tracks, timeline, offers, play queue. It is separate from `PlayerView` because Picture in Picture, AirPlay, the Lock Screen and the queue must keep working after the screen closes; `PlayerCenter` holds the one active model and the presented one apart for that reason.

- **Route first.** The model calls `PlaybackRouteDecider`, then builds exactly one stream: direct play on AVPlayer, an on-device remux (`RemuxSession` from VideoEngine, for containers AVPlayer cannot open), or a server transcode (HLS). A `StreamKey` records what a track change can switch inside the running stream; anything else starts a new stream at the same position.
- **Timeline mapping.** Times are on the movie's timeline; a remux run or a server stream started part-way maps onto it through `origin`, which is why the lock-screen entry (`NowPlaying`) is published by hand.
- **Backend seam.** `VideoBackend` hides AVPlayer. The simulator decodes no video, so UI tests use `StillFrameBackend` (a fixture picture and a clock that ticks like AVPlayer's observer) and every player screen, gesture and offer is testable on CI while decoding stays a device-only check.
- **Server side effects.** The server chooses the audio and burned-in subtitle through `selectStreams`; loudness normalisation and dialog boost are server transcode options, since AVPlayer offers no audio tap on HLS.
- **Subtitles are drawn by the app.** Text cues and image subtitles are drawn in an overlay so one style, timing and position apply to every source; AVPlayer's own drawing remains only where the overlay cannot be seen (Picture in Picture, AirPlay).

### Live TV

`LiveSource` is one protocol with two implementations behind `LiveRouter`, which re-decides per tune using `LiveRouteDecider` (first matching rule of `docs/LIVE-TV.md` §2.2). A direct tune that fails before its first picture or while it plays carries on once through Plex; a tuner's own refusal does not, since Plex would be refused the same way. While the phone holds a one-tuner device, the router reads the recording schedule, warns a minute ahead and lets the tuner go 5 seconds before a recording starts. `LiveTVStore` owns the DVR, channels, guide, filters and recordings for the Live TV tab.

### Theme and design system

`Resources/themes.json` is the only source of colour: 40 themes of 20 roles. `ThemeStore` selects the theme (one per mode when following the system appearance) and views read `@Environment(\.theme)`, so a change repaints the whole app at once. The system parts take the theme's colour scheme and accent. `tools/check_themes.py` proves every theme's contrast on composited colours and that no two themes of a mode are recolours of each other; CI fails on any failure. Space, size and radius come from `App/DesignSystem/Tokens.swift`. The reasoning is in `docs/DESIGN.md` §5.

### Integrations

Integrations (SpeechDock, Bazarr, the direct Live TV path, anything added later) are off until enabled in Settings, each with its own page and stored connection. They supply data to the core and never styling. Secrets such as an API key go to the Keychain, and an address that is not a viewing preference is kept per iPhone rather than per profile.

## Tests and seams

| Layer | How it is tested | Seam |
|---|---|---|
| MarqueeCore | Swift Testing on Linux (`PlexTransport` fakes, fixed clocks) | `PlexTransport` protocol, injected clocks and sleeps |
| MarqueeLive | simulator `xcodebuild test`, synthetic tuner | `LiveFixtures`, a simulated clock |
| App | XCUITest on the CI simulator, screenshots in dark, light and large text | `FakePlex` (a `URLProtocol` answering from `UITests/FakePlex/`, Debug only), `StillFrameBackend`, `FakeTuner`, a fixed Live TV clock |
| Playback and heat | by hand on an iPhone | `docs/DEVICE-TEST.md` |

Test-only types are `#if DEBUG`, so the Release IPA carries none of them.

## Build and release

XcodeGen builds the project from `project.yml`; the `.xcodeproj` is not stored. CI builds an unsigned Release IPA, runs the UI tests, and on `main` publishes it as a GitHub release and patches the Feather source (`apps.json`) on `main`. The version is derived from the newest tag, so it is never committed. Details are in `AGENTS.md` under CI and release.
