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
- `"__anchor": T` at the top of a fixture moves every `beginsAt` and `endsAt` in it by 9 PM today minus T. The app draws the Live TV guide at 9:41 PM today while the fake Plex is active, so the guide fixtures, written around T = 1800000000, always air at the same times.
- `live.json` holds the Live TV favourites and recent channels each profile starts with.

The fake server is "Living Room", `fake-server`, at `http://192.0.2.10:32400`.

plex.tv lists four servers of the account and its Home: Living Room (reached locally), Cabin (remote only), Office (relay only) and Studio (Alex's, offline), plus a friend's server the app leaves out. The browser sign-in code is approved at once; the plex.tv/link code never is. The Home has three profiles: Jordan (the account), Alex (PIN 1234) and Kids (restricted). Their photos, `users/<uuid>/avatar.png`, are generated silhouettes.

Living Room has two libraries. Movies holds eleven Blender open movies: Sintel is half watched and has two versions (4K Dolby Vision with Atmos, and 1080p) and a full set of tracks, Tears of Steel is part watched, Big Buck Bunny and Elephants Dream are watched. TV Shows holds Caminandes, one season of three episodes with the second in progress. One collection, Blender Open Movies, gathers the films. The watchlist on plex.tv holds Wing It! (not on the server), Spring, Caminandes, Cosmos Laundromat and Elephants Dream. Titles, years and credits are real; summaries, dates, ratings, files and watch state are invented.

Living Room has an antenna DVR with one four-tuner HDHomeRun and eight channels, 2.1 Metro 2 to 46.1 Music 46, guided from 7 PM to 11 PM the next day. The provider groups them into News, Sports, Movies and Kids. News 7 Tonight is recording, City Desk records as a series and Open Movie Night's Sintel as a single episode. Movies 5 and Public 13 are favourites; News 7, Metro 2 and Sports 9 were watched last. Music 46 has no logo, so its call sign stands in. Channels, programmes and logos are invented; Open Movie Night airs the Blender films with their frames.

## Artwork

`art/` holds frames from the films, cropped and resized to posters (400 × 600), backdrops (960 × 540) and episode stills (640 × 360). Each film's licence applies to its frames; the frames from the two CC BY-SA films are shared under CC BY-SA 3.0 as well. The source videos are on Wikimedia Commons.

- Big Buck Bunny (2008), Blender Foundation, CC BY 3.0. `File:Big_Buck_Bunny_4K.webm`
- Elephants Dream (2006), Orange Open Movie Team, Blender Foundation, CC BY 2.5. `File:Elephants_Dream_(2006).webm`
- Sintel (2010), Durian Open Movie Team, Blender Foundation, CC BY 3.0. `File:Sintel_movie_4K.webm`
- Tears of Steel (2012), Mango Open Movie Team, Blender Foundation, CC BY 3.0. `File:Tears_of_Steel_in_4k_-_Official_Blender_Foundation_release.webm`
- Cosmos Laundromat: First Cycle (2015), Gooseberry Open Movie Team, Blender Foundation, CC BY-SA 3.0. `File:Cosmos_Laundromat_-_First_Cycle_-_Official_Blender_Foundation_release.webm`
- Glass Half (2015), Blender Foundation, CC BY 4.0. `File:Glass_Half_-_Blender_Open_Movie-full_movie.webm`
- Caminandes: Llama Drama (2013), Pablo Vazquez, Beorn Leonard and Francesco Siddi, CC BY 3.0. `File:Caminandes-_Llama_Drama_-_Short_Movie.ogv`
- Caminandes: Gran Dillama (2013), Pablo Vazquez, Beorn Leonard and Francesco Siddi, Blender Foundation, CC BY-SA 3.0. `File:Caminandes_-_Gran_Dillama_-_Blender_Foundation's_new_Open_Movie.webm`
- Caminandes: Llamigos (2016), Blender Foundation, CC BY 3.0. `File:Caminandes_3_-_Llamigos_-_Blender_Animated_Short.webm`
- Hero (2018), Blender Foundation, CC BY 4.0. `File:HERO_-_Blender_Open_Movie-full_movie.webm`
- Spring (2019), Andy Goralczyk, Blender Foundation, CC BY 4.0. `File:Spring_-_Blender_Open_Movie.webm`
- Coffee Run (2020), Blender Foundation, CC BY 4.0. `File:Coffee_Run_-_Blender_Open_Movie-full_movie.webm`
- Sprite Fright (2021), Blender Studio, CC BY 4.0. `File:Sprite_Fright_-_Blender_Open_Movie-full_movie.webm`
- Charge (2022), Blender Studio, CC BY 4.0. `File:Charge_-_Blender_Open_Movie-full_movie.webm`
- Wing It! (2023), Blender Studio, CC BY 4.0. `File:WING_IT!_-_Blender_Open_Movie-full_movie.webm`
