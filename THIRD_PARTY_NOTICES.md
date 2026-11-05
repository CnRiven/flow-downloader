# Third-party notices

Flow (拾流) application code is licensed under GPL-3.0-or-later. See LICENSE.

## macOS

This build launches locally installed programs. No yt-dlp, FFmpeg, Deno, Python or Homebrew binaries are bundled in the app.

- yt-dlp: https://github.com/yt-dlp/yt-dlp — source distributed under the Unlicense; standalone release licensing varies with bundled dependencies.
- FFmpeg: https://ffmpeg.org/legal.html — LGPL/GPL depending on build options.
- Deno: https://github.com/denoland/deno — MIT and third-party licenses.

## Android

The APK bundles the following runtime components through published AAR dependencies:

- youtubedl-android 0.18.1: https://github.com/yausername/youtubedl-android — GPL-3.0. Library and FFmpeg wrapper sources are available in that repository, including BUILD_PYTHON.md and BUILD_FFMPEG.md.
- yt-dlp: https://github.com/yt-dlp/yt-dlp — Unlicense, with additional component notices in THIRD_PARTY_LICENSES.txt upstream.
- Android 1.0.1 overrides the AAR's old engine with the official **2026.10.26** zipimport release: https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.26. SHA-256: `e51e69e89489f199530f13d32a4342da3ddb2cf34842f364603a066db05afbf3`, verified against that release's SHA2-256SUMS. Its ISC/MIT component license texts are bundled at `assets/licenses/yt-dlp-THIRD_PARTY_LICENSES.txt`; application GPL text is bundled alongside it.
- FFmpeg: see https://github.com/yausername/youtubedl-android/tree/0.18.1/ffmpeg and https://ffmpeg.org/legal.html for bundled build configuration and licensing.
- Python: PSF license. Source: https://www.python.org/downloads/source/.
- Kotlin: Apache-2.0. Source: https://github.com/JetBrains/kotlin.
- AndroidX: Apache-2.0. Source: https://android.googlesource.com/platform/frameworks/support/.
- Jackson: Apache-2.0. Source: https://github.com/FasterXML/jackson.
- Apache Commons IO: Apache-2.0. Source: https://commons.apache.org/proper/commons-io/.

The complete Flow source and build scripts accompany these local build artifacts in this workspace. Before redistributing any binary, include corresponding source for its exact bundled component versions and their license texts. Upstream links alone are not a substitute for a corresponding-source distribution.
