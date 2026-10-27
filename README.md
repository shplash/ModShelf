# ModShelf

A native SwiftUI Steam Workshop downloader for iPhone. Sign in to Steam, paste a Workshop link (or
browse the Workshop in the built-in browser), and ModShelf downloads the item into its own folder,
sorted per game, ready to copy into the game.

## What it does

- **Library** — every downloaded mod, in a grid or list, with search, tags, a game filter, sorting,
  favourites, bulk select, and a status per mod: up to date, update available, not checked yet, or
  files that no longer match Steam.
- **Downloads** — one mod at a time with a live progress panel, a queue for "update all", Wi-Fi-only
  mode, and per-mod install records so an update check still works after the files have been moved
  into a game.
- **Options** — appearance, tab bar style, scrolling title speed, haptics, GIF playback, checking for
  updates on launch, writing an info file into each mod, Steam account, and the folder everything
  lands in (also reachable from Files, thanks to file sharing).
- **Maintenance** — check for updates against the Workshop, verify files against Steam's size, and
  export one mod, a selection, or the whole library as a ZIP.

Mods live under `On My iPhone → ModShelf → Downloaded Mods → <game name>/`. Moving a mod into a game
is normal use, so ModShelf reports those as moved out rather than broken.

## Building

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`:

```sh
swift Scripts/make-app-icon.swift   # fills in a placeholder AppIcon.png only if none is committed
xcodegen generate
xcodebuild -project ModShelf.xcodeproj -scheme WorkshopDownloader -sdk iphoneos build
```

The Steam engine is a Go module bound to iOS with `gomobile`. `.github/workflows/build-ipa.yml`
builds `SteamEngine.xcframework` from `ios-engine/` and packages an ad-hoc signed IPA, published to the
`ios-build` release on every push to `main`. `engine.yml` runs the Go tests and
`ios-compatibility.yml` checks the engine still binds for iOS.

## Installing

Download `ModShelf.ipa` from the `ios-build` release and install it with any sideloading tool that
resigns the app for your device.

Steam and the Steam Workshop are trademarks of Valve Corporation. ModShelf is not made by or endorsed
by Valve.
