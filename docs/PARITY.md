# Feature parity with Marquee TV

Behaviour only (clean room): TV-side rows come from the TV app's user-facing strings and docs, never its code.

## Legend
- **Done**: works in the iPhone app.
- **Partial**: some of it exists; the gap is named.
- **Missing**: no iPhone code found.
- **N/A**: does not apply on a phone (D-pad navigation etc.).

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
| Stats logging (opt-in) | N/A | The iPhone app sends no usage reports, so there is nothing to opt in to; Stats for Nerds stays local. | none |

## 2. Detail actions
| Feature | Status | Behaviour | API |
|---|---|---|---|
| Play / Resume | Done | Play or resume; label shows 'Resume · N min left'. | `/library/metadata/{key}`, timeline [code] |
| Play from Beginning | Done | Starts again from zero. | `viewOffset=0` [code] |
| Mark Watched / Unwatched | Done | Toggles watched state on title or episode. | `/:/scrobble`, `/:/unscrobble` [code] |
| Mark show watched | Done | Mark Show Watched / Unwatched on a show's page (the check button), in the long-press menu of a show's poster in the library grid and shelves, and on an episode in Continue Watching; Mark Season Watched / Unwatched in the menu beside the season name. Plex marks every episode; badges, episode checks and Continue Watching change at once, and Undo is offered. | `/:/scrobble`, `/:/unscrobble` with the show's or season's `ratingKey` [code] |
| Remove from Continue Watching | Done | Removes a title from the continue row. | `/:/unscrobble` / on-deck [code] |
| Cast shelf | Done | Circular photos with names. | `roles` in metadata [code] |
| Related titles | Done | Related shelves on the detail page. | `/library/metadata/{key}/related` [code] |
| Extras (bonus videos) | Done | Movie and show pages: a shelf of 16:9 cards (kind and length); tapping one plays it. | `/library/metadata/{key}/extras` |
| Trailer | Done | More menu › Play Trailer: the server's primary extra, else the first trailer. | `primaryExtraKey`, `/library/metadata/{key}/extras` |
| Add to Watchlist | Done | Adds or removes from watchlist. | watchlist API [code] |
| **Delete media** (remove the file from the server) | Done | More menu › Delete… on a movie, show, season or episode, and Delete This Version… for a title with several files. Shown only on the owner's server, from the owner's profile, with Allow media deletion on; confirmation names the title, Cancel is the default. A deleted title leaves every list at once (Home, Continue Watching, library grids, search, seasons and episodes, a watchlist title's server copy) and its artwork leaves the caches; the server still lists it until its trash is emptied, so refetched lists keep it out for the session. 404 counts as deleted; 401/403 explains the server setting with no retry; a fault or no answer offers Retry. A delete waits up to 180 s; after a 5xx or a timeout the item is read again three times (1, 2 and 4 s apart) and counts as deleted once it answers 404. The item's guid (an episode's or season's show guid) is read before the DELETE. A deleted movie or show leaves the Watchlist if it is on it; an episode or season takes its show off only when the show has no episode left (empty `allLeaves`, or 404). A 404 before or during the delete still cleans the Watchlist from the on-screen identity. Not being on the Watchlist counts as success; the removal is tried three times, 0.5 and 1 s apart, and then the toast reads “Deleted, but couldn't remove it from your Watchlist.” The title leaves the Watchlist screen at once. | `DELETE /library/metadata/{ratingKey}`, `…/media/{id}`; `allowMediaDeletion` on `/`; `/library/metadata/{showKey}/allLeaves`; discover `…/userState`, `PUT /actions/removeFromWatchlist` [code] |

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
| Playback speed 0.5x–2x | Done | More menu › Speed: 0.5×, 0.75×, Normal, 1.25×, 1.5×, 1.75×, 2×; back to Normal for each new item; pitch kept. | local (`AVPlayer.defaultRate`) |
| Quality picker in player | Done | More menu › Quality (Original, 20, 12, 8, 4, 2 Mbps); "Original · Converted" while the server re-encodes. Picking one also sets the default. | `maxVideoBitrate`, `videoResolution` on transcode |
| Default quality ceiling (Settings) | Done | Video & Playback › Default Quality; Forced Direct Play reads "original quality". | local setting |
| Normalize loudness / Boost dialog (Plex Pass) | Done | More › Audio Enhancements toggles, shown only for a Plex Pass server; each reason they cannot apply is shown. The server reworks the sound on a copy of the video; on-device processing is not used because AVPlayer gives no audio tap on HLS streams. | `boostDialog=1`, `normalizeLoudness=1` on transcode; `Stream.canNormalizeLoudness` |
| Stats for Nerds | Done | Route, stream and bitrate overlay. | local [code] |
| Playback Info sheet | Done | Route, subtitle track, bitrate, frame rate. | local [code] |
| AirPlay / Picture in Picture | Done | AirPlay and the PiP button in the top row; leaving the app while a film or a live channel plays starts PiP; AirPlay stream handling. | AVKit [code] |
| Chromecast | Done | Settings › Chromecast turns it on; the route popover lists receivers. The receiver plays the file or the server's HLS with subtitles burned in; controls, Skip Intro, Up Next and watched state follow it. Untested on hardware. | Google Cast SDK; `/security/token`, `/video/:/transcode/universal/start.m3u8` [code] |
| Resume position | Done | Starts at saved offset. | `viewOffset` [code] |
| Watched threshold | Done | Marks watched near the end. | timeline [code] |
| Remote-control focus | Done | On the big screen only (XR glasses or TV, DESIGN §8.9): one focus on the screen, moved by swipes on the phone, which is the remote. | — |

## 4. Audio
| Feature | Status | Behaviour | API |
|---|---|---|---|
| Audio track selector | Done | Pick track; wanted-language first; check on playing track. | streams [code] |
| Preferred audio language | Done | Per-profile preference. | local [code] |
| Follow-dub rule | Done | Subtitles follow the audio: English audio takes the dub transcript (SDH or CC flag, `.cc`/`.sdh`, a Dub or Dubtitle title), other audio the full translation; a downloaded track beats a built-in one. Switching audio picks again unless the viewer chose the subtitle or the show remembers one; Off and on-screen text are left alone. Audio & Subtitles › Follow the Audio turns it off. | local [code] |
| Normalize loudness / Boost | Done | See Playback. | `boostDialog`, `normalizeLoudness` |

## 5. Subtitles
| Feature | Status | Behaviour | API |
|---|---|---|---|
| Off / the viewer's language | Done | The Tracks menu offers Off and one language row, which puts the usual track on screen: full ahead of SDH, text ahead of pictures. On-screen-text and other-language tracks are not offered; a track the file turned on stands ticked under the two rows. | streams [code] |
| Sidecar (external) subtitle download | Done | Downloads an external subtitle file and reads it. | `/library/streams/{id}` [code] |
| Image subtitles (PGS, DVB, VOBSUB) | Done | Drawn as bitmaps. | streams [code] |
| Image-subtitle badges and no-restyle rule | Done | Image subtitles keep their own size and position; Subtitle Style offers them only Colour and Soften Brightness and says why. | local |
| Subtitle style (size, position, colour, background, presets, live preview) | Done | In the player, Subtitle Style is a submenu of the Tracks menu (Look, Size, Colour, Position, Reveal as Spoken) that stays up while choices apply, over the subtitles. Settings holds the rest: the TV's presets, fonts, edges, boxes, rounded corners, padding, edge distance, line spacing, file styling Keep/My Look, with a live preview over sample scenes. | local [code] |
| Subtitle timing (offset) | Done | Shifts subtitles earlier or later for the playing item. | local offset [code] |
| Find subtitles | Done | One Tracks menu action: Bazarr first for up to 20 s, then Plex's own agents by themselves when Bazarr is not set up, unreachable, slow or empty in the language. A banner names the source being asked and the outcome. Asking again brings another file. | Bazarr REST API; Plex `GET`/`PUT /library/metadata/{id}/subtitles` [code] |
| Check Plex again | Done | A file Plex had not listed when its search ended is looked for first by the next Find, which refreshes metadata only and never downloads twice. | `/library/metadata/{id}/refresh` [code] |
| Downloaded-twin rules (don't offer a second download when one already exists) | Done | A finished download is not fetched again, a Plex result the item already lists is not added again, and a file fetched again replaces its earlier copy in the menu. | streams, release name and language [docs] |
| Plex agent subtitle search | Done | Plex results can be added and shown once Plex lists the file. | `GET`/`PUT /library/metadata/{id}/subtitles` [code] |
| SpeechDock: reveal as spoken (word timing) | Done | Words appear as they are said, timed by SpeechDock for an English text file over English audio; any other subtitle, or no answer, keeps the estimate. | SpeechDock `POST /api/alignment/windows`, protocol 1 [code] |
| SpeechDock: address and on/off | Done | A valid address turns it on and an empty one off, as on the TV; plain http:// only on the home network. | SpeechDock `GET /health` [code] |

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
| Video & playback page | Done | Direct Play mode, default aspect, Video Orientation (Follow Device, Start in Landscape, Lock to Landscape). | local [code] |
| Audio & subtitles page | Done | Preferred audio, subtitle mode, remember choices, style. | local [code] |
| Downloads | Partial | Download a movie or episode as Original or at High, Medium or Low from its page or the … menu, or a season or show's episodes at the default quality. Each choice shows its picture size and download size; the tiers aim at VMAF 95, 90 and 85, from HomeLabber's measured map when its plugin is set up and the title is measured, otherwise estimated from the file's resolution, bitrate, codec, frame rate and genre. A tier is converted by the server while its segments download, in the background too; the download queue makes it when the server will not stream it. The Downloads screen groups them by show and movies, each row with a still, size, resolution, quality, duration, watched progress and state, and ends in a storage bar of Marquee, other and free space; Play, Pause, Resume and Remove work by tap, swipe, context menu or Select, and Settings › Downloads sets transfers, playback, cellular, background and watched-deletion preferences. On cellular only with cellular downloads off, a row says Waiting for Wi-Fi and offers Download on Cellular, which turns the setting on; after two failed tries in a row it says the server can't be reached while it keeps trying. A transfer that gets no answer from its address makes the next one probe for an address that answers. Device and server behavior remains unverified. | Plex transcode decision and HLS segments, download queue, file byte ranges; HomeLabber `/api/media-quality/v1` [code] |
| Intro skip (manual/3/5/10/15/30s) | Done | Intro skip delay. | local [code] |
| Credits countdown | Done | Up Next delay. | local [code] |
| Auto sign-in | N/A | The iPhone keeps its session in the Keychain and opens straight to the last profile, so there is no sign-in step to skip. | local |
| Interface resolution | N/A | A TV output-size setting; an iPhone draws at its own screen size. | local |
| Language | N/A | The interface language follows the iPhone's per-app language in iOS Settings. | local |
| Trailers auto-play | Done | Settings › Video & Playback › Play Trailers Automatically, on by default, per profile. After 2 s on a movie's or show's page its trailer plays in the hero with sound, once, from a file the iPhone plays untouched; no watch state is written. It waits in Low Power Mode, with Reduce Motion, on cellular or in Low Data Mode, while the app is inactive, the hero is scrolled off or the player is open; the sound follows the silent switch and mixes with other apps, and a trailer is silent over audio already playing. | `/library/metadata/{key}/extras`, part file [code] |
| Favourite libraries | Done | Settings › Favorite Libraries: switched-off libraries leave Home's shelves and the Library title menu; one always stays on. | local |
| Privacy / consent (crash, product reports) | N/A | Nothing is reported from the iPhone app, so there is no consent to ask for; Delete All Local Data covers what is stored on the phone. | none (local) |
| Delete all local data | Done | Settings › Delete All Local Data, after a confirmation: signs out and removes Keychain items, preferences, themes, cached artwork and guide data; the sign-in screen says what happened. | local |
| Appearance | Done | Settings › Appearance: Theme (theme picker), Tab Bar, Header Style, Show Scroll Bars. | local [code] |
| Sign out | Done | Confirmation dialog. | local [code] |

## 8. Profiles
| Feature | Status | Behaviour | API |
|---|---|---|---|
| Plex Home profiles | Done | Switch profile, PIN pad. | `/home/users`, `/home/users/{id}/switch` [code] |
| Per-profile settings | Done | Settings saved per profile. | local [code] |

## 9. Integrations
| Feature | Status | Behaviour | API |
|---|---|---|---|
| Bazarr settings page (address, API key, Test connection, Forget key) | Done | Connection to Bazarr; the key is kept in the Keychain. | Bazarr REST API `GET /api/system/status` [code] |
| Sonarr / Radarr linked | Done | The Bazarr page's connection test names the linked Sonarr and Radarr versions. | Bazarr `/api/system/status` |
| SpeechDock page | Done | Address with its checks, and Test Connection naming the service's version. | SpeechDock `GET /health` [code] |
| HomeLabber Quality Map page (address, token, Test Connection, Forget token) | Done | Off until set up; the token is kept in the Keychain. Test Connection says how many titles HomeLabber has measured. Download tiers use the measured bitrates. | HomeLabber `GET /api/media-quality/v1/status`, `/servers/{machineIdentifier}/items/{ratingKey}` [code] |
| Linked phones plugin | Done | iPhone only; off until enabled. Two iPhones linked once by a QR code control each other when near each other with Wi-Fi switched on (no network needed) or on the same Wi-Fi: the eyes-free remote for one driving a TV or glasses, or a few player controls for one playing on its own screen, with the volume of what it plays (DESIGN §8.10). | Bonjour `_marquee-link._tcp`, Noise NNpsk0 over TCP, Keychain, AVFoundation QR reading [code] |
| Seerr page (address, Plex profile or API key, Test Connection) | Done | Requests becomes a tab or a Library destination once connected; the API key is kept in the Keychain. | Seerr `/api/v1/status`, `/auth/plex`, `/auth/me`, `/settings/public` [code] |
| Seerr Discover | Done | Trending, Popular Movies, Movie Genres, Upcoming Movies, Popular Series, Series Genres and Upcoming Series rows; each loads as it nears the screen and hides if it fails. | `/discover/trending`, `/discover/movies`, `/discover/tv`, `/discover/movies/upcoming`, `/discover/tv/upcoming`, `/discover/genreslider/{movie,tv}` [code] |
| Seerr browse and filters | Done | See all or a genre card opens a paged poster grid: Movies \| Series, genre chips and one View menu (sort, release decade, original language, rating, runtime, streaming service and region, upcoming only). | `/discover/movies`, `/discover/tv`, `/genres/{movie,tv}`, `/languages`, `/watchproviders/{regions,movies,tv}` [code] |
| Seerr request and status | Done | Posters badge a title's status (available, partially available, processing, pending and so on); a title page requests a movie or chosen seasons. | `/movie/{id}`, `/tv/{id}`, `POST /request`, `GET /request` [code] |
| Big screen plugin (XR glasses and TV) | Done | Off until enabled. Glasses or a TV (USB-C video out, HDMI adapter) connected as a display get their own screen, 1920 × 1080 for glasses and the display's own shape and pixels for a TV, with 5 % overscan margins and the theme's dark canvas on a TV (black on glasses). AirPlay mirroring is not handled. The answer and Display Type are kept per display. Pages: Home, libraries, detail, seasons, search, Seerr requests, downloads, Live TV and the player with its tracks. The phone becomes an eyes-free remote (DESIGN §8.9). | UIKit external display scene (`UIWindowSceneSessionRoleExternalDisplayNonInteractive`), Core Haptics, Core Motion [code] |

## 10. Not on a phone
- D-pad navigation: N/A; on XR glasses the phone's swipes stand in for it (§3).
- Tuner sharing: N/A (server plugin).

## Summary counts
Count the status column: `grep -c '| Done |' docs/PARITY.md` (likewise `Partial`, `Missing`, `N/A`).

## Gaps
- The TV's docs/ folder, CHANGELOG and player-submenus doc were not read. Rows rest on the locale strings and the iPhone's own spec. Mark rows as Unverified until those are read.
- The Plex and Bazarr endpoints marked [INFERENCE] are not confirmed against their API docs. Check them before build work.
- SpeechDock's API is read from the service's own source: `POST /api/alignment/windows`, protocol 1.
