# Third-party notices

ModShelf itself is licensed under the GNU General Public License, version 3.0 only. The full text is in [LICENSE](LICENSE).

This file lists the third-party components that ship inside the app, with their copyright lines and licence texts. The same text is available in the app under Options → Credits → Third-party notices.

---

## go-steam

Engine for talking to Steam, bundled as `SteamEngine.xcframework`.

- Upstream: https://github.com/BirknerAlex/go-steam
- The fork this build compiles: https://github.com/shplash/go-steam
- Copyright (c) 2026 Alexander Birkner

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### Test fixtures

go-steam carries a set of test fixtures under `internal/*/testdata/` that originate from the SteamKit project and remain under the GNU Lesser General Public License v2.1. They are test data only: gomobile compiles the library packages ModShelf imports, and test data and test files are not part of the compiled framework. None of those fixtures are distributed in the IPA.

---

## ZIPFoundation

ZIP reading and writing, linked as a Swift package.

- Upstream: https://github.com/weichsel/ZIPFoundation
- Copyright (c) 2017-2025 Thomas Zoechling (https://www.peakstep.com)

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Corresponding source

ModShelf is distributed as a compiled binary under GPL-3.0. The complete corresponding source for every release is public:

- The app: https://github.com/shplash/ModShelf — the release is built from the commit or tag it is published from
- The engine binding: `ios-engine/` in the same repository
- The engine it compiles: https://github.com/shplash/go-steam
- Build configuration: `.github/workflows/build-ipa.yml`, which shows every step from the sources to the signed IPA

No part of the app is built from source that is not published there.
