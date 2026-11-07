# Marquee for iPhone

A native SwiftUI Plex client for iPhone, built for iOS 27. Sideloaded as an unsigned IPA (Feather or AltStore) from this repo's releases.

## Clean room

Marquee for iPhone shares a name and behaviour with the Marquee TV app, which is built on PlxNative (GPL-3). No PlxNative or Marquee TV code is copied, translated or structurally mirrored here. Behaviour comes from `docs/behaviour-spec.md` (a plain-English description) and from Plex's public HTTP API. Contributors to this repo do not read the TV app's source.

## Layout

- `App/`: the SwiftUI app (screens, player, theming).
- `Packages/MarqueeCore/`: Plex API client, connection choice, playback route decision, audio and subtitle rules. Foundation only, unit-tested with `swift test`; its API is summarised in `docs/core-api.md`.
- `Resources/`: `themes.json` (40 Lucent colour-role themes) and the Manrope font (OFL).
- `docs/DESIGN.md`: design direction. `docs/behaviour-spec.md`: behaviour.
- `tools/check_themes.py`: contrast and distinctness gate for `themes.json`; CI fails on any failing theme.

Video remux and transcode use [stashy-videoengine](https://github.com/nphil/stashy-videoengine) (FFmpeg, LGPL-2.1, linked statically; its source and build scripts are public in that repo).

## Building

There is no local Mac. GitHub Actions builds on the `xcode-27` runner image: core tests, an app build, simulator screenshots, and on `main` an unsigned IPA attached to a GitHub release.
