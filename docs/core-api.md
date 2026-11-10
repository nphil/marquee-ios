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
- `PlexMetadata.markers(_:)`: intro, credits or commercial markers in playback order. `onDeck`: the episode to play next on a show's details. `theme`, `parentTheme`: a show's theme tune path, on the show and on its seasons. `PlexPart.hasSceneThumbnails`: the server has scrubber thumbnails at `/library/parts/<id>/indexes/sd`.
- `KeychainStore`, `KeychainError`: the account token and server list, readable after first unlock.
- `PlexTV`: the plex.tv account API.
  - `createPIN(strong:)`, `authURL(for:)`, `checkPIN(_:)`, `waitForToken(_:every:now:sleep:)`: PIN sign-in. A strong PIN is for the browser sheet, which the app closes once polling sees the approval; a 4-character one is typed at plex.tv/link.
  - `servers()`: servers with this user's token for each.
  - `homeUsers()`, `switchHomeUser(_:pin:)`: Plex Home profiles; a switch returns that profile's token.
  - `account()`: the user a token belongs to (`/api/v2/user`), the account or the profile switched to.
- `PlexPIN`, `PlexHomeUser`: sign-in code and profile. `PlexHomeUser` is Codable, so the app keeps the active profile.
- `PlexWatchlist`: the profile's watchlist on discover.provider.plex.tv, with the account token. `items(start:size:)`, `contains(guid:)`, `add(guid:)`, `remove(guid:)`. `catalogueKey(guid:)` is nil for titles matched by an older agent, which cannot be watchlisted.
- `MediaDeletion(server:watchlist:)`: `delete(_:alreadyDeleted:afterDelete:)` deletes a title and cleans its Watchlist entry (rules in PARITY, Delete media) and returns a `MediaDeletionResult`: a `DeleteOutcome` plus a `WatchlistCleanup` (`unchanged`, `removed(guid:)`, `failed(guid:)`). It talks to `DeletionServer` (`PlexLibrary`) and `WatchlistAccount` (`PlexWatchlist`); waits go through an injected `sleep`. `PlexLibrary.deleteItem(_:)` and `deleteVersion` wait 180 s; `allLeaves(of:)` lists a show's episodes. `PlexMetadata.parentGuid` and `grandparentGuid` name an episode's season and show.

## Server address (`Connection/`)

- `PlexServer`, `PlexConnection`: a server with this user's token and its addresses. Codable, for the Keychain only. `PlexConnection.displayAddress` is the address as a person reads it: the IP a plex.direct name spells, and the port when it is not 32400. `ipAddress`: that IP, or nil for a host name.
- `NetworkPlace.of(_:onPhoneNetwork:localAddress:roundTrip:)`: `.home` or `.away(.relay | .remote | .tunnel)` for the connection in use; a LAN address reached through a VPN (Tailscale) is away. Rules in docs/adaptive-playback.md.
- `ConnectionRanking.ordered(_:httpsRequired:)`: local, then remote, then relay; https before http, IPv4 before IPv6; duplicates dropped.
- `HomeNetwork.contains(_:)`: the hosts the app's transport security lets through without TLS (private, link-local and tailnet addresses, `.local` and single-label names); integrations allow plain http only to these.
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
  - `searchSubtitles(_:language:)`, `addSubtitle(_:candidate:)`: the server's own subtitle agents for an item in one two-letter language, best match first, as `PlexSubtitleCandidate`s, and adding one. A candidate's key is good only for the search that found it; the server lists the added file a little later as a new selected stream named after the release.
  - `imageURL(_:width:height:scale:)`, `authorizationHeaders()`: artwork and headers for the image loader and the remux.
