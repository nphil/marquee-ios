# Fake Plex fixtures

The UI tests launch the app with `MARQUEE_FAKE_PLEX` set to this folder. `App/Testing/FakePlex.swift` (debug builds only) then answers every Plex request from the files here, so screenshots never touch a real account or server. Everything in this folder is synthetic.

## Rules

- A request reads `<prefix>/<path>.json`: prefix `plextv` for plex.tv, `discover` for discover.provider.plex.tv, `pms` for any other host. `GET /library/metadata/12` on the fake server reads `pms/library/metadata/12.json`.
- `<path>@<name>=<value>.json` wins over `<path>.json` when the request has that query item, e.g. `plextv/api/v2/home/users/<uuid>/switch@pin=1234.json`.
- `"__status": 401` at the top of a fixture answers with that status.
- `hosts.json` maps a host to the machine identifier its `/identity` reports, or to `null` for a host that cannot be reached. Unlisted hosts report `fake-server`.
- Lists under `MediaContainer.Metadata` are filtered, sorted and paged like a server does for `type`, `guid`, `unwatched`, `unwatchedLeaves`, `sort` and `X-Plex-Container-Start`/`-Size`. `/hubs/search` keeps the entries whose title contains the query.
- Without a fixture, `firstCharacter` is counted from the `all` list beside it, and `/library/all` joins the `all` lists of the sections in `pms/library/sections.json`.
- `/photo/:/transcode` serves the file at its `url` item, and any URL ending in `.jpg` or `.png` serves the file at its own path, so `/art/sintel-poster.jpg` and `https://metadata-static.plex.tv/art/sintel-poster.jpg` both read `art/sintel-poster.jpg`.
- A write, or an action under `/:/` or `/actions/`, without a fixture answers 200 `{}`. Any other missing fixture answers 404.

The fake server is "Living Room", `fake-server`, at `http://192.0.2.10:32400`.

plex.tv lists four servers of the account and its Home: Living Room (reached locally), Cabin (remote only), Office (relay only) and Studio (Alex's, offline), plus a friend's server the app leaves out. The browser sign-in code is approved at once; the plex.tv/link code never is. The Home has three profiles: Jordan (the account), Alex (PIN 1234) and Kids (restricted). Their photos, `users/<uuid>/avatar.png`, are generated silhouettes.
