# Handoff: work in progress

The current state of unfinished work, for an agent picking it up without the conversation. Update it whenever the state changes; delete a section once its work has shipped.

## Batch for 0.1.30 (started 2026-11-09)

Nitin wants this whole batch to ship as ONE release, never piecemeal, and wants tokens spent carefully.

**Branching.** Work lands on the integration branch `batch`, not `main`: every push to `main` publishes a release. Each helper works on its own branch from `batch` and fast-forwards `batch` when done. Every commit on a non-`main` branch carries `[skip ci]` in its message (CI runs on every branch push). Nobody runs CI on a branch. When all parts are on `batch`, `main` is fast-forwarded to `batch` once; that `main` run is the single test, and its release job publishes only if every job passes. If it fails, every failure is fixed together on `batch` (or a branch from it) and `main` is pushed once more.

**Parts.** Each part has a branch named after its owner and a resume note at `docs/wip/<Owner>.md` on that branch (done, next, decisions). Continue from the note and the branch; do not restart a part.

| Owner | Scope |
|---|---|
| PlayerPolish | Done on `batch` (11462cb, 2b0b8ec): close button is an xmark; Skip Gesture setting, default Double-Tap only; format badge on first start; episodes panel (landscape side panel, season menu pinned in the header). |
| AppChrome | Done on `batch` (commit "AppChrome: customisable tab bar…"): Appearance › Tab Bar (switch and order tabs, at most 5, Home always, Search last) over the destination registry (Core `TabLayout`, `App/Navigation/Destinations.swift`); places off the bar keep a way in (Search beside Library's filter chip, Requests as + on Library, Live TV, Watchlist and Downloads in Library's title menu, Watchlist shelf on Home, bookmark menu on title pages); Show Scroll Bars; A–Z rail lens 3.6× left of the thumb with a letter callout; theme music on show pages, with volume (Video & Playback). Left: the registry calls Seerr's `RequestsView()` and `session.seerr.isEnabled` and Downloads' `DownloadsView()` and `session.downloads.activeCount`, so the app compiles only once both land (if Seerr misses this release, take `.requests` out of `Destination` and its hooks). When Downloads lands: a Settings › Downloads row (`settings.downloads` → `DownloadSettingsView()`), Go to Downloads in `DownloadButton`'s done menu, the §8.7 Downloads row in DESIGN. |
| Seerr | Seerr (Overseerr API v1) at the address the user enters (Nitin's is `https://request.nateshome.net`): discover, search, request, status, Play when available; Plex sign-in. Pulsarr also turns Watchlist adds into requests, so show "already requested". Tests use FakeSeerr only; never create a real request. |
| Streaming | Auto quality (adaptive, design in `docs/adaptive-playback.md`); home vs away detection that works with Tailscale always on (the phone's own network plus measured RTT and throughput). |
| Downloads | Download manager. Stashy's lessons apply (`/data/home/Stashy/docs/ENGINEERING_NOTES.md`): ONE connection by default (8-way measured slower against Nitin's server), 64 MB slices into a durable part file, one background range task, the audio keep-alive for background runtime (ON by default, Settings switch, idle while a video plays), strict free-space check. Quality: Original or a server transcode at the existing levels; the VMAF option is an interface only. |
| LiveTimeshift | Live TV Pause instead of Stop, buffering while paused, rewind within the buffer, LIVE to the live edge; Plex Live TV's own buffer on the Plex path, an app-side capped ring buffer on the LumaTuner path; buffers deleted on close, crash leftovers on next launch. The live player's close button becomes an xmark. |

**Decisions already made by Nitin.** The VMAF map server job is deferred. The Picture in Picture LIVE label on remuxed videos is deferred (needs a large engine change; design noted in `docs/adaptive-playback.md`). A YouTube-style mini player and XR headset support are parked. Double-tap only is the default skip gesture.

## Standing rules (also in AGENTS.md)

- Video engine changes go upstream to `nphil/stashy-videoengine` and its release flow; Marquee pins the tag; the Stashy Cody session is told the tag and the change.
- Clean room, real-server safety and token rules in AGENTS.md "Rules that bite" apply to every part.
- Nitin is not a programmer: report to him in plain words, briefly.
