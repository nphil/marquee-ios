# MarqueeCore API

`Packages/MarqueeCore` holds everything that does not draw: the Plex client, the choice of server address, the library calls, the audio and subtitle rules and the playback route decision. It uses Foundation (plus Observation for `PagedLoader`); `Security` appears only in `KeychainStore`, which compiles on Apple platforms only. Public types are `Sendable` and network calls are `async`. The behaviour follows `docs/behaviour-spec.md`.

## Plex client (`Plex/`)

- `PlexClientIdentity`: the app as Plex sees it. `headers(token:)` gives the `X-Plex-*` headers; `storedClientIdentifier(in:key:)` creates the install's identifier once and keeps it.
- `PlexHeader`: Plex header names.
- `URL.removingPlexToken`: the URL without `X-Plex-Token`, for log lines and cache keys.
- `PlexTransport`, `URLSessionTransport`: send one request; URLSession errors become `NetworkFailure`.
- `PlexRequest`, `PlexHTTPResponse`, `HTTPMethod`: request and answer values.
- `PlexURL.make(base:path:query:)`: joins a base, a Plex path and a strictly encoded query.
- `PlexHTTPClient` (actor): adds identity and token headers. `send` retries a read once after a dropped connection, never a write or a timeout; `decode` parses JSON off the actor; `setToken` after a profile switch.
- `PlexError`: `unauthorized` (401), `unreachable(NetworkFailure)`, `server(status:message:)`, `decoding`, `pinExpired`, `profilePINRejected`, `noConnections`. Carries no token or URL, so it is safe to log.
- `PlexMediaContainer`, `PlexMetadata`, `PlexMedia`, `PlexPart`, `PlexStream`, `PlexMarker`, `PlexChapter`, `PlexRole`, `PlexHub`, `PlexDirectory`, `PlexLibrarySection`, `PlexMediaType`: Plex JSON. Every field is optional and read whether Plex sends `"1"`, `1` or `true`; a bad field never drops its item.
- `PlexMetadata.markers(_:)`: intro, credits or commercial markers in playback order. `onDeck`: the episode to play next on a show's details. `PlexPart.hasSceneThumbnails`: the server has scrubber thumbnails at `/library/parts/<id>/indexes/sd`.
- `KeychainStore`, `KeychainError`: the account token and server list, readable after first unlock.
- `PlexTV`: the plex.tv account API.
  - `createPIN(strong:)`, `authURL(for:forwardURL:)`, `checkPIN(_:)`, `waitForToken(_:every:now:sleep:)`: PIN sign-in. A strong PIN is for the browser; a 4-character one is typed at plex.tv/link.
  - `servers()`: servers with this user's token for each.
  - `homeUsers()`, `switchHomeUser(_:pin:)`: Plex Home profiles; a switch returns that profile's token.
  - `account()`: the user a token belongs to (`/api/v2/user`), the account or the profile switched to.
- `PlexPIN`, `PlexHomeUser`: sign-in code and profile. `PlexHomeUser` is Codable, so the app keeps the active profile.
- `PlexWatchlist`: the profile's watchlist on discover.provider.plex.tv, with the account token. `items(start:size:)`, `contains(guid:)`, `add(guid:)`, `remove(guid:)`. `catalogueKey(guid:)` is nil for titles matched by an older agent, which cannot be watchlisted.

## Server address (`Connection/`)

- `PlexServer`, `PlexConnection`: a server with this user's token and its addresses. Codable, for the Keychain only. `PlexConnection.displayAddress` is the address as a person reads it: the IP a plex.direct name spells, and the port when it is not 32400.
- `ConnectionRanking.ordered(_:httpsRequired:)`: local, then remote, then relay; https before http, IPv4 before IPv6; duplicates dropped.
- `ConnectionRanking.pick(_:graceExpired:)`: `use`, `wait` or `noneReachable` from probe outcomes so far.
- `ConnectionRanking.triesAlone(_:)`: only a remembered local address skips the probe. `upgrades(from:in:)`: the addresses in a better tier than the one in use.
- `PlexServerConnection` (actor): probes every address at once with `/identity` (no token; an answer from another machine counts as a failure). A remembered local address is tried alone first; a remembered remote one is not, since it may have won only while iOS asked for Local Network access or a VPN was on. Better-ranked addresses get 750 ms after the first answer. `connection()`, `currentConnection`, `reportFailure(of:)`, `refresh()` (after a network change), `preferLocal()` (on foreground: while a remote or relay address is in use, probes the better ones and moves to the best that answers).