- `HomeRow`, `HomeLayout`: a profile's Home rows. A row is a Home hub or a library hub (id prefixed with the library's uuid). `arrange(_:)` orders rows by the saved placements, then unplaced ones in server order with their default visibility (library rows hidden); `save(_:)` keeps placements of rows the server did not send this time; `shownLibraries` names the libraries worth asking. Row ids go through `HomeLayout.stableID`, which drops the genre or person Plex rotates in `movie.genre.<section>.<id>` hubs, and a layout decodes leniently so one odd placement from an older version costs only itself.
- `ProfileSettingsStore`: a profile's settings saved and read under its Plex uuid; a profile with none takes those kept under the key the same sign-in used before (the empty uuid, or the uuid the Home list gave).
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
- `MediaTracks(part:)`: one part's tracks, separate files last. An embedded subtitle with an exact separate-file twin, and an earlier copy of a file downloaded again (same release name and language), are hidden behind the newer file (`visibleSubtitles`, `visible(_:)`).
- `MediaTracks.arrived(_:kind:since:)`: a separate file in a language that was not listed before, such as a Bazarr download once Plex lists it. `listed(_:)` and `landed(_:since:)` find a Plex search result already in the menu and the file an added one became.
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
- `TrailerAutoplay`: `dwell` (2 s); `decide(_ conditions:)` → `.play(muted:)` or `.hold` from the setting, Low Power Mode, Reduce Motion, a metered link, app activity, hero visibility, an open player and other audio; `directPart(of:capabilities:)` → the first trailer file the phone plays untouched.
  - Direct play for MP4/MOV with H.264 or hvc1 HEVC and playable audio.
  - On-device remux for other containers, hev1 HEVC, Dolby Vision 7 and audio the remux converts. Without the remux, the server copies the video instead.
  - Server re-encode for video the phone cannot decode, Dolby Vision it cannot show, HDR on an SDR screen, HLS level or frame-rate limits, a quality limit, or a hand-picked subtitle to burn in.
  - Unplayable audio is first swapped for a playable track in the same language. Automatic subtitle picks never burn; a remembered one burns only when the video is re-encoded anyway.
