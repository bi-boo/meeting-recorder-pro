# Third-Party Notices

The application source is distributed under the MIT License. The binary distribution also contains the following third-party components. Versions and revisions come from the committed Swift Package Manager resolution file or the bundled static library.

## PermissionFlow

- Source: <https://github.com/bi-boo/PermissionFlow>
- Version: `2.1.0`
- Revision: `6d6f13176f8942535d6c1acd75d7a3446bbf0acd`
- License: MIT License
- Copyright: `Copyright (c) 2026 小弟调调`
- Purpose: macOS privacy-permission guidance.

The complete upstream license is included in the DMG as `PermissionFlow-LICENSE.txt`.

## Sparkle

- Source: <https://github.com/sparkle-project/Sparkle>
- Version: `2.9.4`
- Revision: `b6496a74a087257ef5e6da1c5b29a447a60f5bd7`
- License: MIT License with additional notices for bundled upstream components
- Purpose: signed application updates from GitHub Releases.

The complete upstream `LICENSE` file, including Sparkle's external component notices, is included in the DMG as `Sparkle-LICENSE.txt`.

## LAME / libmp3lame

- Upstream source: <https://sourceforge.net/projects/lame/files/lame/3.100/>
- Exact source archive: <https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz>
- Source archive SHA-256: `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`
- Bundled complete source archive: `SimpleRecorder/ThirdParty/lame/lame-3.100.tar.gz`
- Bundled version reported by the library: `3.100`
- Bundled archive: `SimpleRecorder/ThirdParty/lame/libmp3lame.a`
- Bundled archive SHA-256: `dea6b41806721d6e7494250d2d5fa30552e16fd155e632fddbd0d11a1cbce44c`
- License: GNU Library General Public License version 2 or, at your option, any later version
- Purpose: MP3 encoding.

The license text is stored at `SimpleRecorder/ThirdParty/lame/COPYING` and included in the DMG as `LAME-COPYING.txt`. The complete machine-readable LAME 3.100 source archive is included in the DMG and every GitHub Release as `lame-3.100.tar.gz`; the build and publication scripts reject a missing or hash-mismatched archive. Compatible-library rebuild, replacement, and application relinking instructions are in [`docs/lame-relinking.md`](docs/lame-relinking.md) and included in the DMG as `LAME-SOURCE-AND-RELINKING.md`.

The complete application source for each distributed version is available from the Git tag matching that release. Together with the replacement instructions, it can be rebuilt against a modified `libmp3lame.a`.
