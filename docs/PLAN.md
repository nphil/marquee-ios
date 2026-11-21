# Marquee feature backlog and implementation plan

Scope: the Marquee iPhone, XR glasses, wired-TV, remote and HomeLabber quality-map requests in this conversation. Status reconciled on 2026-11-16 against released main `964dd90` (0.1.44), the request history and the live HomeLabber inspection. Planning only; this document does not start feature implementation.

`Released` means included in a published unsigned IPA, not accepted on hardware. `Check` means implementation exists but the requested result still needs evidence. `Build` means implementation remains. `Later` preserves a deferred request. `Unconfirmed` means no delivery receipt was found. The broader implemented app inventory remains in [PARITY.md](PARITY.md); hardware procedures remain in [DEVICE-TEST.md](DEVICE-TEST.md).

## 1. Now: next point release

- [ ] **N1 — Profile close control (R09).** Replace Settings' Done with an X matching the profile button's visible size and corresponding position. Keep an accessible touch target and Close label. Reuse the existing sheet zoom and theme tokens. Done: opening, button close and swipe close return to a complete circular avatar without a clipped frame, including Reduce Motion and larger text.
- [ ] **N2 — Avatar clipping (R07–R08).** Recheck both the idle icon and dismissal; the previous size/shape changes are not hardware acceptance. Correct any remaining shared sizing or transition-source problem, not another device-specific offset. Done: receipt from the actual iPhone, with no clipped ring or photo before, during or after dismissal.
- [ ] **N3 — Subtitle style acceptance (R11).** Diagnose `testStyleMenuLandscape` from the latest available failure recording before changing code or assertions. Keep every in-player style choice inside the controls, never a full-screen sheet. Done: the actual menu is usable in small-phone landscape and the specific checks pass without weakening the visible contract.
- [ ] **N4 — Binge playback acceptance (R31–R33).** Diagnose `testSkipCreditsInstantly` and review any current Up Next failure; neither is presumed harmless or pre-existing. Done: autoplay off, configured countdown, instant skip, Watch Credits and natural episode end behave correctly, without duplicate advances or a restarted timer.
- [ ] **N5 — Current CI baseline.** Separate the simulator boot failure from product failures in run [43566194650](https://github.com/nphil/marquee-ios/actions/runs/43566194650). App, Core, Live engine and Release passed; four UI jobs failed, including one at simulator boot. Done: every genuine failure is fixed in one combined push and any remaining infrastructure failure is named, not hidden by retries.
- [ ] **N6 — Diagnostic logs acceptance (R46).** DEVICE-TEST check 29 on the iPhone, then read the first `offers skip.missed` from the live log. Done: live batches and both report paths arrive on the real server, and the skip-intro miss is explained or ruled out from its log line.
- [ ] **N7 — Chapter markers acceptance (R47).** Play The Apothecary Diaries S2 E10 and E11 on the iPhone. Done: Up Next appears as each Ending chapter starts (22:15), Skip Intro runs to 1:30, and the log's `offers markers` line shows them tagged `chapter`.
- [ ] **N8 — Home at launch acceptance (R48).** DEVICE-TEST check 30 on the iPhone. Done: Home shows the last titles and artwork on the first frame of a relaunch, online and offline, refreshes without a jump, and a second profile never sees the first's Home; the `load.cached` and `load.ok` times are recorded.
- [ ] **N9 — Rewatch acceptance (R49).** On the iPhone, with a show watched through whose latest view is a finished episode, not one part-way (Plex lists those itself): Community between episodes, or My Hero Academia S4 E14. Done: Home shows the next episode as an ordinary card, without a progress bar, that plays from the start; Remove from Continue Watching hides it with Undo until the show is viewed again; the show's page offers the same episode as Play; the cached first paint and the Glasses Home show the same card. The `rewatch` log line's `ms` is recorded.
- [ ] **N10 — Lost conversion acceptance (R50).** DEVICE-TEST check 31 on the iPhone. Done: a converted title paused for four minutes plays again within about 5 s of Play, not 30 s; the log shows `conversion.lost` (`cause`, `missed`, `ahead`), then `conversion.restart` or `conversion.switched`; no error shows. A 404 cannot be forced on demand, so which of the two lines appeared is recorded.
- [ ] **N11 — Measured link acceptance (R51).** DEVICE-TEST check 32 on the iPhone, with Isabel's server (DMZ VLAN through Tailscale) and an MKV that needs the remux. Done: the second start reads Route "Repackaged on the phone", Why "MKV file, Server at N Mbps, fast enough for the original", the `route` log line's `reach` says "near by link", and a remote quality limit set on the server keeps the stream there (`route.server-limit held`). Cellular, the relay and a direct public address stay untested.
- [ ] **N12 — Offers keep up, skips land first time (R52).** On the iPhone, with auto-skip on, let the countdown skip intros on three episodes in a row, the later ones started by Up Next, one of them repackaged on the phone; tap the picture after each skip. Done: the Skip Intro pill fades out once the skip lands and the controls draw when brought back; the log's `ui offer.view offer=none` follows each `offers skip`, and `skip.landed` reads `retried=no`.
- [ ] **N13 — Continue Watching follows playback (R53).** On the iPhone, play two episodes of a show in a row, then go back to Home, once closing the player and once closing Picture in Picture from the Home Screen. Done: the row shows the episode and place last played within a few seconds, without pulling to refresh; the log has `player server.stopped ok=yes` for each close.
- [ ] **N14 — Subtitles on time in a server stream begun part-way (R54).** On the iPhone, resume an episode the server converts with its picture copied (Playback info reads "Repackaged by the server") from Continue Watching, mid-episode, with a sidecar subtitle on. Done: lines appear with the speech, as they do when the same episode plays from its start; the log's `player stream.origin` shows `used` equal to `measured`.
- [ ] **N15 — The first episode after launch plays on the phone at home (R55, R56).** On Isabel's iPhone at home with Tailscale on, quit Marquee, open it and play an MKV episode. Done: Playback info reads "Repackaged on the phone", not "by the server"; the log has `player link.probe` with its kbps and `ms` under 1000, and the route's `reach` reads "fast enough". On 5G, the same start plays on the phone when the probe reads at least 3 times the file's bitrate.
- [ ] **N16 — Save Data on mobile data (R56).** On the iPhone with Save Data on, play an episode on Wi-Fi, then turn Wi-Fi off mid-episode. Done: stats for nerds shows Save Data · 720p on cellular only, and the picture moves to 720p at the playhead; with Save Data off, cellular plays as Wi-Fi does.
- [ ] **N17 — A paused remux plays on (R57).** On the iPhone, play an MKV episode repackaged on the phone, pause it for two minutes, once in the player and once in Picture in Picture paused from its own button, then play. Done: it plays on from the same place without closing, Playback info still reads "Repackaged on the phone", and the log has no `-12888`, `-1004` or `stream.failed`.

The first build batches N1–N5. Inspect recordings before editing, exercise the touched behavior once after the batch, then publish one point release. No unrelated refactor or engine replacement.

## 2. Next device session: validate the released features

These checks can proceed on 0.1.44 except the new X control. Agent work prepares the cases and reviews diagnostics; Nitin or Isabel performs actions requiring the physical phones, TV or glasses. A failed check becomes a specific fix, not a claim that the entire feature is absent.

### Phone playback and downloads

- [ ] **D1 — Intro skip and binge settings (R05, R31–R33).** Confirm that the intro skips once, autoplay can be disabled, the chosen credits delay is respected, instant skip advances once and Watch Credits cancels it.
- [ ] **D2 — Detail and player layout (R01–R04, R06).** Confirm the prominent parent-show link without a glass pill, one Home/Library title, an episode panel using its full width without the top divider, and the first-play quality badge appearing top-trailing after the controls hide, then fading after roughly one second.
- [ ] **D3 — Simple subtitles (R10–R13).** Confirm Off/English, ordinary English tracks preferred, inline style controls and one Find Subtitles action. Slow, empty or failed Bazarr must fall back automatically with useful progress; no separate Plex choice. Device check 5 plus the subtitle UI flows.
- [ ] **D4 — Away playback (R14).** Repeated cold starts and close/reopen on mobile 5G must play or offer a bounded error with Retry, never remain preparing indefinitely. Device check 20; actual phone playback remains unverified.
- [ ] **D5 — Isabel's downloads (R15).** Check her affected titles and cellular policy. Zero progress must show its real reason, offer the cellular action when appropriate and recover from an unreachable home address. A recent app update alone does not close this issue.
- [ ] **D6 — Picture in Picture (R16).** Movies, direct-tuner Live TV and Plex Live TV must keep the picture when leaving the app and restore correctly. Device check 7; the remux LIVE-label limitation is tracked separately below.
- [ ] **D7 — Orientation (R17).** Check Follow Device, Start in Landscape and Lock to Landscape for movie/live playback, return to the app and PiP, including iOS orientation lock. Device check 18.
- [ ] **D8 — Phone smoothness (R18).** Check film pans, live playback, Home/library scrolling and controls on a 120 Hz phone. Record frame diagnostics; an uncapped frame-rate setting is not proof of smooth playback. Device check 19.
- [ ] **D9 — Quality downloads end to end (R34–R37).** Test measured and unmeasured titles, animation, resolution/size labels, transfer while Plex converts, locked-phone progress, pause/reopen/resume, joined-file continuity and offline picture/audio/subtitles. Include the estimated 4K HEVC choice and conversion-session cleanup. Device checks 14–16 and 25. Respect iOS background limits; a force-quit need not continue transferring, but saved work must resume safely.

### XR, wired TV and linked remote

- [ ] **D10 — XR presentation and feature coverage (R19).** Use the Stashy glasses patterns as a reference, but keep Marquee's movie/TV identity, theme tokens, optical safe margins and large-display proportions. Check each relevant phone feature against the glasses surface: browse/search, title/season/episode navigation, requests, downloads, Live TV/DVR, playback/tracks and access to settings. Record actual gaps; complete them before claiming phone-feature parity. Device check 21 and DESIGN §8.9.
- [ ] **D11 — Eyes-free haptics (R21).** Distinguish focus, selection, back, boundaries, scrubbing, volume and errors without looking at the phone. Confirm accessible alternatives. Device check 22.
- [ ] **D12 — Motion assistance (R22).** Check the opt-in hold/tilt controls, useful fine adjustment and no navigation from walking, picking up or putting down the phone. No always-on sensor navigation. Device check 22.
- [ ] **D13 — Wired TV mode (R23).** Check USB-C/HDMI connection choice, remembered display type, native scaling, margins, sound, disconnect recovery and HDR/SDR behavior. Similar-resolution glasses and TVs may require a manual type override. Device check 23; wireless AirPlay mirroring is not claimed.
- [ ] **D14 — One-time symmetric pairing (R24).** Link once by QR and confirmation, reverse host/remote roles, reconnect after lock or network change and unlink safely. Device check 24. Successful initial pairing has been reported by Nitin; full reconnection acceptance is still open.
- [ ] **D15 — No hotel Wi-Fi (R25).** Repeat with neither phone joined to Wi-Fi while the host streams using cellular; Wi-Fi radios remain enabled for the direct phone-to-phone link. Check permission/error guidance and reconnection. Device checks 24 and 26. This is peer-to-peer Wi-Fi, not BLE or an internet relay.
- [ ] **D16 — Software HDMI volume (R26).** Verify film and Live TV volume from the host's touchpad and the linked phone, including quiet/full levels, next-episode persistence and Dolby/Atmos handling. Device check 24. The HDMI host's physical volume buttons do nothing in the reported hotel setup; no acceptance depends on them. App attenuation cannot raise the TV above its own physical setting.
- [ ] **D17 — Leave and restore the remote (R27).** Phone App/Close, Settings and the top-edge gesture must return to the normal app without stopping the external screen; the Home display button restores the remote. Device check 27.
- [ ] **D18 — Local XR touchpad (R28).** Check continuous finger tracking, coasting, interruption, settling and boundary haptics on the phone driving glasses. Device check 28; record median and 95th-percentile touch delay.
- [ ] **D19 — Local TV touchpad (R29).** Repeat on the phone driving a wired TV, at the display's actual refresh rate. Device check 28.
- [ ] **D20 — Linked-phone touchpad (R30).** Repeat with the second phone driving the host's TV and glasses, on shared Wi-Fi and the direct link. Compare with Apple TV Remote before claiming equal or better feel. Device check 28. Pages/grids have continuous tracking; panels, player and Live TV currently retain step navigation, so their feel must also be assessed rather than implied equivalent.

Record only the cases actually exercised, with the app version, device/output route and diagnostics or receipt path. Simulator shots do not prove decoding, haptics, HDMI volume, network handovers or touch-to-display smoothness.

## 3. Build queue: network-aware VMAF streaming

R39–R42 remain planned, not implemented. The full library map is not a prerequisite: existing measurements and estimates are enough to start development. Validation of the shared quality contract and playback reliability comes first; this work must not wait weeks for every episode to be measured.

1. **S1 — Reuse and validate the quality data.** Connect the existing HomeLabber client to playback, not a second integration or token. Check title/media identity, source, codec and encoder compatibility; use estimates for unmeasured titles or an unavailable map. Existing measurements cover H.264 through 1080p, not measured 4K HEVC. Revisit incomplete or expired answers during a long app session so newly measured titles can become available without an app update.
2. **S2 — Add the presets without removing control.** Offer Auto and VMAF High/Medium/Low, preserving explicit Original/fixed-quality and Force Direct Play behavior. Use the map to choose resolution and bitrate per title. Show desired tier, actual resolution and measured/estimated basis; explain when capacity prevents the desired quality. Reconcile title-specific tiers with the existing picture-quality floor rather than copying fixed Mbps thresholds blindly.
3. **S3 — Measure the real playback path quietly.** Prefer bytes delivered during active video transfers and buffer trends. Exclude intentional download pauses, already-buffered data and stale measurements from another network/server path. Distinguish insufficient network delivery from slow Plex conversion. Only when confidence is insufficient, use a small, bounded background probe on the actual path; no continuous full-speed speed tests. Bound cellular data and power use and obey Low Data Mode.
4. **S4 — Preserve quality, adapt only when needed.** The selected tier is the desired quality, not a guarantee that an inadequate connection can sustain it. Absorb temporary dips with buffered video. Require evidence of a sustained deficit or impending buffer exhaustion before reducing quality; choose the smallest reduction that can sustain playback. Large reductions are a last resort, not forbidden during a severe collapse. Recover after sustained headroom, with enough separation between switches to prevent oscillation.
5. **S5 — Treat Wi-Fi and cellular intelligently.** Adjust measurement confidence and response to observed variability and network handovers, rather than assuming Wi-Fi is fast or cellular is slow. Reassess the new path without an automatic downgrade just because its type changed. Separate policies for stable Wi-Fi, variable cellular, unknown capacity and recovery must be justified by traces, not arbitrary device-specific presets.
6. **S6 — Switch using the existing player.** Reuse Core's `AdaptiveQuality`/`QualityScores` and the player's prepared-stream swap. Preserve position, selected tracks and external output. Plex needs a new conversion stream for a changed setting; PiP, AirPlay and other fallback routes cannot all promise a gapless swap. Engine changes, if actually required, go upstream to VideoEngine and are shared with Stashy.
7. **S7 — Prove the policy and release once.** Deterministic delivery/buffer traces must cover stable fast Wi-Fi, a brief dip with a healthy buffer, sustained congestion, variable cellular, handover, slow conversion, unknown capacity and recovery. The brief-dip case must not downgrade; a sustained deficit must make only necessary changes. On a phone, record switches, buffering, bytes, startup time and playback continuity on Wi-Fi and cellular. Release an unsigned point update after the touched Core/App checks, with UI results tracked independently under the existing release policy.

Implementation order: S1 → S2/S3 → S4/S5 → S6 → S7. One integration owner keeps the shared quality contract, policy and player changes consistent; no separate download or streaming network engine is introduced.

## 4. Later work retained

- [ ] **L1 — XR webpage mockups (R20).** The requested browser-viewable design artifact has no confirmed delivery receipt. Retain it as an open design task, focused on glasses-scale Plex navigation and the eyes-free remote. The later instruction waived screenshot approval before an XR release; it did not establish that the webpage was delivered. Mockups are not a release gate and do not replace hardware checks.
- [ ] **L2 — YouTube-style in-app mini player (R43).** Reuse the active player while browsing, with expand and dismiss controls and no second playback instance. Define its interaction with PiP, external displays and the remote before implementation. No new mini-player design has been accepted yet.
- [ ] **L3 — Feel-your-way LG TV remote (R44).** Separate from the released iPhone-to-iPhone remote. Build through LumaRemoteKit and the LumaTV phone-remote plugin: continuous touch navigation, confirmed haptics and optional thumb-held motion assistance. Establish actual LG transport/driver support before choosing Wi-Fi Aware or any BLE path; compare measured delay with the existing encrypted route. No unmeasured latency target is an acceptance claim.
- [ ] **L4 — Remux PiP LIVE label/scrubber.** Existing upstream dependency from [adaptive-playback.md](adaptive-playback.md): a finite movie playlist must be implemented and released in VideoEngine, then adopted by Marquee and communicated to Stashy. No local frame-copy workaround that loses HDR or increases power.

**Not automatically queued:** native Android/iOS HomeLabber quality-map controls (R38). The web page and NAS scoring are available; the question about native-app availability did not authorize two additional app implementations. If requested, reuse HomeLabber's existing settings/status interface for enable, schedule, progress, pause/resume and token management.

**Platform answer, not a missing implementation:** HDMI-CEC from an ordinary iPhone USB-C/HDMI app (R45) has no supported public control path identified. Software playback volume is the implemented alternative. Bluetooth was a proposed means of avoiding shared Wi-Fi, not a requirement to replace the working direct Wi-Fi link.

## 5. Request inventory

Each request is retained separately below; repeated reports share one entry instead of creating duplicate work. Release references establish delivery only. Hardware acceptance remains open unless explicitly stated.

| ID | Requested result | Recorded state / next work |
|---|---|---|
| R01 | Prominent, obviously tappable show/movie parent title without a glass pill | Released: `f2843a7`; D2. |
| R02 | Home/Library title shown once, with its menu visible | Released: `4820f80`; D2. |
| R03 | Episode picker uses the available trailing width | Released: `57fcab1`; D2. |
| R04 | No divider above the episode picker | Released: `57fcab1`; D2. |
| R05 | Intro countdown skips once instead of restarting | Released: `ed15c7b`; D1. |
| R06 | First-play quality badge after the controls hide, in the corner for about one second | Released: `57fcab1`; D2. |
| R07 | Profile photo and ring never clipped while idle | Previous fix released: `ac20b0b`; N2, not hardware-accepted. |
| R08 | Settings closes smoothly into the circular profile icon | Previous fixes released: `0b61cb4`, `ac20b0b`; N2. |
| R09 | Settings X matches the profile button rather than a Done label | Build: N1. |
| R10 | Simple English subtitles, no on-screen-text or technical-track clutter | Released: `49d398e`; D3. |
| R11 | Subtitle styling stays inside the player controls, never a full-screen window | Released; unresolved style UI acceptance: N3 and D3. |
| R12 | Quick subtitle search with clear working/result feedback | Released: `8b08c79`, `69ab5de`; D3. |
| R13 | Automatic Bazarr-to-Plex fallback, no separate Plex option | Released: `8b08c79`; D3. |
| R14 | Reliable away-from-home/mobile-5G playback starts | Released: `70ad4aa`; D4. |
| R15 | Isabel's downloads finish instead of silently staying at zero | Recovery and cellular guidance released: `70ad4aa`; D5. |
| R16 | Automatic PiP for movies and both Live TV paths | Released, Plex Live added by `8d35992`; D6. |
| R17 | Predictable landscape/orientation settings | Released: `c09cfde`; D7. |
| R18 | Smooth playback and scrolling on a high-refresh iPhone | No cap found; not performance-accepted: D8. |
| R19 | Beautiful, large-display XR Plex UI with the phone's features, informed by Stashy | Plugin released in 0.1.36 (`920da41`); feature and hardware acceptance: D10. |
| R20 | Browser-viewable XR UI/UX mockups | Unconfirmed delivery; L1 retained. |
| R21 | Intuitive eyes-free remote with meaningful haptic cues | Released with XR; D11. |
| R22 | Useful optional gyro/motion assistance without accidental input | Released with XR; D12. |
| R23 | The same big-screen mode on TVs through USB-C/HDMI | Released in 0.1.38 (`3b2f915`); D13. |
| R24 | One-time QR pairing; either linked phone can control the other | Released in 0.1.38; initial pairing reported successful; D14. |
| R25 | Linked remotes without joining hotel Wi-Fi, while using mobile internet | Peer-to-peer Wi-Fi released in 0.1.39; initial link reported successful; D15. |
| R26 | Remote software volume for HDMI, including the second phone | Released in 0.1.42 (`a112388`, `bb8aa57`, `6182450`); D16. |
| R27 | Obvious exit to the normal app/Settings and return to TV/glasses remote | Released in 0.1.44 (`2c9655b`); D17. |
| R28 | Apple TV Remote-level smooth touchpad on the phone driving glasses | Continuous page/grid tracking released in 0.1.44 (`4b00f27`); comparison unmeasured: D18. |
| R29 | The same smoothness on the phone driving its own wired TV | Released in 0.1.44; comparison unmeasured: D19. |
| R30 | The same smoothness from a second linked phone | Released in 0.1.44; shared/direct-link comparison unmeasured: D20. |
| R31 | Autoplay-next-episode toggle in Settings | Released in 0.1.38 (`e532e06`, `3b2f915`); N4 and D1. |
| R32 | Credits skip honors the configured countdown | Released in 0.1.38; N4 and D1. |
| R33 | Instant credits skip for binge watching | Released; current test acceptance unresolved: N4 and D1. |
| R34 | Download completed chunks while Plex converts, then join them | Released in 0.1.41 (`9957904`, `94731c4`); D9. The original parked idea is no longer unbuilt. |
| R35 | Scheduled Plex-library VMAF map inside HomeLabber, not a separate script | HomeLabber 1.29.0 (`c43d38d`); live scoring verified Nov 15, initial map incomplete. |
| R36 | Estimates immediately, replaced by measured quality choices as available | Released in 0.1.41; integration key accepted Nov 15; D9 and S1 refresh verification. |
| R37 | High/Medium/Low choose a suitable resolution and show resolution/file size | Released in 0.1.41; target scores approximately 95/90/85, 4K remains estimated; D9. |
| R38 | Whether HomeLabber's Android/iOS apps receive the quality-map page | Answered: no automatic native page; optional implementation not authorized. |
| R39 | VMAF High/Medium/Low presets for streaming as well as downloads | Build queue: S1–S7; not released. |
| R40 | Streaming presets respect actual network and conversion capacity | Build queue: S3–S7. |
| R41 | Preserve quality; avoid drastic or needless drops and quality oscillation | Build queue: S4/S5/S7. |
| R42 | Seamless background measurement, intelligently different on Wi-Fi and cellular | Build queue: S3/S5/S7; passive transfer measurement first. |
| R43 | YouTube-style in-app mini player | Later: L2. |
| R44 | Eyes-free touch remote for the LG TV app | Later: L3; not the linked-iPhone remote. |
| R45 | iPhone USB-C/HDMI CEC control | Platform question answered; no supported public path identified. R26 supplies software volume instead. |
| R46 | Diagnostic logs to ntfy with Report a Problem, and the skip-intro miss explained | Built: DESIGN §8.12; N6 open. |
| R47 | Skip Credits on time for shows Plex marks late or not at all | Built: markers from named chapters, joining every Plex marker a chapter spans (DESIGN §8 Up Next); N7 open. 0.1.60 on Isabel's iPhone: S1 E14 waited for Plex's split-off final credits, fixed in 0.1.61. |
| R48 | Home appears instantly at launch | Built: last Home from disk, then a quiet refresh, DESIGN §11; N8 open. |
| R49 | Continue Watching follows rewatches | Built: the rule shared with the LG TV app, DESIGN §8.1 item 2 (`RewatchQueue`, `RewatchRun`); N9 open. |
| R50 | A lost server conversion is replaced within seconds, not after 30 s of retries | Built: DESIGN §8.6 (`ConversionWatch`); N10 open. |
| R51 | The measured link, not the place, decides whether the phone reads a file itself | Built: DESIGN §8.6, docs/adaptive-playback.md (`RouteReach`, `LinkMemory`, `ServerLimit`); N11 open. |
| R52 | Skip Intro leaves after the skip and lands on the first seek | Built: DESIGN §8.6 Who decides an overlay and Seeking in the remux (AVPlayer's seekable range); `testSkipIntroLeavesNothingOnScreen` checks the screen's pixels; N12 open. |
| R53 | Continue Watching follows what was just played | Built: DESIGN §8.1 item 6 (`LibraryChanges` from the player, stopped report held open in the background); N13 open. |
| R54 | Subtitles keep time in a server stream started part-way | Built: ARCHITECTURE Timeline mapping (`ServerStreamClock`, the origin measured from the first frame of the starting segment); N14 open. |
| R55 | A file plays on the phone whenever the link carries it, the first start after launch included | Built: DESIGN §8.6 Which way a file plays (`LinkProbe`). At home through Tailscale, checked on Isabel's iPhone with 0.1.59 (report r0773): the first start after launch probed 81 Mbps in 585 ms and was repackaged on the phone from its first route. N15's 5G case untested. |
| R56 | Speed alone decides, with a Save Data switch for mobile data | Built: DESIGN §8.6 Which way a file plays, docs/adaptive-playback.md (no place; `LinkProbe` on every unmeasured start; Save Data caps at 720p, 4 Mbps); N15, N16 open. |
| R57 | A paused episode repackaged on the phone plays on after a long pause | Built: DESIGN §8.6 Pausing the remux (VideoEngine 2.0.4 keeps production in step with the clock; 2.0.5 listens again after a suspension); N17 open. 0.1.59 on Isabel's iPhone: no `-12888` through a 2.5 min Picture in Picture pause, but the suspended app's listener was lost. |

## 6. Evidence and release boundaries

- Latest published version: **0.1.44**, built from `4b00f27`; `apps.json` updated by CI in `964dd90`. CI UI failures remain open despite successful publication. Worker-reported product failures include `testStyleMenuLandscape` and `testSkipCreditsInstantly`; their causes must be read from the failure artifacts, not inferred from their names. Older Up Next failures are not automatically classified as flakes.
- Last live HomeLabber inspection, Nov 15: enabled, unpaused, 74 measured titles, 693 of 4,814 covered including season borrowing; Dredd advanced from five to seven saved measurement points during inspection. No failed titles. The helper used about four CPU cores and 1.25 GiB RAM. An earlier helper-image HTTP 429 recovered. Marquee's token was accepted at 17:15 EST; this proves credential use, not an end-to-end completed download.
- HomeLabber's configured window is 01:00–06:00 UTC, currently 20:00–01:00 EST. Keep that explicit; no schedule change is authorized by this plan. Mapping can continue while app work proceeds, and completed results are usable before the full map finishes.
- No new physical-device acceptance, VMAF streaming behavior or Apple TV Remote performance comparison is claimed by this planning update. No new HomeLabber deployment, native HomeLabber app page, signed release or phone installation is authorized.
- Each implementation batch runs the narrow changed-behavior checks once after edits. Release remains the existing unsigned Feather pipeline: Core, Live and App gate publication; full UI/size checks continue independently and genuine failures get one combined point fix. Device evidence is required before calling hardware-dependent behavior accepted.
