# Adaptive playback

Auto quality is the default and adapts to the measured link. Plex converts on the fly, so there is no ready-made ladder of aligned streams to hop between: each step is a new server stream at one of the `VideoQuality` presets, opened beside the playing one and swapped in at a movie time ahead of the playhead.

## Home presence (`HomePresence`)

Playback does not judge where the phone is. `HomePresence` is independent proof for the optional TV remote only. The remote's open session directly over Wi-Fi establishes home. Without one, a probe completes the paired TV's encrypted handshake and closes without opening a remote session. Failed probes retain home for at most 30 seconds from the last success. A network change invalidates proof immediately. Probes run only while the plugin is enabled and the app is foregrounded.

## How near the server is (`RouteReach`)

The measured link alone decides whether the phone reads a file that needs the remux itself, at any address but a relay, which always converts. A reading of at least 3 times the file's bitrate and 20 Mbps lets the phone's remux read it; less sends the file to the server. A reading counts for 30 minutes and only at its server address on the network it was taken on (`LinkMemory`). Without one, any start but direct play reads the first 4 MB of the file, for half a second at most, and the route and Auto's start go by that reading (`LinkProbe`); a failed read leaves the link unmeasured, and the server streams the file. Playback info says why: "Server at 131 Mbps, fast enough for the original".

The server's own limits win. Before the phone reads the original, Marquee asks Plex what it would make of the file's video; a picture under nine tenths of the file's rate is a limit (remote streaming quality, the user's own), and the server streams it (`ServerLimit`). A quality cap or Direct Play off converts whatever the link measures. A phone that fails to read the file over a measured link ignores that link's readings until the network changes. Direct play does not depend on the link.

Save Data, off by default, caps the quality at 720p, 4 Mbps (`PlayerModel.savedDataCap`), on mobile data, a personal hotspot or Low Data Mode (`NWPath.isExpensive` or `isConstrained`): Auto climbs no higher, and a fixed quality above it plays at the cap. Moving on or off such a network mid-film applies or lifts the cap at the playhead.

## Choosing a rung (`AdaptiveQuality`)

The ladder is Original plus watchable presets below the file's bitrate. For a source and viewing picture both at least 1080 pixels on their short edge, the lowest preset is 8 Mbps; otherwise it is 4 Mbps. A source below 720 pixels on its short edge has only Original, as does a file whose bitrate leaves no eligible preset. With missing dimensions, the source defaults to 1080 for floor selection and 720 for ladder eligibility, and the view defaults to 720. Throughput is two moving averages of the link speed (half-lives 3 s and 10 s), the lower of them counting: bytes over active transfer time from AVPlayer's access log, or the remux's source rate. Buffer is media on the phone ahead of the playhead.

- **Start.** A measured link selects the highest eligible rung that fits, subject to any quality-score ceiling and Save Data's cap. Without a measurement, Auto starts at the lowest eligible rung at or below 4 Mbps, or the lowest eligible rung if none does. A rung fits when its rate is at most 70% of the estimate; if none fits, the floor is retained.
- **Down.** A wait on the network of 2 s, or under 12 s of buffer with the estimate below the rung's rate: down to the highest rung that fits, at least one step.
- **Up.** The estimate fits a higher rung for 10 s straight, the buffer holds 10 s, and the last switch was 20 s ago: up to the highest rung that fits.
- **Hysteresis.** Down needs the estimate below the rate; up needs it at 1/0.7 of the target's, so estimates in between change nothing. A drop within 60 s of a climb doubles the wait before the next climb (once per climb, to 160 s at most); 5 minutes without a drop resets it.

When the floor's known rate exceeds 70% of the link estimate, or a network wait reaches 2 s at the floor, `belowFloor` reports that the connection cannot sustain the floor. Each accepted look recalculates this flag. The player explains a network wait with the quality warning rather than selecting a lower preset; the flag alone neither shows the warning nor holds the controls up. Looks carrying a different stream ID are ignored; callers may omit the ID.

