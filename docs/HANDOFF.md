# Handoff: work in progress

The current state of unfinished work, for an agent picking it up without the conversation. Update it whenever the state changes; delete a section once its work has shipped.

## 0.1.31 player

Worktree `/tmp/cs/2407333fa292/batch`, branch `batch`; commits carry `[skip ci]`. Main owns integration, push and release: focused checks and build, the release, then the full GitHub suite and a point release if needed. Linux parses the Swift and runs the MarqueeCore tests; the app builds only in CI.

Done:

- Playback start and the still picture's controls (64483cf). A tap on a paused picture hides the controls and the next tap restores them; no timer hides them while paused; an automatic pause shows them; pinch works on a paused frame.
- Tracks and More menus. The subtitle choices stand on the Tracks menu, audio opens from one row and the tools (Search Subtitles, Subtitle Style, Subtitle Timing, Wrong Subtitles?) end it; the Subtitles sheet is gone. The More menu reads top down in three groups. `PlayerScreenshotTests` reaches the subtitle flows through the menu, finding rows by label.
- Video Orientation (Settings › Video & Playback): Follow Device (the default), Start in Landscape and Lock to Landscape, for the film and live players (`PlayerOrientation`; the rule is `OrientationHold` in Core, DESIGN §8.6). The player no longer turns the screen on its side as it opens: under Follow Device it opens the way the phone is held. `MarqueeApp` now adapts `AppDelegate`, which answers which ways the screen may turn; the downloads' background-launch handler in it was not reached before. iOS 27 deprecates that answer for `UIWindowSceneDelegate.supportedInterfaceOrientations(for:)`; it stays on the app delegate because the scene's delegate is SwiftUI's, and `PlayerOrientationTests` shows whether iOS 27 still asks it.

Outstanding, in order:

- Picture in Picture on a swipe Home during playback, from the player on its side and upright; inspect, fix only what is broken, name the paths that cannot offer it.
- ProMotion: inspect for frame-rate caps; note the result.

Unseen until CI and a phone: the shots `player-02-tracks-menu` and `player-03-more-menu`, and the migrated subtitle flows; `PlayerOrientationTests` (the setting's list in `video-orientation-01-choices` and `-02-chosen`, and the two settings that keep the player on its side) and the page in `acct-05-video`. The turns themselves, Portrait Orientation Lock included, are DEVICE-TEST check 18.

## Combined 0.1.30 batch

The complete batch is integrated on `main` for one unsigned Feather release. Branch commits use `[skip ci]`. The 0.1.31 release order above supersedes the previous full-suite pre-release gate.

Included: player controls and episode navigation; configurable tabs, alphabet rail and theme music; Seerr requests; durable downloads and offline playback; Live TV timeshift; unified subtitle controls, fonts and Bazarr/Plex search; optional remote mini bar/Home button with authenticated home presence; source/view-aware Auto quality, recovery and network invalidation; DVR recordings selected only from completed DVR-marked media across the full library.

The Home watchlist loads only while its shelf is shown; new subtitle requests scroll their progress into view. LumaRemoteKit retains the closing connection until the peer hangs up, bounded to five seconds, so the last pairing reply can finish delivery. The player's Tracks and More menus are UIKit menus, which report every open and close, so the controls fade again after a menu is dismissed. A download played from Settings › Downloads plays over the Settings sheet and closes back onto it. The Library and Home title menus are an explicit menu in the bar's title slot, as `toolbarTitleMenu` drew no menu in the inline-large bar.

Release review fixes: playback counts as home at a Plex-local address reached without relay or tunnel; the home-presence check stops after the encrypted handshake, so it never replaces the remote's session; a network change restarts playback only when the server address or place changes; the floor note no longer holds the controls; Up Next cannot outlive its episode. Downloads build their background path from path components, wait and retry on transient network errors, refuse an Original the phone cannot play, and auto-delete only titles finished on the phone. Recorded reads only the DVR's target libraries, once per load. Device acceptance of these remains outstanding.

The combined simulator run and screenshot review remain acceptance work, not a pre-release full-suite gate. Real-iPhone decoding, offline audio/subtitles, background downloads, watch-state reconciliation, tuner timeshift, network handovers and power/heat remain device checks; simulated playback is not acceptance evidence for these. Native picture scaling is retained because extra enhancement has no measured device benefit.

Double-tap only remains the default skip gesture. The server-side VMAF map and remuxed Picture in Picture LIVE-label change are deferred; the latter needs an upstream engine change (`docs/adaptive-playback.md`).

## Parked ideas

Not to be built until Nitin asks. Recorded so the design is not lost.

- **YouTube-style mini player.**
- **XR headset support.**
- **Touch-surface TV remote (LumaRemoteKit and the LumaTV phone-remote plugin).** Parked, not part of this release: a TV-themed touch surface with continuous scrolling, stable tap targets, thumb-engaged Core Motion assistance and TV-confirmed haptics. Investigate Wi-Fi Aware support in the LG radio, firmware and driver, plus the sideload signing entitlement, then compare against the existing encrypted UDP path. The proposed 20–40 ms touch-to-display target is unmeasured. Bluetooth LE is not inherently faster; its actual connection timing must be measured. The optional mini bar and automatic away hiding are separate, active release requirements.

## Standing rules (also in AGENTS.md)

- Video engine changes go upstream to `nphil/videoengine` and its release flow; inform both Stashy and Marquee of improvements and released tags. Both consumers currently pin exact 2.0.3.
- Clean room, real-server safety and token rules in AGENTS.md "Rules that bite" apply to every part.
- Nitin is not a programmer: report to him in plain words, briefly.