## Library (`Library/`)

- `PlexLibrary`: one server's library through its chosen address. Reads move to another address once when the chosen one stops answering; writes are never repeated.
  - `promotedHubs(count:)`, `sections()`, `search(_:limit:)`: home rows, libraries, search groups.
  - `items(in:query:start:size:)`, `alphabetIndex(in:query:)`, `genres(in:)`: one grid page (60 by default), its A–Z jump bar and the genres to filter by.
  - `collections(in:start:size:)`, `recommendedHubs(in:count:)`: a library's Collections and Recommended.
  - `list(_:start:size:)`: one page behind a key the server handed out (a row's "see all", a collection, a person); the key keeps its own query.
  - `metadata(_:)`, `children(of:)`, `related(to:)`: details with streams, markers, chapters and the next episode; seasons and episodes; similar titles.
  - `items(matchingGuid:)`: this server's copies of a catalogue title, e.g. a watchlist entry.
  - `markWatched(_:)`, `markUnwatched(_:)`, `removeFromContinueWatching(_:)`, `reportTimeline(_:)`: watched state and progress.
  - `createPlayQueue(for:)`, `playQueue(_:)`: a queue that continues through the show for episodes.
  - `selectStreams(partID:audioStreamID:subtitleStreamID:)`, `playbackURL(path:query:)`, `transcodeURL(_:)`, `stopTranscode(session:)`: playback. These URLs carry the token because the player cannot send headers; they are never logged or cached.
  - `transcodeSession(_:)`: the server's `PlexTranscodeSession` for a `TranscodeRequest.session` (speed, throttling, decisions, hardware), nil once it has ended; for the player's stats.
  - `removeSubtitle(streamID:)`, `refresh(_:)`, `externalIDs(_:)`: deletes a separate subtitle file (the video stays), asks the server to re-read an item so a new file is listed, and an item's IMDb, TMDB and TVDB ids for Bazarr.
  - `imageURL(_:width:height:scale:)`, `authorizationHeaders()`: artwork and headers for the image loader and the remux.
- `HomeRow`, `HomeLayout`: a profile's Home rows. A row is a Home hub or a library hub (id prefixed with the library's uuid). `arrange(_:)` orders rows by the saved placements, then unplaced ones in server order with their default visibility (library rows hidden); `save(_:)` keeps placements of rows the server did not send this time; `shownLibraries` names the libraries worth asking.
- `SectionQuery`: item type, sort, Unwatched filter and genre for a grid.
- `PlexPage`: one page and the total behind it.
- `AlphabetIndexEntry.entries(from:)`: jump-bar letters with the offset where each starts.
- `PagedLoader` (`@MainActor`, `@Observable`): grid paging.
  - `reload(using:)`: starts a new generation; pages from an older one are dropped. A load cancelled because its screen went away records no failure.
  - `refresh()`: the first page again with the last query; on failure the shown items stay, with `failure` set. `loadedAt` is when the first page last arrived.
  - `loadMoreIfNeeded(after:)`: fetches the next page three quarters of a page before the end.
  - `ensureLoaded(through:)`: one request reaching a jump target, after any page already on its way.
  - `patch(_:)`: replaces a loaded item. Rows a shifted page repeats are skipped.
- `PlexPlayQueue`: `item(after:)`, `item(before:)` for Up Next.
- `PlexImageURL.transcoded(_:base:width:height:scale:)`: `/photo/:/transcode` at the view's pixel size, without a token, so the URL is the cache key.
- `PlaybackState`, `TimelineUpdate`, `TimelineCadence`, `TimelineReporter` (actor): progress reports on every state change and every 10 s while the state holds; a stop is sent once.

