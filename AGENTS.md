# Agent guide: Marquee for iPhone

Marquee for iPhone is a native SwiftUI Plex client for iOS 27 (Swift 6, Liquid Glass, 40 colour themes), sideloaded as an unsigned IPA through a Feather/AltStore source. It matches the behaviour of Nitin's Marquee TV app (webOS) on a phone, plus Live TV. There is no local Mac: everything that needs Xcode runs on GitHub Actions.

Read first: `docs/HANDOFF.md` (unfinished work, how it lands, decisions already made), then `docs/ARCHITECTURE.md` (layers and why), then the file for the area you touch (table below).

## Rules that bite

- **Clean room.** No Marquee TV or PlxNative code is copied or read. Behaviour comes from `docs/behaviour-spec.md` and Plex's public API. Of the TV app's folder (`/data/home/Marquee`) only `locales/en` and `docs/` may be read, never its source.
- **Never touch Nitin's real Plex server or account.** No DELETE, watched/unwatched change, rating, collection or setting change against it, even to "test". Deletion, watched state and Live TV writes are exercised only against FakePlex (below). Reads against the real server for diagnosis are fine; never log, commit or store its token.
- **Tokens stay out of everything that persists.** Image URLs carry no token. Log URLs through `URL.removingPlexToken`. Only playback and transcode URLs carry a token (AVPlayer cannot send headers); never cache or log them. Secrets go to the Keychain; never put an API key or token in a doc, fixture, test or commit.
- **Delete is permission-gated.** Plex answers 401/403 to a delete unless the server owner enabled "Allow media deletion"; `PlexLibrary.delete` maps that to `DeleteOutcome.notAllowed` and the UI hides the action by `AppSession.canDeleteMedia`. Plex also keeps a deleted title in lists until the library trash is emptied, so the app remembers it in `DeletedTitles` and filters every list. `MediaDeletion` (Core) owns the rest of a title delete: identity read first, Watchlist cleanup, recheck after a 5xx or timeout. FakePlex answers every DELETE with 200.
- **HLS has no audio tap.** AVPlayer cannot process audio of an HLS stream, so loudness normalisation and dialog boost are server transcode options, not a local filter. The simulator decodes no video: playback, heat and smoothness are proved on a real iPhone (`docs/DEVICE-TEST.md`), never claimed from CI.
- **A route is decided in Core, performed in the App.** Do not put codec, container or tuner rules in a view or in `PlayerModel`; add them to `PlaybackRouteDecider` / `LiveRouteDecider` with a Linux test.
- **Themes and tokens.** Every colour comes from the theme (`@Environment(\.theme)`, roles in `Resources/themes.json`); space, size and radius from `App/DesignSystem/Tokens.swift`. No hex or raw numbers in views, and plugins/integrations supply data, never styling. A new surface must read in all 40 themes at default and accessibility text sizes.
- **Integrations are plugins.** Off until enabled in Settings, each with its own page; the core stays minimal.
- **Push straight to `main`.** No feature branches or PRs (`/data/home/lgtv/CLAUDE.md`). Before pushing run the touched package's tests; docs-only commits use `[skip ci]`. Fetch and rebase right before push, because several agents land work on `main` at once. Exception: while `docs/HANDOFF.md` describes an open batch, its work lands on the batch's branch and `main` is pushed once for the whole batch.
- **`apps.json` and the release job are CI-owned.** The release job creates the GitHub release and commits `Update the Feather source for vX.Y.Z [skip ci]`; never hand-edit `apps.json`, tag, or bump a version. The version comes from the newest tag plus one patch.
- **Measure before claiming.** "Faster" or "fixed" needs a frame or video result; "accepted" means checked on the actual iPhone with the receipt recorded; untested cases are listed as untested.
- **Writing.** Commit messages, docs and release notes are short and third person ("the iPhone", never "you"). State what changed and why, not the route taken.
- **Scratch.** The data disk is nearly full. Work in a worktree under `$CODY_SCRATCH`, reuse one build directory, and delete worktree, build output and screenshots when done.

## Module map

`Packages/MarqueeCore` (Foundation only; `Security` only in `KeychainStore`; CryptoKit only in `LinkKeys`, swift-crypto in its place on Linux), under `Sources/MarqueeCore/`:

