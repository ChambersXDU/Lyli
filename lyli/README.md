# Lyli package

This directory contains the Swift package for the native Apple Music lyrics app.

```sh
./build.sh --no-restart
swift run lyli-selftest
```

`Sources/LyliCore` contains lyric parsing, matching, providers, synchronization, cache access, and playback support. `Sources/lyli` contains the macOS app. The lyric cache is stored at `~/.config/lyli/lyli-enrich-cache.json`.

For an installed release, use `./build.sh`; use `./package.sh` to produce arm64 release archives. The app requires Apple Silicon, macOS 14+, and Apple Music Automation permission.
