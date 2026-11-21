# Handoff: work in progress

The current state of unfinished work, for an agent picking it up without the conversation. Update it whenever the state changes; delete a section once its work has shipped.

The canonical request list and implementation order are in [PLAN.md](PLAN.md). It separates released code from hardware acceptance and retains every request without rebuilding shipped features.

## Latest release: 0.1.45

Published from `ddce805`, with the Feather source updated in `a3bb9e8`; it adds diagnostic logs (below). Software HDMI volume shipped in 0.1.42; the remote exit/Settings strip and continuous page/grid touchpad shipped in 0.1.44. These still need DEVICE-TEST checks 24, 27 and 28, including the Apple TV Remote comparison.

Run `44225884414` (0.1.45): App, Core, Live engine and Release passed. Its UI failures `testStyleMenuLandscape` (N3) and "Episode 3 is not playing" in `testUpNext`, `testUpNextCountsDownThenPlaysNext` and `testSkipCreditsInstantly` (N4) also failed before 0.1.45; `testDirectPlayerRosePine` failed at its controls coming back, and at another step in run `43562385063`. Read their artifacts before changing code or assertions; do not classify them as harmless flakes without evidence.

## Diagnostic logs: released in 0.1.45

Settings › Integrations › Diagnostic Logs sends the app's log to the write-only ntfy topic `marquee-logs` (DESIGN §8.12); AGENTS.md says how to read it. 0.1.45 crashes on opening Report a Problem; `09bfb76` fixes it for the next release. The skip-intro miss is not yet explained: the next `offers skip.missed` line carries the seekable range, the remux's written time and the item time. DEVICE-TEST check 29 is open.

## Next build: profile settings close button

Replace the profile Settings screen's Done button with an X matching the profile button's size and alignment, so closing the screen collapses cleanly back into the profile icon. Check the return animation as well as the icon at rest.

## Away from home

A server conversion asks Plex's decision first, as PMS 1.43.5 refused the start of a player's later sessions without one; the player gives the stream 30 s to be ready, tries twice more on a new session with the addresses probed again, then shows the error with Retry. Ending a conversion also reports its playback stopped. Downloads report an address that stops answering, so the next transfer probes again; on cellular only with cellular downloads off a row says Waiting for Wi-Fi and offers Download on Cellular; after two failed tries a row says the server can't be reached while it keeps trying.

A conversion the server loses mid-play (Plex ends idle sessions, so a long pause leaves 404s) is started again at the playhead within seconds, not after AVPlayer's 30 s of retries. For a file that needs the remux, the measured link to the server, not the place, decides whether the phone reads it itself (DESIGN §8.6, `RouteReach`). DEVICE-TEST checks 31 and 32 are open.

Released in the fix batch. DEVICE-TEST check 20 remains open; this handoff does not establish the latest result of `DownloadFlowTests.testWaitingForWiFi`.

## Quality downloads: released in 0.1.41

Integrated on `main` in `9957904`, with the actor-isolation fix in `94731c4`. The Download menu offers Original, High, Medium and Low, each with its resolution and size. Tiers aim at VMAF 95, 90 and 85, from HomeLabber's map when available, otherwise estimated. Conversion and segment downloading overlap; the app joins segments into `media.ts`, preserves saved work across resume and uses the download queue when the server will not stream it.

HomeLabber 1.29.0 (`c43d38d`) is deployed and enabled. On Nov 15, live inspection found 74 measured titles, 693 of 4,814 covered through season borrowing, no failed titles and active progress on Dredd. The Marquee key had been accepted that day. The window is 01:00–06:00 UTC, not local time. DEVICE-TEST check 25 remains open: real Plex/background transfers, conversion-session cleanup, resume continuity, the estimated 4K HEVC tier and offline playback of the joined file. The completed map is not required before using measured titles.

## XR glasses and TV: released

The XR glasses plugin shipped in 0.1.36; wired TV mode shipped in 0.1.38. Both are on `main`, off until Settings › XR Glasses & TV enables them. The glasses have a dedicated 1920 × 1080 screen and eyes-free phone remote; a TV on USB-C/HDMI uses the display's aspect and pixels, 5 % margins and the theme's dark canvas. The plugin remembers display choices, with a manual type override for displays sharing a resolution/refresh fingerprint. AirPlay mirroring is not claimed.

