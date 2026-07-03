# Third-Party Notices

This project is distributed under the MIT License. The following third-party components are used by the app or build:

## PermissionFlow

- Source: `https://github.com/bi-boo/PermissionFlow.git`
- Version: `2.1.0`
- License: MIT License
- Purpose: Guides users through macOS privacy permission setup.

The PermissionFlow license is included by Swift Package Manager in the resolved source package checkout during builds. Keep the upstream MIT notice when redistributing source or binary releases.

## MP3 Encoding

MP3 export is implemented with `libmp3lame` first, with macOS native encoding kept as a fallback when available.

## LAME / libmp3lame

- Files: `SimpleRecorder/ThirdParty/lame/`
- Included artifacts: `libmp3lame.a`, `lame.h`, `module.modulemap`, `COPYING`
- License: GNU Library General Public License version 2, or later as stated in the upstream header
- Purpose: Converts finished M4A recordings to MP3 for services that require MP3 uploads.

The LAME license text is kept at `SimpleRecorder/ThirdParty/lame/COPYING`. Keep that notice with source and binary releases. If the static `libmp3lame.a` is redistributed, release notes should also describe how the bundled library was built and how users can replace or rebuild it.
