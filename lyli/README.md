# Lyli package

This directory contains the Swift package for the native Apple Music lyrics app.

```sh
./build.sh --no-restart
./scripts/swiftpm.sh run lyli-selftest
./scripts/test-lyrics-workflows.sh
```

The SwiftPM wrapper keeps compiler and package caches under `.build` and avoids nested SwiftPM sandbox failures in restricted build environments. `build.sh` uses it too.

`Sources/LyliCore` contains lyric parsing, matching, providers, synchronization, cache access, and playback support. `Sources/lyli` contains the macOS app. The lyric cache is stored at `~/.config/lyli/lyli-enrich-cache.json`.

For an installed release, use `./build.sh`; use `./package.sh` to produce arm64 release archives. The app requires Apple Silicon, macOS 14+, and Apple Music Automation permission.
