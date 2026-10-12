# LolPing

[![Release](https://img.shields.io/github/v/release/icloudza/lol-ping)](https://github.com/icloudza/lol-ping/releases/latest)
![Platform](https://img.shields.io/badge/macOS-14%2B-blue)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**English** | [简体中文](README.zh-CN.md)

League of Legends ping wheel and emotes for the macOS desktop: ping over any app, on any display, and see each other's pings in a shared room.

A native Swift menu bar app (AppKit · SwiftUI · Core Animation) for Apple silicon and Intel.

## Features

- **Ping wheel**: hold ⌥ and drag, release on a slice, and the ping appears at the pointer with its animation and sound.
- **Emote wheel**: hold ⌃ and drag. Add your own images (PNG, JPG, GIF, WebP).
- **Rooms**: join with a room code, directly over the local network or through internet relays, end-to-end encrypted. Compatible with the Windows and Mac clients of [darrenprx/lolPing](https://github.com/darrenprx/lolPing).
- **Every key is configurable**: wheel triggers can be modifier combinations, any key, or a mouse side button; pause, mute, and sending a specific ping or emote can each have a global shortcut.
- **Multiple displays**, English and Chinese interface, open at login.

## Install

1. Download `LolPing-<version>.dmg` from [Releases](https://github.com/icloudza/lol-ping/releases/latest) and drag LolPing into Applications.
2. On first launch, allow LolPing under **System Settings → Privacy & Security → Accessibility**.

Requires macOS 14 or later.

## Default keys

| Action | Keys |
| --- | --- |
| Send a ping | Hold **⌥** and drag, release on a slice |
| Send an emote | Hold **⌃** and drag, release on an emote |
| Cancel | Release in the middle, right-click, or press **Esc** |
| Pause / resume | **⌃⌥P** |

Change them under **Settings → Shortcut**.

## Build

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The project file is generated from `project.yml`; regenerate it after adding or removing source files.

```bash
xcodegen generate
```

```bash
xcodebuild -project LolPing.xcodeproj -scheme LolPing -configuration Release -derivedDataPath build build
```

Tests:

```bash
swift test --package-path Packages/LPCore
```

```bash
swift test --package-path Packages/LPRooms
```

The Debug configuration builds **LolPing-Dev** (`com.cloudza.LolPing.dev`), whose settings and Accessibility grant are separate from the released app's.

## Project layout

| Path | Contents |
| --- | --- |
| `App/` | The app: event tap, overlay windows and animations, sound, menu bar, settings, localization |
| `Packages/LPCore` | Gesture recognition, key model, preferences, ping and emote catalogs |
| `Packages/LPRooms` | Room protocol, encryption, LAN UDP, Nostr relays |
| `Scripts/release/` | Release scripts, documented in [Scripts/release/README.md](Scripts/release/README.md) (Chinese) |

## Releasing

Pushing a `vX.Y.Z` tag makes GitHub Actions test, sign, notarize, package a DMG and create the release. The app checks this repository's latest release and tells you when a newer version is out; it never downloads or installs anything by itself.

## Links

- [LINUX DO](https://linux.do)

## License

Code is released under the [MIT License](LICENSE). `Packages/LPRooms` is ported from [darrenprx/lolPing](https://github.com/darrenprx/lolPing) (© Danrui Meng, MIT).

The ping icons, emotes and sounds in `App/Resources` are © Riot Games and are not covered by the MIT License. See [NOTICE.md](NOTICE.md).

LolPing isn't endorsed by Riot Games and doesn't reflect the views or opinions of Riot Games or anyone officially involved in producing or managing Riot Games properties. Riot Games, and all associated properties are trademarks or registered trademarks of Riot Games, Inc.
