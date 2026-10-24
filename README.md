# SteamWorkshop-iOS

Native SwiftUI Steam Workshop downloader project intended to build on GitHub Actions, so no Mac or PC is required on the user's side.

## Included
- Native iOS interface with Download, Library and History tabs.
- Paste a Workshop item URL or numeric published-file ID.
- Steam username/password sign-in and a Steam Guard retry field.
- Progress reporting, current-file display, cancel action and errors.
- Persistent download library and history.
- Re-download/update existing items into the same folder.
- ZIP export through the iOS share sheet.
- Keychain storage for credentials; Steam session cache in private app storage.
- Individual Workshop items from different games, as resolved by Steam's item metadata.

## Build
In GitHub, open Actions → Build Steam Workshop IPA → Run workflow. When it finishes, download the `WorkshopDownloader-IPA` artifact from that run.

The IPA is unsigned. It must be signed before iOS will install it normally.

This is an unofficial project and is not affiliated with Valve. Only download content you are entitled to access.