## Tracks (`Tracks/`)

- `TrackLanguage`: `eng`, `en` and `en-US` compare as English. `matches(_:)`, `name`, `variantName`, `.english`; `all` lists every two-letter language by English name, for language pickers.
- `AudioTrack`, `SubtitleTrack`, `TrackBadge`: tracks with plain menu labels ("English – 7.1", "English (on-screen text)", "Spanish (Latin America)") and Captions or Audio description badges. `SubtitleTrack.Kind` is full, captions, on-screen text or commentary.
- `MediaTracks(part:)`: one part's tracks, separate files last. An embedded subtitle with an exact separate-file twin is hidden behind the file (`visibleSubtitles`, `visible(_:)`).
- `MediaTracks.arrived(_:kind:since:)`: a separate file in a language that was not listed before, such as a Bazarr download once Plex lists it.
- `SubtitleLanguages`: the tracks menu's groups, the preferred languages first and the rest A to Z behind Other Languages.
- `SubtitlePicker.decide(tracks:audio:handPick:remembered:settings:canDrawImageSubtitles:)`: `SubtitleDecision` with its source. Order: hand pick, server selection, remembered choice, file default, setting. Automatic picks take only tracks the app can draw and follow the audio: the dub transcript for audio in the preferred language, the full translation for other audio.
- `SubtitlePicker.onScreenText(for:in:)`: the on-screen-text track in the audio's language.
- `AudioPicker.pick(in:handPick:remembered:preferredLanguage:)`: hand pick, remembered choice, server selection, preferred language, file default, first main track.
- `SubtitleSettings`, `SubtitleDefault`, `SubtitleChoice`: the subtitle setting and menu choices.
- `TrackMemory`, `RememberedAudio`, `RememberedSubtitle`: per-show memory described by language and kind, since stream ids differ in every episode. `TrackMemory.storageKey(server:profile:item:)`; the app stores it.

Tracks titled Signs or Songs count as on-screen text, as the spec's forced-word list includes "sign" and "signs".

## Playback (`Playback/`)

- `DeviceCapabilities`: what the phone, screen and player can do; the app fills it.
- `PlaybackRouteDecider.decide(media:part:tracks:audio:subtitle:capabilities:limits:hevcSampleEntry:)`: `PlaybackRoute`.
  - Direct play for MP4/MOV with H.264 or hvc1 HEVC and playable audio.
  - On-device remux for other containers, hev1 HEVC, Dolby Vision 7 and audio the remux converts. Without the remux, the server copies the video instead.
  - Server re-encode for video the phone cannot decode, Dolby Vision it cannot show, HDR on an SDR screen, HLS level or frame-rate limits, a quality limit, or a hand-picked subtitle to burn in.
  - Unplayable audio is first swapped for a playable track in the same language. Automatic subtitle picks never burn; a remembered one burns only when the video is re-encoded anyway.
- `PlaybackRoute`: kind, `RouteReason`s, played audio and whether it stands in, audio conversion, video re-encode, `SubtitleDelivery` (sidecar, in stream, burned in, not shown).
- `RouteReason`: plain-English reasons. `RouteLimits`: a server reason (on-device failure, direct play off, AirPlay), phone only (Direct play forced: never the server, unshowable subtitles not shown), bitrate cap.
- `TranscodeRequest`: start offset, quality, video copy and burn-in for `PlexLibrary.transcodeURL(_:)`. The server takes audio and subtitle from the streams set with `selectStreams`. `init(live:)` streams a tuned channel; the server copies H.264 and HEVC and converts MPEG-2.

## Live TV (`Live/`)

The endpoints and the route rules are in `docs/LIVE-TV.md`.