- `ThemeMusic.key(for:)`: the tune a show's or season's page plays. `plays(_ conditions:)`: whether it plays now, from the setting, app activity, page visibility, an open player, other audio and a trailer with sound. `ThemeFade`: the tune's gain, rising over 1.5 s and falling over 1 s from wherever it is; `volume(level:)` is the setting times the gain squared.
- `PlaybackRoute`: kind, `RouteReason`s, played audio and whether it stands in, audio conversion, video re-encode, `SubtitleDelivery` (sidecar, in stream, burned in, not shown).
- `RouteReason`: plain-English reasons. `RouteLimits`: a server reason (on-device failure, direct play off, AirPlay), phone only (Direct play forced: never the server, unshowable subtitles not shown), bitrate cap.
- `VideoQuality.lower(mediaKbps:)`: the highest preset at or below half the rate playing now, offered after a long network wait at a fixed quality.
- `QualitySetting`: `.auto` (the default) or `.fixed(VideoQuality)`; `all` for menus, `saved(legacy:)` reads the old fixed-only setting.
- `AdaptiveQuality(place:mediaKbps:linkKbps:scores:tuning:now:)`: Auto's rung keeper (docs/adaptive-playback.md). `observe(Look)` takes the link speed, buffer and network wait every few seconds and returns a rung to move to or nil; `moved(to:at:)` once the move is over; `rung`, `estimateKbps`, `ladder`. `QualityScores`: a title's VMAF score per rung, capping the climb (nothing supplies them yet).
- `StallWatch`: what a wait in mid-play waits on. `check(now:position:run:)` → `.network(seconds:)`, `.stuck(ahead:cause:)` (a remux run idle for 1 s, or 30 s of output the player sits on: restart it at the playhead) or `.giveUp` (stuck again within 1 s of the last restart); `resume()` once playback moves.
- `SkipTaps`: the player's tap rule as a state machine. `tap(_ side:at:)` → `.skip(side)`, `.toggleAspect` or `.single`; `SkipTapMode.doubleTap` skips only on a true double-tap (`doubleTapWindow` 0.3 s), `.chained` also skips on same-side taps within `chainWindow` (1.5 s) of a skip; `reset()`. `TapSide` is the third of the picture a tap landed in.
- `FormatBadge`: `make(video:media:audio:route:)` → the first-start badge: `resolution` (by width), `range` (HDR10, HDR10+, HLG, Dolby Vision; none when the server re-encodes, HDR10 for a Dolby Vision profile 7 base layer), `sound` (Atmos, 5.1, 7.1; only for passed-through audio), `spoken` for VoiceOver.
- `TranscodeRequest`: start offset, quality, video copy and burn-in for `PlexLibrary.transcodeURL(_:)`. The server takes audio and subtitle from the streams set with `selectStreams`. `init(live:)` streams a tuned channel; the server copies H.264 and HEVC and converts MPEG-2.
- `CastReceiver(modelName:)`: what a Chromecast plays (4K HEVC for Chromecast Ultra and Google TV Streamer, 1080p H.264 for the rest). `CastRouteDecider.decide(media:part:tracks:audio:subtitle:receiver:limits:)`: the receiver opens an MP4 with video it decodes and AAC or MP3 first itself, else the server's HLS of H.264 and AAC; a subtitle is always burned in, since the Default Media Receiver draws none of Plex's formats.
- `CastStream`: the receiver's URL, content type and server session. `address(current:among:)` swaps plain http for an HTTPS address of the same machine; `file(part:base:token:)`, `transcode(_:base:identity:isLocal:token:)`. `PlexLibrary.transientToken()`: the 48-hour delegation token the receiver holds instead of the account's.
- `CastProgress`: one load's state from `CastStatus` updates: position between updates, `PlaybackState` for the timeline, and how it ended (finished, stopped, failed, replaced).

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
- `LiveSource` (`@MainActor` protocol): what the live player plays through (play, pause, resume, `seek(behindLive:)`, stop); `LiveState`, `LiveError`.
- `LiveTimeshift`: where a live stream plays against live (`isPaused`, `behindLive`, `reach`). `isBehindLive` (paused, or 3 s or more behind), `canSkipBack`, `skipped(by:)` (a skip's landing, within the buffer and snapped to live within 3 s); `hls(seekable:position:liveOffset:isPaused:)` and `hlsPosition(behindLive:seekable:liveOffset:)` map the Plex path's HLS player times.

## Subtitles (`Subtitles/`)

- `BazarrConfig.parse(address:key:)`: checks a typed address and key; plain http only for home-network addresses.
- `BazarrClient`: `status()` (Bazarr, Sonarr and Radarr versions), `find(_:)` (a `BazarrLookup` by external id, then file name, then title and year, to a `BazarrTarget`), `search(_:)` (`BazarrSubtitle`s, best score first), `download(_:for:)`.
- `SpeechDock.origin(_:)`: checks a typed service address (an http(s) origin alone; plain http only on the home network). `identity(server:ratingKey:media:audio:subtitle:)`: the choice SpeechDock can time (English sidecar text and English audio in a one-part file), or nil. `cues(_:)`, `alignable(_:)`, `window(_:asked:due:offset:ahead:)`: the file as the service reads it, the cues it times and the next window to ask about.
- `SpeechDockClient`: `health()` (the service's version), `align(_:)` (a `SpeechDock.Request` window to a `SpeechDock.Answer`: measured word starts by cue ordinal, or busy, or refused).
- `SubtitleLook`: the subtitle style: the TV's presets, font, size, colour, edge, box, position, line spacing, blending with the video and file styling. `init(preset:)`, `isCustom`.
- `SubtitleTiming`: a subtitle offset in 0.1 s steps, up to 60 s either way.
- `SubtitleReveal.estimate(_:duration:by:)`, `visibility(of:at:)`: Reveal as Spoken timing estimated from a cue's text and length. `measured(_:starts:by:)` takes SpeechDock's word starts instead; `spoken(_:)` is about how long a text takes to say.

## Seerr (`Seerr/`)

- `SeerrConfig.parse(address:apiKey:)` validates an HTTP(S) service address and optional key; plain HTTP is limited to home-network addresses. `Auth.plex` uses the Plex profile token; `Auth.apiKey` acts as the key’s owner. `SeerrError` distinguishes connection, authentication, permission, quota, duplicate request, missing title and service failures.
- `SeerrClient` (actor) takes a config, transport, optional Plex token and saved session, plus an `onSession` callback. `version()`, `signIn()`, `me()` and `serverSettings()` check the service, account and request settings. It maintains its own session and CSRF cookies; a Plex session rejected with 401 or 403 is renewed once and the call retried.
- `discover(_:page:)`, `search(_:page:)` and `details(_:tmdbID:)` return movies and series. `SeerrShelf` names Trending, Popular Movies, Popular Series, Upcoming Movies and Upcoming Series. `requests(of:take:)` returns the account’s latest requests, newest first, with optional title details. `request(_:)` submits a `SeerrOrder`; HTTP 202 and 409 mean `alreadyRequested`.
- `SeerrUser`, `SeerrPermissions`, `SeerrServerSettings`, `SeerrTitle`, `SeerrDetails`, `SeerrMedia`, `SeerrRequest` and `SeerrSeason` describe the account, catalogue and request state. Permission and server settings control standard and 4K requests, partial season requests and specials.
- `SeerrMedia.badge(is4K:)`, `SeerrRequest.badge` and `openRequest(is4K:)` describe status and the latest open request. `plexLink(serverID:)` returns a matching Plex item or an unconfirmed rating key that must be checked against the TMDB identifier before use. `SeerrDetails.seasonChoices(is4K:settings:)`, `canRequest(is4K:user:settings:)` and `order(seasons:is4K:settings:)` enforce quality and season choices; `watchlistAddRequests(user:pulsarr:)` detects automatic Watchlist requests. `TMDBImage.url(_:pixels:)` selects an image size.

## Navigation (`Navigation/`)

- `Destination`: Home, Library, Live TV, Watchlist, Search, Requests, Downloads.
- `TabLayout`: the order and the tabs switched on; `standard`, `init(savedOrder:savedShown:)` (unknown names dropped, missing ones appended off), `tabs(available:)`, `canSwitch(_:available:)`, `setTab(_:_:available:)`, `reorder(_:)`. Home is always a tab, Search always last, at most `maximumTabs` (5).

## Not yet checked against a live server

- The status codes for a wrong profile PIN (the live Plex Home has no protected profile). `/api/v2/resources`, `/api/v2/user` and `/api/v2/home/users` were decoded from a live account on 2026-11-06 with no mismatch.
- The watchlist add and remove calls and `removeFromContinueWatching`, which have not been sent to a live account; likewise `MediaDeletion`'s reads of `grandparentGuid` and `allLeaves`, and its recheck after a 5xx or timeout.
- The universal transcode parameters, including identity sent as query items and the offset format.
- The Seerr API and request flow, which use fixtures and have not been checked against a live Seerr server.
- The Keychain store, which has no tests.
- Dolby Vision, HEVC level and HDR limits, and CEA-608 captions on the actual phone.
- The live endpoints: fixtures follow the server's API spec and the shapes recorded in `docs/LIVE-TV.md` §1, not a captured response.
- `removeSubtitle(streamID:)` and the subtitle search and add, which only FakePlex has answered (their shapes follow the TV's measured notes), and the Bazarr client, which follows Bazarr's API source rather than a captured response.
- `PlexMetadata.theme` and `parentTheme`, which follow the server's API spec rather than a captured response; no test plays a tune.
