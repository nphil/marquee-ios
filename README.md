# Marquee for iPhone

A native SwiftUI Plex client for iPhone, built for iOS 27. Sideloaded as an unsigned IPA (Feather or AltStore) from this repo's releases.

## Clean room

Marquee for iPhone shares a name and behaviour with the Marquee TV app, which is built on PlxNative (GPL-3). No PlxNative or Marquee TV code is copied, translated or structurally mirrored here. Behaviour comes from `docs/behaviour-spec.md` (a plain-English description) and from Plex's public HTTP API. Contributors to this repo do not read the TV app's source.

## Layout

- `App/`: the SwiftUI app (screens, player, theming).
- `Packages/MarqueeCore/`: Plex API client, connection choice, playback and live route decisions, audio and subtitle rules. Foundation only, unit-tested with `swift test`; its API is summarised in `docs/core-api.md`.
- `Packages/MarqueeLive/`: Live TV played straight from an HDHomeRun-protocol tuner (FFmpeg decode into sample-buffer layers). iOS only; tested on a simulator.
- `UITests/`: UI and screenshot tests, answered by the synthetic Plex server in `UITests/FakePlex/`.
- `Resources/`: `themes.json` (40 Lucent colour-role themes), the Manrope font (OFL), the app icon, and `Licences/engine`: the licence files of the linked stashy-videoengine release, shown under Open-Source Notices.
- `docs/`: `ARCHITECTURE.md` (layers and why), `DESIGN.md` (design direction), `behaviour-spec.md` (behaviour), `PARITY.md` (feature parity with Marquee TV), `LIVE-TV.md` (Live TV), `DEVICE-TEST.md` (playback checks that need a real iPhone), `core-api.md`.
- `tools/check_themes.py`: contrast and distinctness gate for `themes.json`; CI fails on any failing theme.
- `AGENTS.md`: the guide for coding agents and new contributors.

Video remux and transcode use [stashy-videoengine](https://github.com/nphil/stashy-videoengine) (FFmpeg, LGPL-2.1, linked statically; its source and build scripts are public in that repo).

## Install

Add this source in Feather or AltStore:

```
https://raw.githubusercontent.com/nphil/marquee-ios/main/apps.json
```

Each release also carries `Marquee.ipa` for a manual install. Marquee needs iOS 27.

## Building

There is no local Mac. GitHub Actions builds on the `xcode-27` runner image (`.github/workflows/ios.yml`):

- **Core:** the theme checker and the MarqueeCore tests.
- **Live engine:** the MarqueeLive package's tests on the iPhone 18 Pro simulator.
- **App:** an unsigned Release build for iPhone, then UI tests on the iPhone 18 Pro simulator (iOS 27.0) that save a screenshot of each screen in several themes as the `screens` artifact, and a second pass with Increase Contrast and accessibility text sizes.
- **Release** (`main` only, after the three above): the IPA goes out as a GitHub release `vX.Y.Z`, one patch above the newest tag, and CI commits the new version to `apps.json` on `main` (`[skip ci]`). `apps.json` is CI-owned; never edit it by hand.

MarqueeCore's tests also run on Linux with a Swift 6.2 or newer toolchain: `swift test --build-system native --package-path Packages/MarqueeCore`.

The Xcode project is generated from `project.yml` with XcodeGen and is not stored in git.
