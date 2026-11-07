# Marquee: behaviour spec for the iPhone client (clean room)

How to read this: plain-English behaviour only. Plex endpoint names and query terms are given because they are public API facts. No code, names or comments are copied. Items marked [INFERENCE] are not confirmed in the docs.

## 0. Gaps and unverified items (read first)
- **Sign-in on the phone:** the Plex PIN (link code) flow and QR sign-in are not confirmed in this pass. The TV uses QR sign-in. Check the Plex auth docs before designing this.
- **Choosing a server connection:** the order of local, remote, relay and https is not confirmed in this pass. The README says relay and https are supported but not verified end to end.
- **Skip interval default:** the options are 5, 10, 15, 30 or 60 seconds (`locales/en/settings.json` ~778–790). The default was not confirmed.
- **Playback speed:** More menu › Playback Speed: 0.5×, 0.75×, Normal, 1.25×, 1.5×, 1.75×, 2×. Each new item starts at Normal.
- **Watched threshold:** about 90% of the length (`docs/pms-api.md` 1392). This was measured on one server version, so treat it as approximate.
- **Not verified on real hardware:** SpeechDock word timing, Reveal-as-spoken, and the TV decoder details.

---

## 1. Feature inventory by screen

- **Sign-in:** link a Plex account. Gap above.
- **Server choice:** pick one of the user's Plex servers. Only the user's own servers are used.
- **Home:** a stack of rows (hubs). A Continue Watching row shows a large card with progress. Other rows are standard shelves. Empty rows are hidden.
- **Libraries:** a poster grid for each movie or TV library. Options are a sort menu, a filter menu, and an A–Z jump rail. Tabs for Collections and Recommended.
- **Show detail:** the show's poster and summary, with its seasons. Unwatched badge = total episodes minus watched episodes (`docs/pms-api.md` ~90).
- **Season and episode lists:** episodes of one season, with watched state and resume position per episode.
- **Movie detail:** poster, summary, and a play button. Resume shows when there is a saved position.
- **Search:** a tab next to the others. It searches only the user's own servers, not the Plex catalogue or watchlist. Keyboard panel covers the bottom 324 px (TV layout). Last 4 recent searches are kept (`docs/search.md`).
- **Watchlist:** its own destination, backed by plex.tv, not part of search.
- **Settings:** two pages, "Video & playback" and "Audio & subtitles". Settings are saved per Plex Home profile. Integrations hold the optional SpeechDock address.
- **Player:** full-screen video. Control row: Previous, Next, a gap, then Subtitles, Audio, More.
- **Player overlays:** Up Next card, intro skip button, credits countdown, end-of-item notice, scene-thumbnail seek preview, and a "Wrong subtitles?" flow.

---

## 2. Plex interactions (public API facts)

**Identity on every call** (`docs/plex-api.md`, `docs/pms-api.md` ~15–16, 1296–1315): send a stable client ID generated once and saved, plus product, version, platform, device name, and the server token (`X-Plex-Token`). The official webOS client also sends firmware version, model, vendor, screen size, language, and an features string. The app sends only a subset. The effect of the features string is not measured.

**Lists and data:**
- Responses are XML by default. Send `Accept: application/json` for JSON. The top level is a `MediaContainer`.
- Sections: read the section list from the server. Do not hard-code section IDs. Movies=1, TV Shows=2 on the verified server.
- Hubs: `/hubs/promoted` for home rows. Continue Watching is a hub with the hero style. A `playlist` hub type is not shown.
- Items: `/library/sections/{key}/all` with paging (page size 60 in the app). Type codes: movie=1, show=2, season=3, episode=4.
- Unwatched filter: movies `unwatched=1`. **Shows use `unwatchedLeaves=1`.** Episodes `unwatched=1`.
- A–Z jump: `/library/sections/{key}/firstCharacter` gives counts per letter. The jump lands on the first title of each letter. `?firstCharacter=X` on `/all` is silently ignored.
- Browse menus: `/library/sections/{key}/all?includeMeta=1` gives the server-driven menu list.
- Metadata: `/library/metadata/{ratingKey}`. Add `includeMarkers=1&includeChapters=1` to get intro/credits markers and chapters, which are omitted by default.
- Children: `/library/metadata/{key}/children` for show → seasons → episodes.
- Search: `/hubs/search` with a window. Search hubs have no key, so they cannot be paged per hub.
- Images: always go through `/photo/:/transcode` at the exact card size. Never load the raw thumbnail.

**Fields:**
- `viewOffset` (ms): saved position. Present only when partly watched.
- `viewCount`: present only once watched. Absent means unwatched.
- `duration` (ms).
- Episodes carry `grandparentTitle`, `parentIndex`, `index` and `grandparentThumb`.
- Parse every field as optional, with 0 or empty as the default.

**Playback decision and transcode:**
- Direct play: use the `Media` → `Part` key with the token. The server supports byte ranges.
- Transcode handshake: call `/video/:/transcode/universal/decision` first.
- Then the stream is `start.mkv` with `protocol=http`, `directPlay=0`, `directStream=1`. The platform header must be `Generic` or the server returns 400. The session ID must match.
- Responses are chunked and must be decoded.
- Seek uses an `offset` parameter.
- Stop with `/video/:/transcode/universal/stop`.
- After a rapid start and stop, retry with backoff for about 60–90 s.
- Adaptive ladder and Original vs HLS: `docs/adaptive-playback.md`. DASH is not supported.

