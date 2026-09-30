# Lyli package

This directory contains the Swift package for the native Apple Music lyrics app.

```sh
./build.sh --debug --no-restart
./scripts/swiftpm.sh run lyli-selftest
./scripts/test-lyrics-workflows.sh
```

Use `./build.sh --debug` for local development. It builds, installs and starts the app using incremental Debug compilation; `--no-restart` skips restarting and `--dest /tmp/Lyli.app` assembles a signed bundle without installing it. Debug and Release keep separate artifacts under `.build`, so keep that directory between builds.

`./build.sh` defaults to optimized Release builds. `./build.sh --configuration release` makes that selection explicit, and `package.sh` always uses Release. App installation builds only the `lyli` product; selftests are compiled by their own commands. The SwiftPM wrapper keeps compiler and package caches under `.build` and avoids nested SwiftPM sandbox failures in restricted build environments. See [build performance measurements](docs/build-performance.md) for the assessment and reproducible profiling commands.

`Sources/LyliCore` contains lyric parsing, matching, providers, synchronization, cache access, and playback support. `Sources/lyli` contains the macOS app. The lyric cache is stored at `~/.config/lyli/lyli-enrich-cache.json`.

See [playback responsiveness and efficiency](docs/playback-efficiency.md) for the native position queries, timestamp-based lyric updates, regression coverage and local measurements. See [lyric display stability](docs/lyric-display-stability.md) for short pauses, accompaniment dots and sustained-word protection.

For an installed release, use `./build.sh`; use `./package.sh` to produce arm64 release archives. The app requires Apple Silicon, macOS 14+, and Apple Music Automation permission.
