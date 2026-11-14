# Handoff: work in progress

The current state of unfinished work, for an agent picking it up without the conversation. Update it whenever the state changes; delete a section once its work has shipped.

## Away from home

A server conversion asks Plex's decision first, as PMS 1.43.5 refused the start of a player's later sessions without one; the player gives the stream 30 s to be ready, tries twice more on a new session with the addresses probed again, then shows the error with Retry. Ending a conversion also reports its playback stopped. Downloads report an address that stops answering, so the next transfer probes again; on cellular only with cellular downloads off a row says Waiting for Wi-Fi and offers Download on Cellular; after two failed tries a row says the server can't be reached while it keeps trying.

Unseen until CI: `DownloadFlowTests.testWaitingForWiFi` and its shot `downloads-waiting-wifi-dark`. On a phone: DEVICE-TEST check 20.

## Quality downloads (branch `quality-downloads`)

Built on branch `quality-downloads`, not yet on `main`. The Download menu offers Original, High, Medium and Low, each with its picture and download size; the tiers aim at VMAF 95, 90 and 85 (Core `DownloadQualityPlan`), measured by HomeLabber's quality map when its plugin is set up (Settings › Integrations › HomeLabber Quality Map), else estimated. A tier is converted while it downloads: the app saves the server's HLS segments into one `media.ts` (Core `StreamedFile`), hands up to 400 segments to iOS in the background, starts a new session where the saved segments end after a pause, a kill or an expired session, and falls back to the download queue when the server will not stream it. HomeLabber's side is its `media-quality` branch.

Unseen until CI: the app build, `DownloadFlowTests.testStreamedDownload` with its shots `downloads-quality-menu-dark` and `downloads-streamed-dark`, and the settings flow's `acct-09c-homelabber-*`. On a phone and the real server: DEVICE-TEST check 25, in particular segment order in the background, the transcoder's throttle and idle reaping for a session that only downloads, the splice at a resume, a 4K HEVC tier, and offline playback of the joined file.

## XR glasses and TV (branch `xr`, TV mode on `tv-mode`)

Built on branch `xr`, not yet on `main`. The XR glasses plugin (DESIGN §8.9) gives glasses that connect as a display (Viture Pro) Marquee's own 1920 × 1080 screen and makes the phone an eyes-free remote. It is off until Settings › XR Glasses & TV turns it on. TV mode (branch `tv-mode`, not yet on `main`) lets a TV on USB-C video out or HDMI use the same screen and remote: Core `BigScreen` (display kinds, per-display answers, the layout: 5 % margins and the display's aspect on a TV), `GlassesCenter` decides each display from its kept answer, `BigScreenMetrics` in the environment replaces the fixed canvas size and margins, the TV's own screen decides HDR in `PlaybackCapabilities`, and `GlassesInput` is the one input hook. UI tests `tv-*` and `tv-phone-*`; device check 23. Untested: everything on a real TV, a disabled scene registration handing the display back to iOS for Mirror, and AirPlay.

