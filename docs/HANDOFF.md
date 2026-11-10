# Handoff: work in progress

The current state of unfinished work, for an agent picking it up without the conversation. Update it whenever the state changes; delete a section once its work has shipped.

## Combined 0.1.30 release gate

The complete batch is integrated on `main` for one unsigned Feather release. Release remains gated by Core, Live engine, App, all four UI shards and the smallest/largest-phone UI run. No partial release is authorised. Failed jobs must be fixed together before another `main` push; branch commits use `[skip ci]`.

Included: player controls and episode navigation; configurable tabs, alphabet rail and theme music; Seerr requests; durable downloads and offline playback; Live TV timeshift; unified subtitle controls, fonts and Bazarr/Plex search; optional remote mini bar/Home button with authenticated home presence; source/view-aware Auto quality, recovery and network invalidation; DVR recordings selected only from completed DVR-marked media across the full library.

The combined simulator run and screenshot review remain required. Real-iPhone decoding, offline audio/subtitles, background downloads, watch-state reconciliation, tuner timeshift, network handovers and power/heat remain device checks; simulated playback is not acceptance evidence for these. Native picture scaling is retained because extra enhancement has no measured device benefit.

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
