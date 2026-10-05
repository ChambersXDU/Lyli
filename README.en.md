# Lyli

**Apple Music lyrics in your macOS menu bar and on your desktop.**

[![Release](https://img.shields.io/github/v/release/ChambersXDU/Lyli?label=release)](https://github.com/ChambersXDU/Lyli/releases/latest) [![CI](https://github.com/ChambersXDU/Lyli/actions/workflows/ci.yml/badge.svg)](https://github.com/ChambersXDU/Lyli/actions/workflows/ci.yml) ![macOS](https://img.shields.io/badge/macOS-14%2B-blue) ![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-arm64-black) [![License](https://img.shields.io/badge/license-GPL--3.0-green)](LICENSE)

[简体中文](README.md) · English · [Download](https://github.com/ChambersXDU/Lyli/releases/latest) · [Report an issue](https://github.com/ChambersXDU/Lyli/issues)

Lyli is a native macOS lyrics app for Apple Music. It follows playback with line and word highlighting, translations, timing adjustments, and a Lyrics Manager for searching, selecting and editing lyrics. Automatic matching first checks Apple's locally cached official lyrics, then falls back to other enabled lyric providers.

## Features

| Feature | What it does |
| --- | --- |
| Menu bar and desktop lyrics | Choose a display surface and customize fonts, colors, width and alignment. |
| Line and word timing | Supports LRC, YRC and Apple TTML; word highlighting requires valid word or syllable timestamps. |
| Sustained-note glow | Desktop lyrics and the player popover softly illuminate Chinese characters or English words lasting at least 1.2 seconds, fading at the end. Disabled while paused or with Reduce Motion. |
| Apple's official lyrics cache | Associates lyrics with cached song metadata by Apple catalog ID, then checks title, artist, album and duration. |
| Multiple lyric providers | Falls back to LRCLIB, Kuwo, NetEase, Kugou and QQ Music, with source and matching-order settings. |
| Translations and Chinese variants | Shows available translations and supports Simplified and Traditional Chinese display. |
| Timing adjustments | Applies global or per-song offsets. |
| Lyrics Manager | Search, preview, select, edit, delete and re-match lyrics while protecting manual choices and calibrated songs. |
| Local storage | Saved lyrics remain available offline; includes launch-at-login and update checks. |

## Install

Requires **macOS 14 or later and an Apple Silicon Mac**, with playback in the Music app. Current releases provide arm64 builds.

1. Download the latest `.dmg` or `.zip` from [Releases](https://github.com/ChambersXDU/Lyli/releases/latest).
2. Move **Lyli.app** into Applications and open it.
3. Allow Lyli to control Music when macOS prompts. You can check this under **System Settings → Privacy & Security → Automation**.
4. Play a song in Music and choose the menu bar or floating lyrics display in Lyli's settings.

If macOS blocks opening the app with a verification notice, check its opening options under Privacy & Security. Releases include a SHA-256 checksum file for the ZIP archive.

## How lyrics are obtained

Automatic matching first reads Apple Music's local cache. A reliable match is saved and displayed immediately. Missing cache data or insufficient song-identity evidence falls back to the other enabled sources. When official lyrics only have line timings, Lyli first tries saved word timings from another enabled provider, then searches enabled providers in the background without delaying the official lyrics.

Fusion treats the official text, translations and line boundaries as the highest-priority constraints. It tolerates script, 妳/你, punctuation and spacing differences, including zero-duration spaces, and aligns crossed line breaks using real word boundaries. Each external provider gets one vote per line. Mutually consistent sources calibrate timings with weighted medians and can fill each other's missing lines. Ties, changed words and boundary overruns fall back to line display; incompatible recordings and clocks are excluded. No character timing is interpolated. Lyrics Manager lists the contributing providers. Failed attempts have a two-minute cooldown, and old fusion results upgrade without clearing lyrics or overwriting protected picks.

Music must have fetched the lyrics already; **opening its lyrics panel can populate the cache**. A line-timed response stays line-timed. Lyli enables word highlighting only when the cached response supplies valid word or syllable timestamps.

The reader accesses response bodies in `~/Library/Caches/com.apple.Music/Cache.db` and `fsCachedData`. It does not read cookies or authentication headers, or replay signed Apple requests. Bounded retries after a track change allow for late cache writes. Apple's cache layout may change with macOS updates; read failures fall back to the other sources.

Use the **Lyrics Manager** to search and select a better candidate, edit lyrics, or adjust timing. Automatic cache matching preserves manual picks, edits, explicit source choices, pinned songs and calibrated lyrics. Provider availability and lyric coverage depend on the respective services; matching accuracy is not guaranteed for every recording.

## Build and verify

Use the Swift toolchain provided by Xcode Command Line Tools. The project is organized as a Swift package with a macOS 14 deployment target.

```sh
git clone https://github.com/ChambersXDU/Lyli.git
cd Lyli/lyli

# Assemble a candidate app without replacing the installed app
./build.sh --debug --dest /tmp/Lyli.app

# Core selftests and application workflow regressions
./scripts/swiftpm.sh run lyli-selftest
./scripts/test-lyrics-workflows.sh
```

`./build.sh --debug` builds, installs and launches the app; add `--no-restart` to install without restarting. `./build.sh` defaults to an optimized Release build, and `./package.sh` produces arm64 release assets. Keep `lyli/.build` between builds to reuse compiler caches.

To check the currently playing song against the real Apple Music cache:

```sh
./scripts/swiftpm.sh run lyli-selftest --apple-music-cache
```

Music must be playing or paused on a song, with Automation access available. The check reports track metadata, cache hit/miss and timeline validation without printing lyric text. A miss can mean there is insufficient cached song metadata, even when Music displays lyrics.

Settings and saved lyrics default to `~/.config/lyli/`. `lyli/Sources/LyliCore` contains the core pipeline; `lyli/Sources/lyli` contains the macOS interface.

See the [package guide](lyli/README.md), [lyric matching](lyli/docs/lyric-matching.md), [playback responsiveness and efficiency](lyli/docs/playback-efficiency.md), [display stability](lyli/docs/lyric-display-stability.md), and [build performance](lyli/docs/build-performance.md) for development details.

## Feedback

Report problems through [GitHub Issues](https://github.com/ChambersXDU/Lyli/issues). For lyric problems, include the Lyli and macOS versions, song title, artist, album, and the affected lyric source or display surface. Do not upload the complete Music cache database or authentication data.

## Origin and credits

Lyli is adapted from [Yudaotor/lyrimuse](https://github.com/Yudaotor/lyrimuse) and maintained by [ChambersXDU](https://github.com/ChambersXDU). The current app focuses on Apple Music lyric retrieval, matching and display. Thanks to the original project for its foundation.

## License

[GNU GPL v3](LICENSE). Third-party code and license notices are listed in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES). Lyrics and song metadata remain the property of their respective rights holders; the app caches lyrics locally for personal display.
