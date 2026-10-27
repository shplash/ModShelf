<p align="center">
  <img src="Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="220" alt="ModShelf Icon" style="border-radius: 22%">
</p>

<h1 align="center">ModShelf</h1>

<p align="center">
  Steam Workshop downloader for iPhone
</p>

<p align="center">
  <a href="https://github.com/shplash/ModShelf/stargazers">
    <img src="https://img.shields.io/github/stars/shplash/ModShelf?style=for-the-badge&label=stars&color=729864">
  </a>

  <a href="https://raw.githubusercontent.com/shplash/shplash-repo/main/apps.json">
    <img src="https://img.shields.io/badge/AltSource-Get-729864?style=for-the-badge">
  </a>

  <br>

  <a href="https://github.com/shplash/ModShelf/releases/latest">
    <img src="https://img.shields.io/github/v/release/shplash/ModShelf?style=for-the-badge&label=release&color=0A84FF">
  </a>

  <a href="https://github.com/shplash/ModShelf/releases/latest/download/ModShelf.ipa">
    <img src="https://img.shields.io/badge/Download-IPA-0A84FF?style=for-the-badge">
  </a>

  <br>

  <a href="https://github.com/shplash/ModShelf/issues">
    <img src="https://img.shields.io/github/issues/shplash/ModShelf?style=for-the-badge&label=open%20issues&color=6E7681">
  </a>
</p>

<p align="center">
If you found ModShelf useful, a GitHub star is always appreciated.
</p>

## Features

- Sign in to Steam and keep the session between launches
- Paste a Workshop link, or browse the Workshop in the built-in browser
- Downloads sorted into a folder per game inside ModShelf's storage
- Library with search, tags, game filter, favourites and bulk select
- Update checks, file verification and ZIP export
- Native SwiftUI, with Files app access for every mod

## Example

<p align="center">
  <img src="assets/example1.png" width="300" alt="ModShelf library">
  <img src="assets/example2.png" width="300" alt="ModShelf details">
</p>

## Install

1. Download `ModShelf.ipa` from the [latest release](https://github.com/shplash/ModShelf/releases/latest).
2. Install it with a sideloading tool that signs for your device.
Use:
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
builds `SteamEngine.xcframework` from `ios-engine/`, packages an ad-hoc signed IPA and publishes it.

## Notes

Steam and the Steam Workshop are trademarks of Valve Corporation. ModShelf is not made by or endorsed by Valve.

## Support <a href="https://ko-fi.com/shplash"><img src="https://img.shields.io/badge/Support-ko--fi-FF5E5B?style=for-the-badge" alt="Support"></a>

If ModShelf has been useful to you, you can support its development as well as future projects.