A network change that keeps the same server address keeps playback and its policy, under Save Data's cap for the new network. At another address playback restarts on a fresh policy without measuring the ending stream; an item still loading starts again. A load fails if no server address answers.

Picking a fixed quality turns Auto off for the profile; Settings and the player's quality menu both offer Auto, and the menu shows the rung playing ("Auto · 8 Mbps 1080p"). The lower-quality offer after a long wait is for fixed qualities only: Auto steps down by itself. Force Direct Play never adapts. Stats for nerds shows how the link decided the route, Save Data's cap when it applies, and Auto's rung and link estimate.

## Picture scaling

Movie playback uses the platform's AVPlayerLayer to fill the picture surface; Live TV uses AVPlayerLayer or AVSampleBufferDisplayLayer. No separate enhancement or AI upscaler is present. Keep native scaling: additional processing is not justified without device comparisons showing a visible benefit and acceptable startup, playback reliability, latency, heat and battery cost. Those costs and image quality have not been measured here; scaling cannot restore detail absent from the source.

## Switching without a stop

The new stream opens on a second, muted AVPlayer at the playhead plus 8 s, is positioned there and prerolled, and replaces the playing one when the playhead reaches that time (a boundary time observer). The old stream then stops. The standby's picture is drawn unseen above the playing one and covers the swap until the main layer draws. `VideoBackend` carries this: `openStandby`, `prerollStandby(at:)`, `armSwitch(at:)`, the `.switchDue` event, `switchToStandby` and `discardStandby`.

A plain restart at the playhead, the old behaviour, is used instead when Picture in Picture or AirPlay is active (both follow one player), when the app is in the background, when the new route is a remux or changes the sound or subtitle, when less than 9 s is buffered, or when the new stream is not ready by the switch time. A pause, a seek, a track change or a 2 s wait on the network gives the standby up; Auto looks again 2 s later.

The preparation deadline is checked against playback even while the standby player is still opening or prerolling; a late completion cannot replace the fallback.

## Per-title quality: HomeLabber's map

With HomeLabber's quality map enabled (Settings › HomeLabber), Auto on a title it has measured streams at the best-looking size and bitrate the link carries, in place of the presets. The ladder is Original, then the steps of the title's curve (`QualityCurve.steps()`: about fifteen, each at least 1.5 VMAF better than the next cheaper one, all cheaper than the file). A step costs its video bitrate plus 192 kbit/s of audio and fits when that is at most 75% of the link estimate, a quarter kept for swings. Each size's curve is joined in log-bitrate and held flat outside the measured range, so nothing is guessed past it. A size is left out of a budget below Plex's own floor for it (480p 1050, 720p 2960, 1080p 6520 kbit/s); below the lowest step Auto holds that step and warns, as for the presets.

A step reaches the server as `RouteLimits.target`, which replaces the preset's cap and frame. Direct play, a fixed quality, Force Direct Play, a title HomeLabber has not measured and one measured for another version of the file (`mediaId`) keep the presets. The lookup is cached per session (`QualityMapCache`), asked for as the item starts and waited for at most 1.5 s; a later answer, and Auto picked in the player's menu mid-item, apply from the next item. A phone uses the curve HomeLabber measured for a phone screen (`vmafPhone`, `phoneTiers`) where it gives one; an iPad uses the general one.

`QualityScores` (a VMAF score per preset rung) still caps a preset ladder's climb: with scores, Auto climbs no higher than the lowest rung within 1.5 points of the best. Nothing supplies them, and a mapped ladder ignores them.

## Open: Picture in Picture shows LIVE for a remux

The remux playlist has no end tag until the run finishes, so Picture in Picture treats a remuxed movie as live and shows LIVE without a scrubber. A finite playlist needs the engine to write the full VOD playlist up front (segment boundaries from the index), released through VideoEngine and pinned here. For the live renderer, which already draws sample buffers, `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)` with a finite `timeRange` is cheap; AVPlayer content would need its frames copied out through `AVPlayerItemVideoOutput`, losing HDR and Dolby Vision and costing power, so it is not the way for movies.