| Folder | Holds |
|---|---|
| `Plex/` | `PlexHTTPClient` (actor) and `PlexTransport`, request building, lenient models, `PlexTV` (sign-in PIN, servers, Home profiles), `PlexWatchlist`, client identity, `KeychainStore` |
| `Connection/` | `PlexServerConnection`: probe all addresses, `ConnectionRanking` (local > remote > relay, https > http), `HomeNetwork` (hosts allowed plain http) |
| `Library/` | `PlexLibrary` (browse, search, metadata, timeline, mark watched, delete), `PagedLoader`, `SectionQuery`, `HomeLayout`, play queues, transcode sessions, `Deletion` |
| `Playback/` | `PlaybackRouteDecider` (direct, remux, transcode and why), `DeviceCapabilities`, `TranscodeRequest`, `TrailerAutoplay`, `ThemeMusic` and `ThemeFade` |
| `Tracks/` | `AudioPicker`, `SubtitlePicker`, `TrackMemory`, language and track-label rules |
| `Live/` | Plex Live TV and DVR (`PlexLiveTV`), guide models and `GuideCache`, recordings, `LiveRouteDecider`, `HDHomeRunClient` for the direct tuner path |
| `Subtitles/` | `Bazarr` client (search, download), `SpeechDock` (word timing: the file as the service reads it, request windows, client), `SubtitleLook` (presets, fonts, edges, boxes, position), `SubtitleTiming` (offset), `SubtitleReveal` (Reveal as Spoken modes) |
| `Navigation/` | `Destination` and `TabLayout`: the person's tabs and their rules |
| `Link/` | Linked phones: `LinkInvite` (the QR code's link, ids, names), `LinkKeys` (HKDF keys), `LinkMessage` (preamble, messages, status, `LinkDialing`, `LinkStatusPacer`) |

Reveal as Spoken gets its word timing from SpeechDock through `App/Player/WordTiming.swift`. Remote server content in the App is `App/Browse/Remote.swift`.

`Packages/MarqueeLive` (iOS only, FFmpeg through VideoEngine): `LiveEngine` (demux, decode, playout, tuner connection; no AVFoundation), `MarqueeLive` (`LiveStreamPlayer`, sample-buffer output, Picture in Picture and Now Playing types that the app does not use yet), `LiveFixtures` (synthetic tuner and stream).

`App/`: `Account/` and `Session/` (sign-in, `AppSession`, `SessionStorage`), `RootView.swift` (root switch and `MainTabs`: the tabs from `TabLayout`; Settings is a sheet from Home), `Navigation/` (`Route`, `BrowseStack`, `Destinations`: each destination's tab and page, `openDestination`; `SheetZoom`: the Home buttons Settings and the remote zoom out of), `Browse/` (routes, detail, `Remote`, `LibraryChanges`, item actions, toasts, `ThemeMusicPlayer`), `Screens/` (Home, Library, Search, Watchlist, Tab Bar, `LiveTV/`), `Player/` (`PlayerModel`, backends, chrome, trickplay, sidecar subtitles, `Live/` router and sources), `Settings/`, `Remote/` (the LumaTV remote integration around LumaRemoteKit; its UI tests pair with the kit's `LumaRemoteFakeTV`), `Link/` (linked phones: `PhoneLink` finds and talks to them over Bonjour and LumaRemoteCore's Noise channel, `LinkHost` answers as the host, `LinkController` is the controlling phone's remote, the settings page and scanner; the keys in `LinkStore`), `Images/` (`ImagePipeline`), `Theme/`, `DesignSystem/`, `Testing/` (Debug-only `FakePlex`, `FakeTuner`, `FakeLinkPhone`).

Other: `UITests/` (UI tests; `UITests/FakePlex/` fixtures and rules in its `README.md`), `Resources/` (`themes.json`, Manrope, licences), `tools/check_themes.py`, `project.yml` (XcodeGen; the `.xcodeproj` is not stored), `.github/workflows/ios.yml`.

## Data flow in one paragraph

`MarqueeApp` creates `ThemeStore` and `AppSession` and puts both in the environment. `AppSession.state` drives `RootView`: sign in (`PlexTV` PIN flow in a browser sheet, or a 4-character code at plex.tv/link), choose a server, then `MainTabs`. Choosing a server makes a `PlexServerConnection`, which probes addresses and yields a `PlexLibrary`; screens load through `Remote<Value>` and refresh on `LibraryChanges`. Playing something builds a `PlaybackRequest` for `PlayerModel`, which fetches metadata, creates a play queue, asks `PlaybackRouteDecider` for a route, and starts a direct, remux or transcode stream on a `VideoBackend`, reporting progress through `TimelineReporter`. Live TV goes through `LiveRouter`, which picks the direct tuner or Plex HLS.

## Where things are decided

| Question | File |
|---|---|
| What the app should do | `docs/behaviour-spec.md`, status per feature in `docs/PARITY.md` (counts: `grep -c '| Done |' docs/PARITY.md`) |
| Why it looks like this, tokens, screens | `docs/DESIGN.md` |
| Core public API | `docs/core-api.md` |
| Live TV decisions and tests | `docs/LIVE-TV.md` |
| What needs a real iPhone | `docs/DEVICE-TEST.md` |
| Design review findings | `docs/design-review-2026-11-07.md` |

## Test and build commands

- Theme gate (Python 3): `python3 -B tools/check_themes.py Resources/themes.json` must print `RESULT: PASS`.
- MarqueeCore on Linux, about 30 seconds, needs a Swift 6.2+ toolchain (swift.org tarball; Xcode is not needed): `swift test --build-system native --package-path Packages/MarqueeCore --scratch-path <dir>`. This is the check to run before pushing Core changes. Use `--filter` for one suite.
- MarqueeLive and the App cannot build on Linux (FFmpeg is iOS only). They build and test only in CI: push to `main`, then watch the run (`gh run list`, `gh run watch`).
- CI (`.github/workflows/ios.yml`, runner image `xcode-27`, Xcode 27.1, iPhone 18 Pro simulator on iOS 27.0), about 30 minutes end to end (it was about 80 when one runner did everything):
  - `core`: theme check and Core tests. `live`: Live engine tests on the simulator. `app`: XcodeGen and the unsigned Release IPA (an IPA under 6 MB fails the build).
  - `plan` then `ui` (matrix): `tools/ui-shards.py` lists every UI test in `UITests/*.swift` and splits them over 4 runners, one simulator each, balanced by measured seconds per test. A new test needs no listing; one that is not in the table in `tools/ui-shards.py` is counted as 120 s, so add its measured time after its first run. Each shard runs its tests with the standard screenshots, then (when the accessibility pass is on) the Increase Contrast and accessibility-text-size variants, and retries a failed test once. Two simulators on one runner was tried and is slower (tests about 2x slower, launch timeouts), so do not raise the per-runner count. The runner pool holds 4 concurrent xcode-27 jobs and `core`, `app` and `live` take slots early, so more than 4 shards just queue.
  - The accessibility pass runs on every push to `main`. On other branches it runs only when the branch differs from `main` in `App`, `UITests`, `Resources`, `Packages`, `project.yml`, `tools` or `.github`; otherwise it is skipped (`--no-accessibility`).
  - `ui-sizes`: one runner, the smallest and largest iPhone simulators selected by `tools/size-simulators.py`, one at a time. It covers the route menu, subtitle search and appearance, accessibility subtitle controls, and the alphabet rail; size-labelled shots land in `screens`.
  - `screens`: merges the shard artifacts `screens-N` into the one `screens` artifact. On a failed or cancelled run each UI job also uploads `UITests-logs-N` (the raw xcodebuild logs), `UITests-xcresult-N` (bundles whose xcodebuild exited on its own) and, best effort, `UITests-xcresult-interrupted-N` (bundles cut off by a cancel or timeout); `ui-sizes` uploads the same three with the suffix `sizes`.
  - `release` (`main` only) needs `core`, `live` and `app` to be green. Full UI and size checks continue independently; failures need a fix and a point release. The engine is `videoengine` pinned to exact 2.0.3 in `project.yml` and `Packages/MarqueeLive/Package.swift`; change both together.
- Video engine changes go upstream only: fix or improve `nphil/videoengine` on its own `main`, publish a tag through its release workflow (which also builds Stashy), then pin that tag here. Never patch or fork the engine inside this repo. Tell the Stashy session the new tag and what changed, so Stashy adopts it too.
- Running CI: batch the work. When a run fails, fix every failure on a branch and push the combined change once; do not push `main` a fix per failure, and do not push `main` while another `main` run is in progress (each run takes 4 runners). Rebase on `main` right before pushing.
- A UI change is reviewed from the `screens` artifact: dark, light and large-text screenshots must be checked for overlap and contrast. UI tests run against FakePlex.

## FakePlex and UI tests

Debug builds only (`#if DEBUG`). The UI tests set `MARQUEE_FAKE_PLEX` to `UITests/FakePlex/` and a request reads the matching JSON fixture (rules in `UITests/FakePlex/README.md`). Launch arguments such as `-marquee.fakeSignedIn YES`, `-marquee.fakeServerList`, `-marquee.uitest.play`, `-marquee.uitest.fakeTuner` set up a screen directly; `StillFrameBackend` stands in for AVPlayer because the simulator decodes no video. A new behaviour needs a fixture and a screenshot or assertion there, and an Increase Contrast / accessibility-size variant when it adds a screen.

## Release flow

Push to `main`. When `core`, `live` and `app` pass, `release` publishes `Marquee.ipa` as the next patch GitHub release and commits the new version to `apps.json`; full UI acceptance continues independently. Sideloaders update from `https://raw.githubusercontent.com/nphil/marquee-ios/main/apps.json`. There is no changelog file; each release’s notes name the commit it was built from, and `git log` is the history. Installing on the iPhone is Nitin’s action; state which release to install.
