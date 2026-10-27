<p align="center">
  <img src="Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="220" alt="ModShelf Icon">
</p>

<h1 align="center">ModShelf</h1>

<p align="center">
  Native Steam Workshop downloader for iPhone
</p>

<p align="center">
  <a href="https://github.com/shplash/ModShelf/stargazers">
    <img src="https://img.shields.io/github/stars/shplash/ModShelf?style=for-the-badge&label=stars&color=729864">
  </a>

  <a href="https://github.com/shplash/ModShelf/issues">
    <img src="https://img.shields.io/github/issues/shplash/ModShelf?style=for-the-badge&label=open%20issues&color=6E7681">
  </a>

  <br>

  <a href="https://github.com/shplash/ModShelf/releases/tag/ios-build">
    <img src="https://img.shields.io/github/v/release/shplash/ModShelf?style=for-the-badge&label=release&color=0A84FF">
  </a>

  <a href="https://github.com/shplash/ModShelf/releases/download/ios-build/ModShelf.ipa">
    <img src="https://img.shields.io/badge/Download-IPA-0A84FF?style=for-the-badge">
  </a>

  <br>

  <a href="https://ko-fi.com/shplash">
    <img src="https://img.shields.io/badge/Support-ko--fi-FF5E5B?style=for-the-badge">
  </a>
</p>

<p align="center">
If you found ModShelf useful, a GitHub star is always appreciated.
</p>

## Features

- Sign in to Steam once; the session is kept between launches
- Paste a Workshop link or item ID, or browse the Workshop in the built-in browser
- Downloads land in `ModShelf/Downloaded Mods` with a folder per game
- Library with grid or list layout, search, tags, game filter, favourites and bulk select
- Per-mod state: up to date, update available, not checked yet, or files that no longer match Steam
- Install records, so an update check still works after a mod is moved into a game
- Verify files against Steam, check for updates, update all at once
- Export one mod, a selection, or the whole library as a ZIP
- Wi-Fi-only downloads, live progress, info file inside each mod, Files app access
- Native SwiftUI, no web wrappers around the UI

## Example

<p align="center">
  <img src="assets/example1.png" width="300" alt="ModShelf library">
  <img src="assets/example2.png" width="300" alt="ModShelf details">
</p>

<p align="center">
Drop screenshots at <code>assets/example1.png</code> and <code>assets/example2.png</code> to show them here.
</p>

## Install

1. Download `ModShelf.ipa` from the [ios-build release](https://github.com/shplash/ModShelf/releases/download/ios-build/ModShelf.ipa).
2. Install it with a sideloading tool that signs for your device.

ModShelf does not sign apps itself. Use:
- SideStore
- AltStore
- Feather
- LiveContainer
- TrollStore
- etc

## Where mods go

```
On My iPhone → ModShelf → Downloaded Mods → <game name> → <mod>
```

Moving a mod into its game is normal use, so ModShelf shows those as moved out rather than broken, and keeps the install record for update checks.

## Build

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`:

```sh
swift Scripts/make-app-icon.swift   # makes the committed icon a valid 1024x1024 app icon
xcodegen generate
xcodebuild -project ModShelf.xcodeproj -scheme WorkshopDownloader -sdk iphoneos build
```

The Steam engine is a Go module bound to iOS with `gomobile`. `.github/workflows/build-ipa.yml`
builds `SteamEngine.xcframework` from `ios-engine/`, packages an ad-hoc signed IPA and publishes it,
with a `version.json` the app's update check reads, to the `ios-build` release on every push to `main`.
`engine.yml` runs the Go tests, and `prune-runs.yml` clears old workflow runs on demand.

## Notes

Steam and the Steam Workshop are trademarks of Valve Corporation. ModShelf is not made by or endorsed by Valve.

## Support

If ModShelf has been useful to you, you can support its development as well as future projects.

[Support Me](https://ko-fi.com/shplash) ♡
