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

## Install

Add this source in Feather or AltStore:

```
https://github.com/nphil/marquee-ios/releases/download/feed/apps.json
```

Each release also carries `Marquee.ipa` for a manual install. Marquee needs iOS 27.

## Building

There is no local Mac. GitHub Actions builds on the `xcode-27` runner image (`.github/workflows/ios.yml`):

- **Core:** the theme checker and the MarqueeCore tests.
- **App:** an unsigned Release build for iPhone, then UI tests on the iPhone 18 Pro simulator (iOS 27.0) that save a screenshot of each screen in several themes as the `screens` artifact.
- **Release** (`main` only): the IPA goes out as a GitHub release `vX.Y.Z`, one patch above the newest tag, and the source `apps.json` on the `feed` release gains that version. Nothing is committed back to `main`.

The Xcode project is generated from `project.yml` with XcodeGen and is not stored in git.
