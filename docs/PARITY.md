# Feature parity with Marquee TV

Behaviour only (clean room): TV-side rows come from the TV app's user-facing strings and docs, never its code.

## Legend
- **Done**: works in the iPhone app.
- **Partial**: some of it exists; the gap is named.
- **Missing**: no iPhone code found.
- **N/A**: does not apply on a phone (remote-control focus etc.).

Plex/Bazarr API column: Plex endpoints marked `[code]` are already used by the iPhone app. Endpoints marked `[INFERENCE]` are not yet used in the iPhone code and must be checked against the Plex or Bazarr API docs before building.

## 1. Browse
| Feature | Status | Behaviour (plain English) | API |
|---|---|---|---|
| Library titles grid | Done | Movies/shows in a poster grid per library, from the title menu. | `/library/sections/{key}/all` [code] |
| Library segments: All / Collections / Recommended | Done | Switch between all titles, the library's collections, and the server's picks. | `/library/sections/{key}/collections`, `/hubs/sections/{key}` [code] |
| Sort | Done | Title, Recently Added, Release Date, Rating (score), Audience Rating, Recently Watched, Plays, Random; Order menu reverses any of them. | `sort=` on section query [code] |
| Unwatched-only filter | Done | Shows only titles not yet watched. | `unwatched=1` [code] |
| Genre filter | Done | Filter the grid by genre. | `/library/sections/{key}/genre` [code] |
| A–Z jump rail | Done | Jump to a letter in the grid. | section alphabet index [code] |
| Under-poster labels (Title on/off, Details: year, length, genre, video, age+score; Sort value shown) | Done | Settings › Under Posters, with a live preview; per profile. | none; local setting |
| Watchlist | Done | Own tab, backed by plex.tv. | `discover.provider.plex.tv` watchlist; `/library/sections/watchlist/all` [code] |
| Search | Done | Search titles. | `/hubs/search` [code] |
| Collections / hubs (home rows) | Done | Home and hub rows; collection destinations. | `/hubs/*` [code] |
| Person filmography | Done | Tap a cast member (or a person in Search) for their titles in the libraries, newest first, with film and show counts. | `/library/people/{id}/media` |
| Stats logging (opt-in) | Missing | Opt-in usage reporting, separate from Stats for Nerds. | none |

