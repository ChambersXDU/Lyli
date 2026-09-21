# Lyli

Native macOS menu-bar and desktop lyrics for Apple Music. It follows playback with LRC/YRC word timing, translation and duet lines, with a Lyrics Manager for manual search, editing, deleting and re-matching cached songs.

The app queries five lyric providers (LRCLIB, Kuwo, NetEase, Kugou, and QQ Music), scores their candidates, and stores lyrics in `~/.config/lyli/lyli-enrich-cache.json`. Cached lyrics work offline.

Apple Music control and playback position use macOS Automation permission. The app focuses on automatic lyric matching, desktop lyrics, menu-bar lyrics, timing correction and simple manual lyric selection.

## Install

Download the latest release from [GitHub](https://github.com/ChambersXDU/Lyli/releases). macOS 14 or newer is required.

## Build and test

```sh
cd lyli
./build.sh --no-restart
swift run lyli-selftest
```

Use `./build.sh --universal` for an arm64 + Intel build and `./package.sh` for release assets.

## License

GPL-3.0. Lyrics and metadata remain the property of their respective rights holders; the app caches lyrics locally for personal display.
