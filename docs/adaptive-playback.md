# Adaptive playback

Auto quality, the default, plays Original at home and adapts away from home. Plex converts on the fly, so there is no ready-made ladder of aligned streams to hop between: each step is a new server stream at one of the `VideoQuality` presets, opened beside the playing one and swapped in at a movie time ahead of the playhead.

## Where the phone is (`NetworkPlace`)

Plex's own flag says only which address answered. Away from home with a VPN that routes the home subnet (Tailscale subnet routes), the LAN address answers through the tunnel and looks local. The place is decided from the address in use:

1. A relay address is away.
2. A request that left the phone from a tunnel address (100.64.0.0/10, Tailscale's fd7a:115c:a1e0::/48), or a server address inside those ranges, is away.
3. A server IP (plex.direct names spell it) on a network one of the phone's own interfaces is attached to, tunnels excluded, is home. A local IP on no attached network is reached through a tunnel: away.
4. A host name is home only when Plex calls it local and the round trip is under 25 ms.

The phone-side address and round trip come from URLSession's metrics for the app's requests to the server. With Tailscale on at home, iOS keeps the Wi-Fi network's own route ahead of an advertised subnet route that overlaps it (tailscale/tailscale#14142), so LAN traffic goes direct; rule 2 makes the tunnel visible if that ever changes, and stats for nerds shows the place. AVPlayer cannot be pinned to an interface, so the app does not steer around the tunnel.

Away also turns a file that needs the remux into a server stream (`RouteLimits.remoteConnection`).

## Choosing a rung (`AdaptiveQuality`)

The ladder is Original plus every preset below the file's bitrate. Throughput is two moving averages of the link speed (half-lives 3 s and 10 s), the lower of them counting: bytes over active transfer time from AVPlayer's access log, or the remux's source rate. Buffer is media on the phone ahead of the playhead.

- **Start.** Home: Original. Away: the highest rung that fits the last measured link, or 4 Mbps with no measurement, climbing from there. A rung fits when its rate is at most 70% of the estimate.
- **Down.** A wait on the network of 2 s, or under 12 s of buffer with the estimate below the rung's rate: down to the highest rung that fits, at least one step.
- **Up.** The estimate fits a higher rung for 10 s straight, the buffer holds 10 s, and the last switch was 20 s ago: up to the highest rung that fits.
- **Hysteresis.** Down needs the estimate below the rate; up needs it at 1/0.7 of the target's, so estimates in between change nothing. A drop within 60 s of a climb doubles the wait before the next climb (once per climb, to 160 s at most); 5 minutes without a drop resets it.

Picking a fixed quality turns Auto off for the profile; Settings and the player's quality menu both offer Auto, and the menu shows the rung playing ("Auto · 8 Mbps 1080p"). The lower-quality offer after a long wait is for fixed qualities only: Auto steps down by itself. Force Direct Play never adapts. Stats for nerds shows the place and Auto's rung and link estimate.

## Switching without a stop

The new stream opens on a second, muted AVPlayer at the playhead plus 8 s, is positioned there and prerolled, and replaces the playing one when the playhead reaches that time (a boundary time observer). The old stream then stops. The standby's picture is drawn unseen above the playing one and covers the swap until the main layer draws. `VideoBackend` carries this: `openStandby`, `prerollStandby(at:)`, `armSwitch(at:)`, the `.switchDue` event, `switchToStandby` and `discardStandby`.

A plain restart at the playhead, the old behaviour, is used instead when Picture in Picture or AirPlay is active (both follow one player), when the app is in the background, when the new route is a remux or changes the sound or subtitle, when less than 9 s is buffered, or when the new stream is not ready by the switch time. A pause, a seek, a track change or a 2 s wait on the network gives the standby up; Auto looks again 2 s later.

## Per-title quality scores

`QualityScores` holds a title's VMAF score per rung. With scores, Auto climbs no higher than the lowest rung within 1.5 points of the best score, so a cartoon that looks the same at 8 Mbps does not pull 20. Nothing supplies scores yet; a server-side analysis would fill them per title.

## Open: Picture in Picture shows LIVE for a remux

The remux playlist has no end tag until the run finishes, so Picture in Picture treats a remuxed movie as live and shows LIVE without a scrubber. A finite playlist needs the engine to write the full VOD playlist up front (segment boundaries from the index), released through VideoEngine and pinned here. For the live renderer, which already draws sample buffers, `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)` with a finite `timeRange` is cheap; AVPlayer content would need its frames copied out through `AVPlayerItemVideoOutput`, losing HDR and Dolby Vision and costing power, so it is not the way for movies.
