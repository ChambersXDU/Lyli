# Lyli

Native macOS menu-bar and desktop lyrics for Apple Music. It follows playback with LRC/YRC word timing, translation and duet lines, with a Lyrics Manager for manual search, editing, deleting and re-matching cached songs.

The app queries five lyric providers (LRCLIB, Kuwo, NetEase, Kugou, and QQ Music), scores their candidates, and stores lyrics in `~/.config/lyli/lyli-enrich-cache.json`. Cached lyrics work offline.

See [lyric matching](lyli/docs/lyric-matching.md) for the ranking signals, recording-version handling and validation limits.

Apple Music control and playback position use macOS Automation permission. The app focuses on automatic lyric matching, desktop lyrics, menu-bar lyrics, timing correction and simple manual lyric selection.

## Install

Download the latest release from [GitHub](https://github.com/ChambersXDU/Lyli/releases). Apple Silicon (arm64) and macOS 14 or newer are required.

## Build and test

```sh
cd lyli
./build.sh --debug --no-restart
./scripts/swiftpm.sh run lyli-selftest
./scripts/test-lyrics-workflows.sh
```

Use `./build.sh --debug` for local development: it builds, installs and starts the app with Swift's incremental Debug compilation. Add `--no-restart` to install without restarting, or `--dest /tmp/Lyli.app` to assemble a signed app without installing it. Debug and Release keep separate build artifacts, so repeated development builds can reuse their cache.

`./build.sh` still defaults to optimized Release builds. Use that or `./build.sh --configuration release` to verify release behavior. The SwiftPM wrapper uses project-local caches and avoids nested SwiftPM sandbox failures in restricted build environments. `build.sh` builds only the app; the test commands above build their own runners. See [build performance measurements](lyli/docs/build-performance.md) for the measured bottleneck and comparison.

Use `./package.sh` to produce the arm64 release assets.

See the [iteration plan](lyli/docs/iteration-plan.md) for completed fixes and the next concrete matching and playback investigations.

## License

GPL-3.0. Lyrics and metadata remain the property of their respective rights holders; the app caches lyrics locally for personal display.
