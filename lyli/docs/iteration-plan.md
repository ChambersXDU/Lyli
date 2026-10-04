# Lyli iteration plan

Prioritize improvements that address observed daily-use failures and can be checked with a concrete reproduction. Use the existing matcher selftests and application workflow tests before expanding features or reorganizing large views.

## Completed — 2026-10-02

Preserve the selected candidate from resolution through automatic saving, re-matching and default search-window selection. Previously, saving and re-matching selected the first candidate with the winning provider name. A higher-ranked instrumental marker from that provider could replace the timed winner with empty lyrics and the wrong score.

The regression reproduces the original failure before the fix. Coverage includes same-source instrumental/timed results, explicit source-priority mode, same-source timing variants, and searches with only plain text or instrumental fallbacks. Scoring rules and version remain unchanged.

## Next: candidate selection clarity

Inspect current-candidate and duplicate badges when one provider returns the same lyric text with different timing, translation or album metadata. The current UI compares source and lyric-body fingerprint, so those variants can share a current badge. Reproduce the ambiguity before changing how the UI identifies the saved selection.

## Next: representative matching cases

Build a small reviewable set of song metadata and permitted or authored lyric fixtures covering studio/live recordings, same-title songs, long outros, plain lyrics and manual corrections. Record expected selections and explain each failure. Keep personal cache contents out of the repository and distinguish format validation from measured matching accuracy.

## Next: playback measurements

Measure sync behavior and app energy use during continuous playback, external seeks, pause/resume and track switching. Existing deterministic timing tests protect the clock logic; actual Apple Music behavior still needs observation. Optimize the measured bottleneck and retain a repeatable before/after comparison.

## Verification

```sh
./scripts/swiftpm.sh run lyli-selftest
./scripts/test-lyrics-workflows.sh
./build.sh --debug --dest /tmp/Lyli-iteration.app
```

Use an explicit build destination for a reviewable app bundle. Running that build is separate from the isolated tests and may request macOS Automation permission.