**Playback queue:** `POST /playQueues?continuous=1` for every playback. It returns the rest of the show, so Up Next needs no extra calls. Queue ID and selected item ID must be kept when handing off, or Previous is lost.

**Progress reporting (`/:/timeline`):**
- Send `state=playing` about every 10 s with the current `time`.
- Send on every pause (`paused`), resume (`playing`) and stop (`stopped`, with the final time). Times are in ms, with `duration`.
- Watched: at about 90% of duration, the server marks the item watched and moves the next episode up. A playing report past that point bumps `viewCount` and clears `viewOffset`.
- A stop under about 1–2 minutes is not saved. A 60 s stop was dropped and a 120 s stop was kept (measured 2026-10-10).
- Mark watched or unwatched directly: `/:/scrobble` and `/:/unscrobble`. These restamp the last-viewed time and move the deck.

**Live updates:** the owner's notifications stream (`/:/eventsource/notifications`). It is only a hint. It never sets resume or the watched state. It sends about one ping every 10 s and does not replay missed events, so reconnects must re-read the screens. Scrobbles emit nothing.

**Markers (intro and credits):**
- Read `Marker` entries with type `intro` or `credits`.
- The list is not sorted by time. Match by type and offsets, never by ID.
- Coverage is uneven. Movies usually have none.
- A `final` credits marker's end equals the full container length, which playback often stops short of. Treat it as open-ended.

**Up Next:** comes from the continuous PlayQueue (above). Next-episode data is already on each row.

---

## 3. Audio and subtitle rules

**Subtitle pick, in order** (`docs/marquee/changelog.md`, `rust-modules/media/src/route/plan.rs` ~3640–3800):
1. The pick for this playback only.
2. A subtitle the server selected that the app can draw.
3. The remembered choice for this show: a track, Off, or Forced only.
4. Plex's embedded default, then the show's setting, then the account setting, then Off.
- Remembered Off and Forced only never fall through to later steps. A remembered track can fall through when no match exists.

**Automatic subtitle follow:**
- English audio: prefer the dub transcript (SDH or CC flag, a `.cc` or `.sdh` sidecar, or a name with Dub or Dubtitle).
- Other audio: prefer the full English translation (not forced, not signs, not dub or commentary).
- Downloaded tracks beat built-in ones.
- A base track that is forced, signs, commentary or of unknown language stands as it is.
- On-screen text and the account-level Forced only rule are never followed.
- A remembered choice that picked the subtitle is never overridden.

**Track kinds** (`rust-modules/data/src/metadata/track_label.rs`):
- Full, SDH, Forced, Commentary. Forced words: "forced", "forsed", "форс", "sign", "signs". Commentary: "commentary" or "комментари".
- Dub words: "dub", "dubs", "dubbed", "dubtitle", "dubtitles".
- "Signs & Songs" is a style name, not a forced track.
- Rank order: full, SDH, forced, commentary.

**Downloaded-twin rule** (`sub_layout.rs` ~290, 747–758): a built-in track is hidden only when a downloaded track has the same language, region and kind. Commentary, dub and on-screen text are never twins of a full translation.

**Forced only:** shows the forced, non-commentary track in the playing audio's language, or nothing. It never falls back to a full track. Switching audio switches the forced track with it. A track named Forced counts even with no flag. A flagged commentary track is never the forced track.

**Remember audio and subtitle choices:**
- On by default, per show or movie, per profile and per server.
- Turning it off stops remembering and recalling, but keeps saved choices.
- The audio menu can remember the current track or forget the saved one.

**Audio matching** (`track_memory.rs`): language, commentary and audio-description are hard constraints. Codec, channel count, tag, title and default flag are soft, in that order. Commentary never stands in for a plain pick.

**Audio stand-in when the wanted track cannot direct-play:**
- First try a same-language, non-commentary track. A commentary or dub never stands in for the main track.
- Force Direct Play tries three passes: (1) a native track that fits the intent, (2) the app's own decode of a track of two channels or fewer, (3) any native stand-in.
- Surround DTS is not mixed down to stereo by default (owner decision, 2026-10-28).

**Remembered external subtitle:** never reused as the same file. The next episode gets a same-language, same-forced sidecar. If none, an embedded track with the same language and forced-ness. If none, memory steps aside.

**Server write-back:** on a fresh direct play, the applied tracks are written once, on the first decoded frame. Retries, transcodes and downloaded-subtitle parts write nothing.

**Burn-in rule:** account defaults never burn a subtitle into the picture at transcode start. A remembered pick is burned in only when the video is re-encoded anyway. Otherwise it is drawn, or shown as "not shown (copy remux)".

