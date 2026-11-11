# Handoff: work in progress

The current state of unfinished work, for an agent picking it up without the conversation. Update it whenever the state changes; delete a section once its work has shipped.

## 0.1.31 player

Shipped as 0.1.31 (14d0826) and 0.1.32 (ed15c7b). 0.1.32 stops the automatic intro skip from restarting its countdown: time read before the jump landed offered the intro again, so `skippedIntroEnd` holds the offer back until the picture reaches the intro's end (needs an iPhone check). Both full UI runs failed `testPlacesOffTheBar` in three themes, and the 0.1.32 run's recording showed why: the Library page drew no title at all, so its library menu was unreachable. Removing the system title (`toolbar(removing: .title)`, e9ff1f1) also removed the menu placed in the `.title` slot; the menu now sits at the bar's leading edge (next point release, unconfirmed until its run). `testUpNextCountsDownThenPlaysNext` failed once in that run and passed on its retry.

Done:

- Playback start and the still picture's controls (64483cf). A tap on a paused picture hides the controls and the next tap restores them; no timer hides them while paused; an automatic pause shows them; pinch works on a paused frame.
- Tracks and More menus. The subtitle choices stand on the Tracks menu, audio opens from one row and the tools (Search Subtitles, Subtitle Style, Subtitle Timing, Wrong Subtitles?) end it; the Subtitles sheet is gone. The More menu reads top down in three groups. `PlayerScreenshotTests` reaches the subtitle flows through the menu, finding rows by label.
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

Double-tap only remains the default skip gesture. The server-side VMAF map and remuxed Picture in Picture LIVE-label change are deferred; the latter needs an upstream engine change (`docs/adaptive-playback.md`).

## Parked ideas

Not to be built until Nitin asks. Recorded so the design is not lost.

- **YouTube-style mini player.**
- **XR headset support.** Deferred to 2026-11-11; no automatic start. Design-only clickable webpage for Viture XR Pro: all phone features, including Home, libraries, details, search, Seerr, downloads, Live TV/DVR and full player controls, scaled for a 1920×1080 glasses display with large type, safe margins, theme tokens and clear focus. Reuse Stashy’s glasses and external-display work. Pair it with an eyes-free phone touchpad: swipe/flick navigation, tap selection, back/options gestures, distinct haptics for movement, boundaries, selection and scrubbing, optional thumb-engaged motion assistance, and VoiceOver support. Show gesture/haptic maps; browser mockups cannot prove native haptics. Offer remembered XR mode on connection, open the remote while foreground, and replace the remote icon with a glasses icon. Implementation follows design approval, after 0.1.31.
- **Touch-surface TV remote (LumaRemoteKit and the LumaTV phone-remote plugin).** Parked, not part of this release: a TV-themed touch surface with continuous scrolling, stable tap targets, thumb-engaged Core Motion assistance and TV-confirmed haptics. Investigate Wi-Fi Aware support in the LG radio, firmware and driver, plus the sideload signing entitlement, then compare against the existing encrypted UDP path. The proposed 20–40 ms touch-to-display target is unmeasured. Bluetooth LE is not inherently faster; its actual connection timing must be measured. The optional mini bar and automatic away hiding are separate, active release requirements.

## Standing rules (also in AGENTS.md)

- Video engine changes go upstream to `nphil/videoengine` and its release flow; inform both Stashy and Marquee of improvements and released tags. Both consumers currently pin exact 2.0.3.
- Clean room, real-server safety and token rules in AGENTS.md "Rules that bite" apply to every part.
- Nitin is not a programmer: report to him in plain words, briefly.