- Core (`Packages/MarqueeCore/Sources/MarqueeCore/Glasses`): focus grid, swipe steps and coasting, scrub detents, tilt drive, haptic cues, the "When Glasses Connect" choice and the search letter board, with tests.
- App (`App/Glasses`): `GlassesCenter` (plugin state, connection, the first-connection question), `GlassesScene` (the external-display scene and the black glasses theme), `GlassesNavigator` (pages over the session's own library, Seerr, downloads and Live TV), `GlassesViews` and `GlassesPlayerView`, `GlassesRemote` (the takeover window, touch surface, Core Haptics and Core Motion), `GlassesSettingsView`. `project.yml` adds multiple scenes and the `UIWindowSceneSessionRoleExternalDisplayNonInteractive` configuration.
- UI tests: `GlassesScreenshotTests` stands the glasses in with `-marquee.uitest.glasses ask|remote|phone|canvas` and opens a glasses page with `-marquee.uitest.glassesPage`. The glasses' screenshots are saved upright at 1920 × 1080 (`glasses-*`); the phone's are `glasses-phone-*`.

Not proven on hardware: DEVICE-TEST checks 21–23, including the external-display scene, Mirror/plugin-off behavior, tilt and haptic feel, brightness restoration, optical legibility, display identification and HDR. The current feature coverage is described in DESIGN §8.9; PLAN task D10 keeps the full phone-feature parity request open until gaps are checked.

## Linked phones: released

Linked Phones shipped in 0.1.38 and is on `main`, off until enabled. One-time QR pairing lets either iPhone control the other, including TV/XR navigation and phone playback. Peer-to-peer Wi-Fi support shipped in 0.1.39: neither phone needs to join hotel Wi-Fi, but both Wi-Fi radios must remain enabled. Nitin reported successful initial pairing; that is not acceptance of every reconnection or remote-control case.

- Core (`Packages/MarqueeCore/Sources/MarqueeCore/Link`): the code's link, HKDF keys, the wire messages, status pacing and the dialing rules, with `LinkTests`. On Linux the Core builds against swift-crypto for CryptoKit (`Package.swift`).
- App (`App/Link`): `PhoneLink` (plugin state, linking, Bonjour advertising and browsing, connections, status), `LinkNetwork` (Network.framework connections around LumaRemoteCore's Noise handshake and sealed frames), `LinkStore` (the id and keys in the Keychain), `LinkHost` (status from the session; inputs to the glasses navigator, commands to the player), `LinkController` (the controlling phone's window: `GlassesRemoteView` through the `RemoteTarget` protocol, or the player controls), `LinkSettingsView`, `LinkScanView`.
- UI tests: `LinkScreenshotTests` and `LinkAccessibilityScreenshots`; `FakeLinkPhone` stands in for the other phone (`-marquee.uitest.linkPeer tv|glasses|phone|idle`) and `-marquee.uitest.linkScan YES` for the camera.

TV/glasses status and symbols follow the connected display type. DEVICE-TEST checks 24 and 26 remain open for permissions, shared/direct-link discovery, lock/network reconnection, unlinking, haptics and software volume. HDMI uses playback attenuation rather than the host's ineffective physical volume buttons; Dolby/Atmos and Live TV behavior still need hardware proof. Check 28 covers local and linked touchpad smoothness and delay.

## 0.1.36

Shipped 0.1.35 (fix batch) and 0.1.36 (`920da41`, XR plugin). The subtitle-search tests passed in 0.1.36. Historical badge/style assertions were changed afterward; that does not close the current style failure listed under 0.1.44. `testAutoBuffersInsteadOfDroppingBelowPictureFloor` once failed with controls not returning; inspect a recurrence rather than assuming it has the same cause.

## 0.1.31 player

Shipped as 0.1.31 (14d0826), 0.1.32 (ed15c7b) and 0.1.33 (b2d6073). 0.1.32 stops the automatic intro skip from restarting its countdown: time read before the jump landed offered the intro again, so `skippedIntroEnd` holds the offer back until the picture reaches the intro's end (needs an iPhone check). 0.1.31 and 0.1.32 drew no Library title: `toolbar(removing: .title)` (e9ff1f1) also removed the menu in the `.title` slot. 0.1.33 puts the menu at `.topBarLeading`, and `testPlacesOffTheBar` passes in all three themes, but the screenshots (`browse-02-library-*`, `places-02-library-menu-*`) show the title twice: the system's large "Movies" at the leading edge and the "Movies ⌄" menu beside it. So `toolbar(removing: .title)` does not hide the `navigationTitle` set inside `SectionBrowser`. Once scrolled, only the menu shows. 0.1.34 (4820f80) hides it with an inline bar whose principal slot is empty (`TitleMenu`); Home and Library set inline-large only on paths without the menu. Its `browse-02-library-rose-pine` and `header-blur-04-library-scrolled-rose-pine` shots show the title once. 0.1.33's run: `testSkipIntroCountsDownThenSkips` and `testHomeRowsDawn` each failed once and passed on retry; shard 2 then went red only because its simulator had shut down before the accessibility pass (CoreSimulator code 405).

Done:

- Playback start and the still picture's controls (64483cf). A tap on a paused picture hides the controls and the next tap restores them; no timer hides them while paused; an automatic pause shows them; pinch works on a paused frame.
- Tracks and More menus. Subtitles are Off or the viewer's language (its usual track), then Find Subtitles, Subtitle Style (a submenu that stays up while choices apply) and Subtitle Timing, all in the Tracks menu with no sheet; audio opens from one row. Find Subtitles asks Bazarr for up to 20 s and Plex's agents by themselves after, with a status banner over the picture. The More menu reads top down in three groups. `PlayerScreenshotTests` reaches the subtitle flows through the menu, finding rows by label.
- Video Orientation (Settings › Video & Playback): Follow Device (the default), Start in Landscape and Lock to Landscape, for the film and live players (`PlayerOrientation`; the rule is `OrientationHold` in Core, DESIGN §8.6). The player no longer turns the screen on its side as it opens: under Follow Device it opens the way the phone is held. `MarqueeApp` now adapts `AppDelegate`, which answers which ways the screen may turn; the downloads' background-launch handler in it was not reached before. iOS 27 deprecates that answer for `UIWindowSceneDelegate.supportedInterfaceOrientations(for:)`; it stays on the app delegate because the scene's delegate is SwiftUI's, and `PlayerOrientationTests` shows whether iOS 27 still asks it.
- Picture in Picture on leaving the app while it plays, the player upright or on its side (DESIGN §8.6). The film player and Live TV read from the tuner had it; Live TV through Plex now has it too, with the film player's `PictureInPicture` on its own layer (`PlexLiveSource`): the window's pause and play are taken as the viewer's, and closing the window away from the app ends the tune. No window for a Chromecast or AirPlay video, where the picture is on the receiver.
- ProMotion: no artificial phone-playback cap was found, but smoothness remains DEVICE-TEST check 19. The later external-display touchpad uses its own display-paced updates; that is not evidence of phone playback smoothness.

The 0.1.31 implementation is released; hardware acceptance and the newer failures above remain open.

Unseen until CI and a phone: the shots `player-02-tracks-menu` and `player-03-more-menu`, and the migrated subtitle flows; `PlayerOrientationTests` (the setting's list in `video-orientation-01-choices` and `-02-chosen`, and the two settings that keep the player on its side) and the page in `acct-05-video`. The turns themselves, Portrait Orientation Lock included, are DEVICE-TEST check 18. The simulator plays no video, so Picture in Picture is seen only on a phone: DEVICE-TEST check 7 and LIVE-TV LT10. If a swipe Home leaves sound alone there, the first thing to look at is whether the window's start reaches the app before the background notification, which is what keeps the picture attached (`enteredBackground` in `PlayerModel` and `PlexLiveSource`).

## Combined 0.1.30 batch

The complete batch is integrated on `main` for one unsigned Feather release. Branch commits use `[skip ci]`. The 0.1.31 release order above supersedes the previous full-suite pre-release gate.

Included: player controls and episode navigation; configurable tabs, alphabet rail and theme music; Seerr requests; durable downloads and offline playback; Live TV timeshift; unified subtitle controls, fonts and Bazarr/Plex search; optional remote mini bar/Home button with authenticated home presence; source/view-aware Auto quality, recovery and network invalidation; DVR recordings selected only from completed DVR-marked media across the full library.

The Home watchlist loads only while its shelf is shown; new subtitle requests scroll their progress into view. LumaRemoteKit retains the closing connection until the peer hangs up, bounded to five seconds, so the last pairing reply can finish delivery. The player's Tracks and More menus are UIKit menus, which report every open and close, so the controls fade again after a menu is dismissed. A download played from Settings › Downloads plays over the Settings sheet and closes back onto it. The Library and Home title menus are an explicit menu at the bar's leading edge, as `toolbarTitleMenu` drew no menu in the inline-large bar.

Release review fixes: playback counts as home at a Plex-local address reached without relay or tunnel; the home-presence check stops after the encrypted handshake, so it never replaces the remote's session; a network change restarts playback only when the server address or place changes; the floor note no longer holds the controls; Up Next cannot outlive its episode. Downloads build their background path from path components, wait and retry on transient network errors, refuse an Original the phone cannot play, and auto-delete only titles finished on the phone. Recorded reads only the DVR's target libraries, once per load. Device acceptance of these remains outstanding.

The combined simulator run and screenshot review remain acceptance work, not a pre-release full-suite gate. Real-iPhone decoding, offline audio/subtitles, background downloads, watch-state reconciliation, tuner timeshift, network handovers and power/heat remain device checks; simulated playback is not acceptance evidence for these. Native picture scaling is retained because extra enhancement has no measured device benefit.

Double-tap only remains the default skip gesture. The remuxed Picture in Picture LIVE-label change is deferred; it needs an upstream engine change (`docs/adaptive-playback.md`).

## Parked ideas

The complete backlog and acceptance criteria are maintained once in [PLAN.md](PLAN.md):

- Network-aware VMAF streaming: S1–S7, preserving picture quality and using quiet, Wi-Fi/cellular-aware measurements. Planned, not started.
- Browser-viewable XR mockups: L1, delivery unconfirmed; no screenshot approval gate before an XR release.
- YouTube-style mini player: L2.
- Feel-your-way LG TV remote: L3, separate from linked iPhones.
- Remux Picture in Picture LIVE-label/scrubber limitation: L4, an upstream VideoEngine dependency.

## Standing rules (also in AGENTS.md)

- Video engine changes go upstream to `nphil/videoengine` and its release flow; inform both Stashy and Marquee of improvements and released tags. Marquee pins exact 2.0.4; Stashy pinned 2.0.3 when 2.0.4 was released.
- Clean room, real-server safety and token rules in AGENTS.md "Rules that bite" apply to every part.
- Nitin is not a programmer: report to him in plain words, briefly.
