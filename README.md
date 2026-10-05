# Lyli

Native macOS menu-bar and desktop lyrics for Apple Music. It follows playback with LRC/YRC word timing, translation and duet lines, with a Lyrics Manager for manual search, editing, deleting and re-matching cached songs.

Automatic matching first reads Apple Music’s local official-lyrics cache. It joins lyric requests to cached song metadata by Apple catalog ID and validates title, artist, album and duration. A safe local match avoids network lyric searches; a miss falls back to LRCLIB, Kuwo, NetEase, Kugou and QQ Music. Lyrics are stored in `~/.config/lyli/lyli-enrich-cache.json` and work offline. Manual picks, edits, pinned songs and calibrated lyrics remain protected.

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

To check the currently playing song against the real Music cache, run `./scripts/swiftpm.sh run lyli-selftest --apple-music-cache` with Music playing or paused and Automation access allowed. It reports track metadata, cache hit/miss and timeline counts without printing lyric text.

Music must have downloaded the lyrics already (opening its lyrics panel can populate the cache). The reader uses `~/Library/Caches/com.apple.Music/Cache.db` and `fsCachedData` in read-only mode, supports `/ttmlLyrics` and embedded `syllable-lyrics` responses, and preserves TTML line/span timing and keyed translations. It never reads authentication headers or replays signed requests. Songs without enough cached identity evidence fall back to the other sources. Cache scans are bounded and retried three times after a track change to allow late cache writes; there is no continuous scan during playback. Apple's private cache layout may change in future macOS versions.

Use `./package.sh` to produce the arm64 release assets.

See the [iteration plan](lyli/docs/iteration-plan.md) for completed fixes and the next concrete matching and playback investigations.

## License

GPL-3.0. Lyrics and metadata remain the property of their respective rights holders; the app caches lyrics locally for personal display.
