# Third-Party Notices

This project is distributed under the MIT License. The following third-party components are used by the app or build:

## PermissionFlow

- Source: `https://github.com/bi-boo/PermissionFlow.git`
- Version: `2.1.0`
- License: MIT License
- Purpose: Guides users through macOS privacy permission setup.

The PermissionFlow license is included by Swift Package Manager in the resolved source package checkout during builds. Keep the upstream MIT notice when redistributing source or binary releases.

## MP3 Encoding

The current public build does not vendor or link any third-party MP3 encoder. MP3 remains guarded by runtime availability checks in the source code and is not part of the default binary release promise unless a compatible encoder is supplied and documented separately.
