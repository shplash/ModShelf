<p align="center">
  <img src="assets/appicon.png" width="187" alt="ModShelf Icon">
</p>

<h1 align="center">ModShelf</h1>

<p align="center">
  Steam Workshop downloader for iOS
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

## Requirements

- iOS 16 or newer
- A Steam account that can sign in on the device
- The game in your Steam library: Steam only hands over a game's Workshop items when your account holds its license. Free-to-play games give you that license when you add them to your library once.

## Where mods go

```
On My iPhone → ModShelf → Downloaded Mods → <game name> → <mod>
```

Moving a mod into its game is normal use, so ModShelf shows those as moved out rather than broken, and keeps the install record for update checks.

## Build

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`:

```sh
xcodegen generate
xcodebuild -project ModShelf.xcodeproj -scheme WorkshopDownloader -sdk iphoneos build
```

The Steam engine is a Go module bound to iOS with `gomobile`. `.github/workflows/build-ipa.yml`
builds `SteamEngine.xcframework` from `ios-engine/`, packages an ad-hoc signed IPA and attaches it to a
private draft release ("ModShelf builds") that keeps only the latest build; only people with write
access can see it, and releases are published by hand from that build.

## License

ModShelf is licensed under MPL-2.0.

It bundles [go-steam](https://github.com/BirknerAlex/go-steam) by Alexander Birkner, which is MIT licensed; its notice is kept in the app's Credits section. MPL-2.0 and MIT combine without any extra licensing: MIT only asks that its copyright and permission notice stay with the code, and the two files simply keep their own licences.

## Notes

Steam and the Steam Workshop are trademarks of Valve Corporation. ModShelf is not made by or endorsed by Valve.

## <a href="https://ko-fi.com/shplash"><img src="https://img.shields.io/badge/Support-ko--fi-FF5E5B?style=for-the-badge" alt="Support"></a>

If ModShelf has been useful to you, you can support its development as well as future projects.