- Core (`Packages/MarqueeCore/Sources/MarqueeCore/Glasses`): focus grid, swipe steps and coasting, scrub detents, tilt drive, haptic cues, the "When Glasses Connect" choice and the search letter board, with tests.
- App (`App/Glasses`): `GlassesCenter` (plugin state, connection, the first-connection question), `GlassesScene` (the external-display scene and the black glasses theme), `GlassesNavigator` (pages over the session's own library, Seerr, downloads and Live TV), `GlassesViews` and `GlassesPlayerView`, `GlassesRemote` (the takeover window, touch surface, Core Haptics and Core Motion), `GlassesSettingsView`. `project.yml` adds multiple scenes and the `UIWindowSceneSessionRoleExternalDisplayNonInteractive` configuration.
- UI tests: `GlassesScreenshotTests` stands the glasses in with `-marquee.uitest.glasses ask|remote|phone|canvas` and opens a glasses page with `-marquee.uitest.glassesPage`. The glasses' screenshots are saved upright at 1920 × 1080 (`glasses-*`); the phone's are `glasses-phone-*`.

Not proven on hardware: device checks 21 and 22 (DEVICE-TEST). In particular the Viture's scene connecting with the non-interactive external-display role, the tilt direction and feel, the haptics' feel, the brightness dim and restore, legibility through the birdbath, and HDR on the glasses (playback capabilities are read from the phone's screen). Next: those checks on an iPhone with the glasses, then merge to `main`.

## Linked phones (branch `phone-link`)

Built on branch `phone-link`, not yet on `main`. Linked Phones (DESIGN §8.10) lets one iPhone with Marquee control another: the eyes-free remote while the other drives a TV or XR glasses, a few player controls while it plays on its own screen. It is off until Settings › Linked Phones turns it on.

- Core (`Packages/MarqueeCore/Sources/MarqueeCore/Link`): the code's link, HKDF keys, the wire messages, status pacing and the dialing rules, with `LinkTests`. On Linux the Core builds against swift-crypto for CryptoKit (`Package.swift`).
- App (`App/Link`): `PhoneLink` (plugin state, linking, Bonjour advertising and browsing, connections, status), `LinkNetwork` (Network.framework connections around LumaRemoteCore's Noise handshake and sealed frames), `LinkStore` (the id and keys in the Keychain), `LinkHost` (status from the session; inputs to the glasses navigator, commands to the player), `LinkController` (the controlling phone's window: `GlassesRemoteView` through the `RemoteTarget` protocol, or the player controls), `LinkSettingsView`, `LinkScanView`.
- UI tests: `LinkScreenshotTests` and `LinkAccessibilityScreenshots`; `FakeLinkPhone` stands in for the other phone (`-marquee.uitest.linkPeer tv|glasses|phone|idle`) and `-marquee.uitest.linkScan YES` for the camera.

On merging with `tv-mode`: `LinkHost` reports `.glasses` for any big screen and `GlassesNavigator.symbol` is always `eyeglasses`; both should follow the connected display's kind. Not proven on hardware: device check 24 (DEVICE-TEST), in particular Bonjour discovery and the Local Network prompt, camera reading, finding each other again after a lock or a Wi-Fi change, the delay and feel of haptics over the network, and an unlink reaching the other phone. Unseen until CI: the app build and the `link-*` shots.

## 0.1.36

Shipped 0.1.35 (fix batch) and 0.1.36 (920da41, XR glasses plugin, off until enabled). 0.1.36's run: the subtitle-search tests pass; `testFormatBadgeShowsOnFirstStart` and `testStyleMenuLandscape` (smallest phone) failed on coordinate-fragile assertions (the recording shows the badge in the top trailing corner), relaxed in the next commit, which is unverified until a run. `testAutoBuffersInsteadOfDroppingBelowPictureFloor` failed once ("controls did not come back"); watch for a repeat.

## 0.1.31 player

Shipped as 0.1.31 (14d0826), 0.1.32 (ed15c7b) and 0.1.33 (b2d6073). 0.1.32 stops the automatic intro skip from restarting its countdown: time read before the jump landed offered the intro again, so `skippedIntroEnd` holds the offer back until the picture reaches the intro's end (needs an iPhone check). 0.1.31 and 0.1.32 drew no Library title: `toolbar(removing: .title)` (e9ff1f1) also removed the menu in the `.title` slot. 0.1.33 puts the menu at `.topBarLeading`, and `testPlacesOffTheBar` passes in all three themes, but the screenshots (`browse-02-library-*`, `places-02-library-menu-*`) show the title twice: the system's large "Movies" at the leading edge and the "Movies ⌄" menu beside it. So `toolbar(removing: .title)` does not hide the `navigationTitle` set inside `SectionBrowser`. Once scrolled, only the menu shows. 0.1.34 (4820f80) hides it with an inline bar whose principal slot is empty (`TitleMenu`); Home and Library set inline-large only on paths without the menu. Its `browse-02-library-rose-pine` and `header-blur-04-library-scrolled-rose-pine` shots show the title once. 0.1.33's run: `testSkipIntroCountsDownThenSkips` and `testHomeRowsDawn` each failed once and passed on retry; shard 2 then went red only because its simulator had shut down before the accessibility pass (CoreSimulator code 405).

Done:

- Playback start and the still picture's controls (64483cf). A tap on a paused picture hides the controls and the next tap restores them; no timer hides them while paused; an automatic pause shows them; pinch works on a paused frame.
- Tracks and More menus. Subtitles are Off or the viewer's language (its usual track), then Find Subtitles, Subtitle Style (a submenu that stays up while choices apply) and Subtitle Timing, all in the Tracks menu with no sheet; audio opens from one row. Find Subtitles asks Bazarr for up to 20 s and Plex's agents by themselves after, with a status banner over the picture. The More menu reads top down in three groups. `PlayerScreenshotTests` reaches the subtitle flows through the menu, finding rows by label.
- Video Orientation (Settings › Video & Playback): Follow Device (the default), Start in Landscape and Lock to Landscape, for the film and live players (`PlayerOrientation`; the rule is `OrientationHold` in Core, DESIGN §8.6). The player no longer turns the screen on its side as it opens: under Follow Device it opens the way the phone is held. `MarqueeApp` now adapts `AppDelegate`, which answers which ways the screen may turn; the downloads' background-launch handler in it was not reached before. iOS 27 deprecates that answer for `UIWindowSceneDelegate.supportedInterfaceOrientations(for:)`; it stays on the app delegate because the scene's delegate is SwiftUI's, and `PlayerOrientationTests` shows whether iOS 27 still asks it.
- Picture in Picture on leaving the app while it plays, the player upright or on its side (DESIGN §8.6). The film player and Live TV read from the tuner had it; Live TV through Plex now has it too, with the film player's `PictureInPicture` on its own layer (`PlexLiveSource`): the window's pause and play are taken as the viewer's, and closing the window away from the app ends the tune. No window for a Chromecast or AirPlay video, where the picture is on the receiver.
- ProMotion: no frame-rate cap found, nothing changed (DESIGN §9, Frame rate). `CADisableMinimumFrameDurationOnPhone` is set, the app holds no display link or frame-rate range, and iOS paces the picture on every path. Smoothness itself is DEVICE-TEST check 19.

Nothing is outstanding in the code.

Unseen until CI and a phone: the shots `player-02-tracks-menu` and `player-03-more-menu`, and the migrated subtitle flows; `PlayerOrientationTests` (the setting's list in `video-orientation-01-choices` and `-02-chosen`, and the two settings that keep the player on its side) and the page in `acct-05-video`. The turns themselves, Portrait Orientation Lock included, are DEVICE-TEST check 18. The simulator plays no video, so Picture in Picture is seen only on a phone: DEVICE-TEST check 7 and LIVE-TV LT10. If a swipe Home leaves sound alone there, the first thing to look at is whether the window's start reaches the app before the background notification, which is what keeps the picture attached (`enteredBackground` in `PlayerModel` and `PlexLiveSource`).

## Combined 0.1.30 batch

The complete batch is integrated on `main` for one unsigned Feather release. Branch commits use `[skip ci]`. The 0.1.31 release order above supersedes the previous full-suite pre-release gate.

Included: player controls and episode navigation; configurable tabs, alphabet rail and theme music; Seerr requests; durable downloads and offline playback; Live TV timeshift; unified subtitle controls, fonts and Bazarr/Plex search; optional remote mini bar/Home button with authenticated home presence; source/view-aware Auto quality, recovery and network invalidation; DVR recordings selected only from completed DVR-marked media across the full library.

The Home watchlist loads only while its shelf is shown; new subtitle requests scroll their progress into view. LumaRemoteKit retains the closing connection until the peer hangs up, bounded to five seconds, so the last pairing reply can finish delivery. The player's Tracks and More menus are UIKit menus, which report every open and close, so the controls fade again after a menu is dismissed. A download played from Settings › Downloads plays over the Settings sheet and closes back onto it. The Library and Home title menus are an explicit menu at the bar's leading edge, as `toolbarTitleMenu` drew no menu in the inline-large bar.

Release review fixes: playback counts as home at a Plex-local address reached without relay or tunnel; the home-presence check stops after the encrypted handshake, so it never replaces the remote's session; a network change restarts playback only when the server address or place changes; the floor note no longer holds the controls; Up Next cannot outlive its episode. Downloads build their background path from path components, wait and retry on transient network errors, refuse an Original the phone cannot play, and auto-delete only titles finished on the phone. Recorded reads only the DVR's target libraries, once per load. Device acceptance of these remains outstanding.

The combined simulator run and screenshot review remain acceptance work, not a pre-release full-suite gate. Real-iPhone decoding, offline audio/subtitles, background downloads, watch-state reconciliation, tuner timeshift, network handovers and power/heat remain device checks; simulated playback is not acceptance evidence for these. Native picture scaling is retained because extra enhancement has no measured device benefit.

Double-tap only remains the default skip gesture. The remuxed Picture in Picture LIVE-label change is deferred; it needs an upstream engine change (`docs/adaptive-playback.md`).

## Parked ideas

Not to be built until Nitin asks. Recorded so the design is not lost.

- **YouTube-style mini player.**
- **Touch-surface TV remote (LumaRemoteKit and the LumaTV phone-remote plugin).** Parked, not part of this release: a TV-themed touch surface with continuous scrolling, stable tap targets, thumb-engaged Core Motion assistance and TV-confirmed haptics. Investigate Wi-Fi Aware support in the LG radio, firmware and driver, plus the sideload signing entitlement, then compare against the existing encrypted UDP path. The proposed 20–40 ms touch-to-display target is unmeasured. Bluetooth LE is not inherently faster; its actual connection timing must be measured. The optional mini bar and automatic away hiding are separate, active release requirements.

## Standing rules (also in AGENTS.md)

- Video engine changes go upstream to `nphil/videoengine` and its release flow; inform both Stashy and Marquee of improvements and released tags. Both consumers currently pin exact 2.0.3.
- Clean room, real-server safety and token rules in AGENTS.md "Rules that bite" apply to every part.
- Nitin is not a programmer: report to him in plain words, briefly.