**Labels a viewer sees:**
- "Subtitles", "Captions" (deaf and hard of hearing), "Audio description".
- Track names: "English", "English (dub)", "English (on-screen text)", "(commentary)".
- No codec names or file titles in the Subtitles menu. The Tracks panel keeps technical labels.
- "Track N" tells apart identical rows.
- The audio menu uses plain-words labels in eleven languages.

**Subtitles menu** (`docs/player-submenus.md` 1–203): Off, Forced only ("On-screen text only"), one section per language, "Other languages N", Timing, Style (size, position, colour), and Search subtitles when Bazarr is set up. Per-language pages rank Full, SDH, Forced, Commentary. Image-format badges (PGS, VOBSUB, DVB) show only on image subtitles.

**"Wrong subtitles?" flow (Bazarr):**
- Remove an external subtitle from Plex, or search Bazarr by score, language, provider and hearing-impaired flag. Download, then Plex refreshes and the new track is selected.
- States: queued, Plex track found, loading, Active, or a named error.
- "Check Plex again" refreshes metadata only and never downloads twice.

**Subtitle look** (per profile): presets, font, size, colour, opacity, bold, edge, background box, position, line spacing, "Blend with video", "Reveal as spoken", and "My look" file styling. Native ASS/SSA keeps its own styles.

**SpeechDock** (the owner's own service): optional address under Settings › Integrations, off when empty. Supplies English word timing for "Reveal as spoken". Not verified on a real TV.

---

## 4. Resume, skipping, and other viewer-visible behaviour

**Resume:** a saved position is `viewOffset`. It is shown on Continue Watching and the episode rows. Playing from there seeks to it.

**Previous and Next:**
- Previous restarts the item if at least 5 s in. Before 5 s it goes to the previous queue item.
- Next is shown when a queue neighbour exists. Unavailable buttons are dimmed and skipped.
- A Marker offer or Up Next card takes priority over this row.

**Skip interval (FF and REW):**
- The setting is one value for both directions: 5, 10, 15, 30 or 60 s. Default not confirmed (gap).
- A tap jumps by that interval. Taps within 1.5 s add up from the last target. After a longer gap, the next tap starts from the current position.
- Holding opens a scrubber that waits for OK. Back cancels.
- Optional "Instant D-pad seeking" (off by default): a Left/Right tap jumps at once when the controls are hidden. With controls visible it still previews and waits for OK.

**Intro skip:** default Manual. Optional countdowns of 3, 5, 10, 15 or 30 s. "Skip intro" is focused first. "Watch intro" cancels auto-skip for that episode.

**Credits and Next episode:**
- The countdown starts only at a real credits marker with a queued next episode. Delay 3/5/10/15/30 s, default 5.
- Off turns off auto-next. The Next button stays.
- "Watch credits" stops the countdown for the whole episode.
- Pause, buffering, menus and input all interrupt the countdown.
- Duration-based guesses are not markers and never show a credits prompt.
- If a marker is confirmed missing, one notice points to Plex's detection settings and Analyze.

**Account preference save:** settings change go to the Plex account profile as a single request with only the changed keys. The confirmed values stay in effect if the save fails, with a Retry. A late response never overwrites a newer setting.

**Video:** aspect ratio preserved by default. The More menu offers Fit, Fill (crop), Original size, Zoom and Stretch without a restart. Scene-thumbnail seek: first Left/Right opens the preview, OK seeks, Back cancels.

**Direct Play modes:** Auto (default), Disabled, Force (advanced). Force asks for a warning acknowledgement with Cancel focused first. It overrides quality and turns off fallback.

**Audio language list:** 190 languages, from Plex Web 4.160.0. Regional codes are not rewritten.

**Playback codecs:** direct play for H.264 and HEVC (up to 4K, 10-bit, Dolby Vision profiles 5 and 8, E-AC-3 Atmos). AV1 and VP9 where the TV's table lists them. Anything else is transcoded.

**Playback speed:** seven speeds from 0.5× to 2× in the More menu, Normal in the middle; a new item starts at Normal and live TV has no speed control.

---

## 5. TV-only items to drop or rethink for a phone

- **Remote-control navigation:** D-pad focus, Back key, focus rings, and the on-screen keyboard layout measured in pixels (324 px). A phone needs touch layouts instead.
- **Sign-in by QR code on the TV.** Phone sign-in is a different flow (see gaps).
- **Digital Sound Output passthrough and the audio device settings.** iOS does its own audio routing.
- **webOS developer-mode and Homebrew expiry notes** and the sideload notes for LG.
- **Interface-resolution setting** and the 4K/1080p panel constraints.
- **Stats for Nerds:** the 120 Hz display-sync and 60 fps test readouts are TV-hardware checks.
- **LG chip failures** (k5lp/k3lp 2019, firmware 3.9.3 in 2018). Not relevant to iOS.
- **Keep the logic, rethink the screen:** subtitle and audio pick rules, Plex calls, resume, markers, Up Next, and the Bazarr flow all carry over. Only the layout and input change.

---

## Next steps for the main agent
1. Save this report text to `/tmp/marquee-ios/behaviour-spec.md` (no tool here can write there).
2. Confirm the sign-in PIN flow, connection order, and skip-interval default before the iPhone design is locked. These are the three gaps in section 0.