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
- `PlexMetadata.markers(_:)`: intro, credits or commercial markers in playback order. `onDeck`: the episode to play next on a show's details.
- `KeychainStore`, `KeychainError`: the account token and server list, readable after first unlock.
- `PlexTV`: the plex.tv account API.
  - `createPIN(strong:)`, `authURL(for:forwardURL:)`, `checkPIN(_:)`, `waitForToken(_:every:now:sleep:)`: PIN sign-in. A strong PIN is for the browser; a 4-character one is typed at plex.tv/link.
  - `servers()`: servers with this user's token for each.
  - `homeUsers()`, `switchHomeUser(_:pin:)`: Plex Home profiles; a switch returns that profile's token.
- `PlexPIN`, `PlexHomeUser`: sign-in code and profile.
- `PlexWatchlist`: the profile's watchlist on discover.provider.plex.tv, with the account token. `items(start:size:)`, `contains(guid:)`, `add(guid:)`, `remove(guid:)`. `catalogueKey(guid:)` is nil for titles matched by an older agent, which cannot be watchlisted.

## Server address (`Connection/`)

- `PlexServer`, `PlexConnection`: a server with this user's token and its addresses. Codable, for the Keychain only.
- `ConnectionRanking.ordered(_:httpsRequired:)`: local, then remote, then relay; https before http, IPv4 before IPv6; duplicates dropped.
- `ConnectionRanking.pick(_:graceExpired:)`: `use`, `wait` or `noneReachable` from probe outcomes so far.
- `PlexServerConnection` (actor): probes every address at once with `/identity` (no token; an answer from another machine counts as a failure). A remembered address is tried alone first; better-ranked addresses get 750 ms after the first answer. `connection()`, `currentConnection`, `reportFailure(of:)`, `refresh()` (after a network change).

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
  - `imageURL(_:width:height:scale:)`, `authorizationHeaders()`: artwork and headers for the image loader and the remux.
- `SectionQuery`: item type, sort, Unwatched filter and genre for a grid.
- `PlexPage`: one page and the total behind it.
- `AlphabetIndexEntry.entries(from:)`: jump-bar letters with the offset where each starts.
- `PagedLoader` (`@MainActor`, `@Observable`): grid paging.
  - `reload(using:)`: starts a new generation; pages from an older one are dropped.
  - `loadMoreIfNeeded(after:)`: fetches the next page three quarters of a page before the end.
  - `ensureLoaded(through:)`: one request reaching a jump target.
  - `patch(_:)`: replaces a loaded item. Rows a shifted page repeats are skipped.
- `PlexPlayQueue`: `item(after:)`, `item(before:)` for Up Next.
- `PlexImageURL.transcoded(_:base:width:height:scale:)`: `/photo/:/transcode` at the view's pixel size, without a token, so the URL is the cache key.
- `PlaybackState`, `TimelineUpdate`, `TimelineCadence`, `TimelineReporter` (actor): progress reports on every state change and every 10 s while the state holds; a stop is sent once.

## Tracks (`Tracks/`)

- `TrackLanguage`: `eng`, `en` and `en-US` compare as English. `matches(_:)`, `name`, `variantName`, `.english`.
- `AudioTrack`, `SubtitleTrack`, `TrackBadge`: tracks with plain menu labels ("English – 7.1", "English (on-screen text)", "Spanish (Latin America)") and Captions or Audio description badges. `SubtitleTrack.Kind` is full, captions, on-screen text or commentary.
- `MediaTracks(part:)`: one part's tracks, separate files last. An embedded subtitle with an exact separate-file twin is hidden behind the file (`visibleSubtitles`, `visible(_:)`).
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
- `RouteReason`: plain-English reasons. `RouteLimits`: server only after an on-device failure, bitrate cap.
- `TranscodeRequest`: start offset, quality, video copy and burn-in for `PlexLibrary.transcodeURL(_:)`. The server takes audio and subtitle from the streams set with `selectStreams`.

## Not yet checked against a live server

- The shape of `/api/v2/home/users` and the status codes for a wrong profile PIN.
- The watchlist add and remove calls and `removeFromContinueWatching`, which have not been sent to a live account.
- The universal transcode parameters, including identity sent as query items and the offset format.
- The Keychain store, which has no tests.
- Dolby Vision, HEVC level and HDR limits, and CEA-608 captions on the actual phone.