## 2. Detail actions
| Feature | Status | Behaviour | API |
|---|---|---|---|
| Play / Resume | Done | Play or resume; label shows 'Resume · N min left'. | `/library/metadata/{key}`, timeline [code] |
| Play from Beginning | Done | Starts again from zero. | `viewOffset=0` [code] |
| Mark Watched / Unwatched | Done | Toggles watched state on title or episode. | `/:/scrobble`, `/:/unscrobble` [code] |
| Mark show watched | Partial | Show-level watched toggle, separate from episode. Not found as a show-level action. | `/:/scrobble` on each episode [code/INFERENCE] |
| Remove from Continue Watching | Done | Removes a title from the continue row. | `/:/unscrobble` / on-deck [code] |
| Cast shelf | Done | Circular photos with names. | `roles` in metadata [code] |
| Related titles | Done | Related shelves on the detail page. | `/library/metadata/{key}/related` [code] |
| Extras (bonus videos) | Done | Movie and show pages: a shelf of 16:9 cards (kind and length); tapping one plays it. | `/library/metadata/{key}/extras` |
| Trailer | Done | More menu › Play Trailer: the server's primary extra, else the first trailer. | `primaryExtraKey`, `/library/metadata/{key}/extras` |
| Add to Watchlist | Done | Adds or removes from watchlist. | watchlist API [code] |
| **Delete media** (remove the file from the server) | Done | More menu › Delete… on a movie, show, season or episode, and Delete This Version… for a title with several files. Shown only on the owner's server, from the owner's profile, with Allow media deletion on; confirmation names the title, Cancel is the default. A deleted title leaves every list at once (Home, Continue Watching, library grids, search, seasons and episodes, a watchlist title's server copy) and its artwork leaves the caches; the server still lists it until its trash is emptied, so refetched lists keep it out for the session. 404 counts as deleted; 401/403 explains the server setting with no retry; a fault or no answer offers Retry. | `DELETE /library/metadata/{ratingKey}`, `…/media/{id}`; `allowMediaDeletion` on `/` |
| Delete subtitle file (Wrong subtitles → remove) | Missing | Deletes the external subtitle from the server; asks twice; cannot be undone. | `DELETE /library/streams/{id}` [INFERENCE] |

## 3. Playback
| Feature | Status | Behaviour | API |
|---|---|---|---|
| Direct Play / Remux / Server transcode routing | Done | Picks how the file plays; shows reason in Playback Info. | `/video/:/transcode/universal/start` [code] |
| Force Direct Play (asks first) | Done | Never falls back to server; confirm dialog. | local setting, route limits [code] |
| Intro skip button | Done | Skip button over intro markers. | `/library/metadata` markers [code] |
| Credits marker / Watch Credits | Done | Watch Credits keeps the end playing. | markers [code] |
| Up Next card + countdown | Done | Next episode card with countdown. | play queue [code] |
| Scrub speed (fine/half/quarter) | Done | Drag up or down to scrub slower. | local |
| Scrub preview thumbnails | Done | Thumbnail while scrubbing. | BIF trickplay [code] |
| Playback speed 0.5x–2x | Done | More menu › Playback Speed: 0.5×, 0.75×, Normal, 1.25×, 1.5×, 1.75×, 2×; back to Normal for each new item; pitch kept. | local (`AVPlayer.defaultRate`) |
| Quality picker in player | Done | More menu › Quality (Original, 20, 12, 8, 4, 2 Mbps); "Original · Converted" while the server re-encodes. Picking one also sets the default. | `maxVideoBitrate`, `videoResolution` on transcode |
| Default quality ceiling (Settings) | Done | Video & Playback › Default Quality; Forced Direct Play reads "original quality". | local setting |
| Normalize loudness / Boost dialog (Plex Pass) | Done | Audio menu toggles, shown only for a Plex Pass server; each reason they cannot apply is shown. The server reworks the sound on a copy of the video; on-device processing is not used because AVPlayer gives no audio tap on HLS streams. | `boostDialog=1`, `normalizeLoudness=1` on transcode; `Stream.canNormalizeLoudness` |
| Stats for Nerds | Done | Route, stream and bitrate overlay. | local [code] |
| Playback Info sheet | Done | Route, subtitle track, bitrate, frame rate. | local [code] |
| AirPlay / Picture in Picture | Done | PiP on phone; AirPlay stream handling. | AVKit [code] |
| Resume position | Done | Starts at saved offset. | `viewOffset` [code] |
| Watched threshold | Done | Marks watched near the end. | timeline [code] |
| Remote-control focus | N/A | TV remote focus. | — |

## 4. Audio
| Feature | Status | Behaviour | API |
|---|---|---|---|
| Audio track selector | Done | Pick track; wanted-language first; check on playing track. | streams [code] |
| Preferred audio language | Done | Per-profile preference. | local [code] |
| Follow-dub rule | Partial | Verify exact rule. | local [code] |
| Normalize loudness / Boost | Done | See Playback. | `boostDialog`, `normalizeLoudness` |

## 5. Subtitles
| Feature | Status | Behaviour | API |
|---|---|---|---|
| Off / On-Screen Text Only | Done | Forced subtitles only, or none. | streams [code] |
| One group per language, ranked Full / SDH / Forced / Commentary | Done | Ranked list per language. | streams [code] |
| Other languages submenu | Partial | Languages not in the wanted set; behaviour not confirmed. | streams [code] |
| Sidecar (external) subtitle download | Done | Downloads an external subtitle file and reads it. | `/library/streams/{id}` [code] |
| Image subtitles (PGS, DVB, VOBSUB) | Done | Drawn as bitmaps. | streams [code] |
| Image-subtitle badges and no-restyle rule | Partial | Image subtitles cannot be restyled; the reason row. | local |
| Subtitle style (size, position, colour, background, presets, live preview) | Partial | Style sheet exists; presets (Blend, Apple TV, Classic, Netflix, Outline, Large print, High contrast, Marquee), rounded corners, padding, edge distance, line spacing, reveal-as-spoken and file styling Keep/My look are not confirmed. | local [code] |
| Subtitle timing (offset) | Missing | Shift subtitles earlier or later. | local offset |
| Wrong subtitles? flow | Missing | Entry under subtitle menu for downloaded subtitles; remove or search Bazarr. | Plex refresh `/library/metadata/{id}/refresh` [INFERENCE] |
| Search subtitles (Bazarr) | Missing | Search Bazarr by score, language, provider, hearing-impaired flag; download; Plex refreshes; new track selected. | Bazarr REST API, `X-API-KEY` header [INFERENCE: check Bazarr's API docs]: episode/movie search and download endpoints |
| Check Plex again | Missing | Refreshes metadata only, never downloads twice. | `/library/metadata/{id}/refresh` [INFERENCE] |
| Downloaded-twin rules (don't offer a second download when one already exists) | Missing | Rules for when a downloaded subtitle duplicates one on the server. | streams [code/INFERENCE] |
| SpeechDock: reveal as spoken (word timing) | Missing | Subtitles appear word by word using timing from SpeechDock. | SpeechDock HTTP(S) origin, owner's own service [INFERENCE: check the service's API] |
| SpeechDock: address and on/off | Partial | Toggle plus address validation; no request is made. | local [code] |

## 6. Live TV
| Feature | Status | Behaviour | API |
|---|---|---|---|
| Guide with now/next, 3 hours then full day | Done | Program guide with channel rows. | `/livetv`, `/media/providers` [code] |
| Favourites / Recent / genre categories | Done | Category chips. | local, channel filters [code] |
| Tune and play | Done | Plays the tuned stream. | `/livetv/sessions`, transcode [code] |
| Surf across channels | Done | Quick channel changes. | local [code] |
| Record one airing / series rule | Done | Record this episode, the series or movie. | `/media/subscriptions` [code] |
| Edit rule; Delete Series | Done | Series settings and delete with confirmation. | `PUT`/`DELETE /media/subscriptions/{id}` [code] |
| Cancel one scheduled airing | Done | Swipe to cancel. | `DELETE /media/grabbers/operations/{id}` [code] |
| Recordings (Scheduled / Recorded) | Done | Lists upcoming and recorded items. | `/media/subscriptions/scheduled` [code] |
| Tuner sharing | N/A | Server-side plugin, not a phone feature. | — |

## 7. Settings
| Feature | Status | Behaviour | API |
|---|---|---|---|
| Video & playback page | Done | Direct Play mode, default aspect. | local [code] |
| Audio & subtitles page | Done | Preferred audio, subtitle mode, remember choices, style. | local [code] |
| Intro skip (manual/3/5/10/15/30s) | Done | Intro skip delay. | local [code] |
| Credits countdown | Done | Up Next delay. | local [code] |
| Auto sign-in, interface resolution, language | Missing | Not found in the iPhone code. | local |
| Trailers auto-play | Missing | Not found. | local |
| Favourite libraries | Done | Settings › Favorite Libraries: switched-off libraries leave Home's shelves and the Library title menu; one always stays on. | local |
| Privacy / consent (crash, product reports) | Missing | Opt-in reporting with its own explanation. | none (local) |
| Delete all local data | Done | Settings › Delete All Local Data, after a confirmation: signs out and removes Keychain items, preferences, themes, cached artwork and guide data; the sign-in screen says what happened. | local |
| Appearance (theme picker) | Done | Themes. | local [code] |
| Sign out | Done | Confirmation dialog. | local [code] |

## 8. Profiles
| Feature | Status | Behaviour | API |
|---|---|---|---|
| Plex Home profiles | Done | Switch profile, PIN pad. | `/home/users`, `/home/users/{id}/switch` [code] |
| Per-profile settings | Done | Settings saved per profile. | local [code] |

## 9. Integrations
| Feature | Status | Behaviour | API |
|---|---|---|---|
| Bazarr settings page (address, API key, Test connection, Forget key) | Missing | Connection to Bazarr. | Bazarr REST API `GET /api/system/status` [INFERENCE] |
| Sonarr / Radarr linked | Missing | Shown on Bazarr page. | Bazarr config [INFERENCE] |
| SpeechDock page | Partial | Toggle and address (no service calls yet). | local [code] |

## 10. Not on a phone
- TV remote focus and D-pad navigation: N/A.
- Tuner sharing: N/A (server plugin).

## Summary counts
Count the status column: `grep -c '| Done |' docs/PARITY.md` (likewise `Partial`, `Missing`, `N/A`).

## Gaps
- The TV's docs/ folder, CHANGELOG and player-submenus doc were not read. Rows rest on the locale strings and the iPhone's own spec. Mark rows as Unverified until those are read.
- The Plex and Bazarr endpoints marked [INFERENCE] are not confirmed against their API docs. Check them before build work.
- SpeechDock's own API is not known from the material read.
