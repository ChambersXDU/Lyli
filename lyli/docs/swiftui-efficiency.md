# SwiftUI interaction and collection efficiency

The October 4, 2026 update keeps macOS 14 compatibility and the existing playback architecture. It applies a focused set of the [SwiftUI Pro review recommendations](https://github.com/twostraws/SwiftUI-Agent-Skill) to the menu-bar panel and Lyrics Manager.

## List results

Lyrics Manager caches both filtered and sorted summaries. Repeated view updates and selection operations reuse the sorted collection until its inputs change. Cache keys include filter conditions, the summaries generation and the sort option. When the manual-correction filter is active, the pin-store generation also invalidates results, so calibration changes cannot leave stale filter membership.

The regression reads a 10,000-item sorted collection 100 times and verifies that sorting runs once. Separate cases cover each invalidation input, empty results and switching back to an earlier filter. This verifies avoided computation; it does not claim a measured reduction in application CPU or wall-clock latency.

## Reduced motion

Both the SwiftUI panel marquee and the native menu-bar marquee respect the system Reduce Motion setting. Changing that setting cancels the panel's scroll task or removes the native scroll animation and restores its resting position. Native follow-scroll updates cannot restart scrolling while Reduce Motion remains enabled. The panel exposes the complete lyric as a tooltip when the visible text is clipped.

Decorative equalizer bars stop their animation schedule and show a static pattern during playback. Pressed panel buttons also avoid scaling. Karaoke color fill remains available because it conveys playback timing.

Native-layer regressions verify stopping and restarting the marquee and blocking follow-scroll updates without changing the user's system settings.

## Playback controls

Previous, play/pause and next buttons have explicit Chinese accessibility labels and tooltips. The lyric-offset reset is a standard button with a label and current value. The progress bar exposes elapsed and total time and supports accessibility increment/decrement actions. Each adjustment seeks five seconds and clamps to the track boundaries.

Version 1.7.3 removes the progress bar's keyboard-focus and arrow-key modifiers. Adding keyboard focus in 1.7.2 caused the popover to give the bar initial focus and draw a large blue ring. The bar keeps its original mouse interaction and does not request keyboard focus; accessibility adjustment remains available.

## Verification

```sh
./scripts/swiftpm.sh run lyli-selftest
./scripts/test-lyrics-workflows.sh
LYLI_VERSION=1.7.3 ./build.sh --configuration release --dest /tmp/Lyli-review.app
```

Compilation and deterministic regressions complement an installed-app smoke check. They do not replace a full spoken VoiceOver audit or controlled energy measurements. Main-thread persistence and a broader state-model migration remain separate work.