- `PlexLiveTV(library:)`: one server's Live TV and DVR.
  - `dvrs()`, `channels(_:)`: DVRs with their devices and channel mappings; the lineup's enabled channels in number order ("2.1" < "2.10" < "10.1"), each joined to the device that receives it (a live one first).
  - `guide(_:channels:from:to:)`: airings overlapping a window, one per channel a programme airs on; channels no device maps are dropped. `channelFilters(_:)`, `channelKeys(in:)`: the provider's genres and their channels.
  - `tune(_:session:)` → `PlexLiveSession`, whose `sessionIdentifier` names the tune, the transcode (`streamURL(_:)` with `TranscodeRequest(live:)`), the timeline reports (`reportTimeline(_:)` with `LiveTimelineUpdate`) and `stopStream(_:)`; the transcoder finds the tuned stream only under that name. `stopStream(_:)` also cancels the session's grab (`grabKey`), which frees the tuner.
  - `recordOptions(_:)` → `RecordOption`s (this episode, all episodes, the movie; `[RecordOption].defaultOption` is what a plain Record takes, never the whole show), `record(_:values:)`, `update(_:values:)`, `rules()`, `scheduled()`, `cancel(_:)` (deletes the grab: skips an airing or stops one recording), `stop(_:deleting:)` (the grab, then a rule), `delete(_:stopping:)` (a rule, after its running airings). `LiveRecordings.holdingTuner(for:dvr:)` finds the recording that has taken a channel's tuner.
- `LiveDVR`, `TunerDevice`, `LiveChannelMapping`, `LiveChannel`, `LiveAiring`, `LiveChannelFilter`: values, Codable for the guide cache.
- `LiveGuide`: channels and per-channel airings for the loaded span. `airing(on:at:)`, `nowAndNext(on:at:)`, `airings(on:from:to:)`, `merging(_:from:to:channels:)` (a refreshed span replaces what it covers; an overlap is cut at the later start), `trimmed(before:)`.
- `GuideCache` (actor): the last guide per server and DVR on disk, loaded re-anchored to now (up to 2 h of past airings) or nil once it ends before now.
- `RecordingRule`, `ScheduledRecording`, `RecordSetting`, `LiveRecordings.mark(for:)` → `RecordingMark` (scheduled, series, recording, failed, recorded) for the guide's record glyphs.
- `LiveRouteDecider.route(_:_:)` with `RouteContext` → `LiveRoute`: `.direct(URL)`, `.plex(PlexRouteReason)` or `.protectedChannel`, by the first matching rule of §2.2.
- `HDHomeRunClient`: a tuner's `discover.json` (0.5 s timeout, the reachability check) and `lineup.json` (`HDHomeRunChannel` with codecs, HD and DRM when the tuner sends them).
- `LiveSource` (`@MainActor` protocol): what the live player plays through; `LiveState`, `LiveError`.

## Subtitles (`Subtitles/`)

- `BazarrConfig.parse(address:key:)`: checks a typed address and key; plain http only for home-network addresses.
- `BazarrClient`: `status()` (Bazarr, Sonarr and Radarr versions), `find(_:)` (a `BazarrLookup` by external id, then file name, then title and year, to a `BazarrTarget`), `search(_:)` (`BazarrSubtitle`s, best score first), `download(_:for:)`.
- `SubtitleLook`: the subtitle style: the TV's presets, font, size, colour, edge, box, position, line spacing, blending with the video and file styling. `init(preset:)`, `isCustom`.
- `SubtitleTiming`: a subtitle offset in 0.1 s steps, up to 60 s either way.
- `SubtitleReveal.estimate(_:duration:by:)`, `visibility(of:at:)`: Reveal as Spoken timing estimated from a cue's text and length.

## Not yet checked against a live server

- The status codes for a wrong profile PIN (the live Plex Home has no protected profile). `/api/v2/resources`, `/api/v2/user` and `/api/v2/home/users` were decoded from a live account on 2026-11-06 with no mismatch.
- The watchlist add and remove calls and `removeFromContinueWatching`, which have not been sent to a live account.
- The universal transcode parameters, including identity sent as query items and the offset format.
- The Keychain store, which has no tests.
- Dolby Vision, HEVC level and HDR limits, and CEA-608 captions on the actual phone.
- The live endpoints: fixtures follow the server's API spec and the shapes recorded in `docs/LIVE-TV.md` §1, not a captured response.
- `removeSubtitle(streamID:)`, which only FakePlex has answered, and the Bazarr client, which follows Bazarr's API source rather than a captured response.
