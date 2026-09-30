# Playback responsiveness and efficiency

Assessment and local validation on 2026-09-30, on an arm64 Mac running macOS 15.7.4. The goal is to keep lyrics synchronized when the user seeks in Music while reducing work during ordinary menu-bar playback.

## What the old timers did

The 20 Hz timer queried the lyrics engine against an extrapolated playback clock. It did not read Music's position 20 times per second. Actual position checks ran every 3 seconds, launching a JavaScript `osascript` process for each check. `com.apple.Music.playerInfo` notifications also fetched a full playback snapshot.

A repeated-tick diagnostic confirmed 1,100 observable-object notifications across 100 checks with no lyric-line change. Downstream deduplication did not prevent those upstream publications. Position corrections also ignored differences of up to 1,000 ms while playing and 400 ms while paused. A 50 ms seek across a lyric boundary reproduced missed switching in both states when those old thresholds were restored; the regression test produced four failed assertions.

## Resulting behavior

Music position is now read directly with an Apple Event targeting the running Music PID. The request reads the `pPos` property from Music's scripting dictionary, waits on a background task with a bounded timeout, and returns nil on error. Missing Music never launches the application. The frequent position check no longer creates a script process; full metadata snapshots and playback commands retain their existing paths.

While lyrics or the menu-bar panel are requested, position checks run every 100 ms when Music is the frontmost app and every 3 seconds in the background. An NSWorkspace application-activation notification switches the cadence and triggers an immediate position check. Both cadences stop when the screen is locked or demand disappears. Only one query may be in flight. This remains polling: in Music's window, the nominal wait for an unannounced seek is up to one 100 ms interval plus query/scheduling latency. Background seeks still rely on playback notifications or a check up to 3 seconds later. Neither interval is a hard real-time guarantee.

The existing Music notification subscription remains active. MusicKit's `SystemMusicPlayer` is unavailable on macOS in the installed SDK, and [MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter) publishes the calling app's information. A separate local diagnostic loaded MediaRemote and subscribed to its notifications, but its playback-info request returned no information, and no MediaRemote change event arrived during a Music seek. The [MediaRemote adapter project](https://github.com/ungive/mediaremote-adapter#motivation) documents restrictions since macOS 15.4. The app does not depend on this private framework or on mouse/keyboard monitoring.

The fixed 20 Hz lyrics timer is replaced by a non-repeating timer for the next relevant timestamp: line start, word-line end, compact-line reveal, gap entry/exit, or completion of the karaoke fill. Seeks, position corrections, offset changes, reloads and playback-state changes immediately recompute the display and its next scheduled update. The scheduled boundary is selected relative to the position already evaluated, so crossing a boundary during scheduling cannot accidentally skip that update. Karaoke animation in the menu bar continues through Core Animation.

Fields are published only when their values change. The scheduler checks gap, compact-line and fill transitions even when the active lyric index stays the same. Word-fill threshold caches are invalidated on reload. In-flight snapshot/position responses are invalidated when the source stops.

Music's `pPos` reply is a 32-bit float. A live comparison confirmed its value matches JXA, including intervals where many queries return the same cached position. Requesting a double did not make those values update more frequently. Repeated samples must not repeatedly reset the running clock.

While playing, unchanged samples are ignored. Changed samples cause immediate correction for a backward movement over 20 ms, a forward jump more than 250 ms beyond expected playback since the last changed sample, or an ahead-of-clock lyric-state change. The existing 1,000 ms tolerance remains for ordinary clock drift. This detects seeks while preserving smooth interpolation through Music's cached readings. While paused, any changed position updates the display. Lyli's own seek still updates its local clock and lyric display synchronously.

## Validation

`./scripts/test-lyrics-workflows.sh` passes 40 cases, including 20 playback/efficiency cases. The existing `lyli-selftest` parsing, matching, cache, crypto and synchronization tests also pass.

The scheduler equivalence test checks every millisecond over 45 seconds for five lyric fixtures and three offset values (675,015 comparisons). It covers plain lyrics, long introductions/gaps, word timing, overlapping/duplicate timestamps, blank clear lines, an embedded LRC offset, compact reveal and fill completion. Scheduled display state and settled-fill state agree with continuous evaluation. Each fixture uses fewer than 30 scheduled updates over that interval, compared with 900 checks for the old 20 Hz lyrics timer. Position-query wakeups are additional and are not included in that comparison.

Other cases verify forward/backward seeks while playing and paused, a forward seek within the same line, stable clocks through cached Music samples, rate-aware scheduling, lock/demand/pause cancellation, a real run-loop timer switching the line, external-position changes without notifications while Music is frontmost, foreground/background cadence changes, discarding late responses after stop, correct Apple Event addressing and single/double-precision fractional replies, permission/timeout failures, invalid replies, and no send when Music is absent. Unchanged checks produce zero observable-object notifications. Restoring the overaggressive 80 ms correction threshold and removing duplicate-sample filtering reproduced seven clock-stability assertion failures; the final implementation passes those same checks.

## Local process measurements

Counters use `proc_pid_rusage`; CPU mach ticks are converted with `mach_timebase_info`. CPU percentages are relative to one core and include the app plus its exited child processes where shown. These are 60-second samples, not watts or battery-life measurements. Different tracks and usage states prevent treating all rows as a controlled A/B experiment. Music's own process and WindowServer are excluded.

| Sample | App CPU | Child CPU | Combined CPU | App interrupt wakeups/s |
| --- | ---: | ---: | ---: | ---: |
| Earlier diagnostic: menu-bar playback, original code | 1.03% | 2.01% | 3.04% | 23.32 |
| Intermediate: deduplicated publications and native 3-second checks, 20 Hz lyric timer retained, playing | 0.89% | 0.22% | 1.11% | 20.95 |
| Intermediate: fixed native 100 ms checks and boundary scheduling, paused | 1.18% | 0.00% | 1.18% | 10.02 |
| Final Release: foreground/background cadence, boundary scheduling and cached-sample filtering, background playback | 0.62% | 0.00% | 0.62% | 2.07 |

The final sample started and ended playing the same track, with no test-induced volume change. The app footprint was about 44.5 MiB, with approximately 2.0 MiB of disk reads and no writes. A separate simultaneous sample of Music measured 2.93% CPU and 6.95 interrupt wakeups/s; without an equivalent Music baseline, those costs cannot be attributed to Lyli's queries. The final Lyli sample supports reduced app work, but does not measure whole-system power. The paused intermediate row measures position-query cost, rather than final playback performance. Activity Monitor's historical energy value is a different metric and was not used as a regression benchmark.

A final installed-Release seek test verified Music was frontmost before the position change and remained frontmost afterward. A native-position correction arrived about 47 ms after a 10-second seek was applied; the playback timeline and previous frontmost app were restored. This measures detection/correction in the source, not rendered pixels or a physically clicked lyric row. The existing notification-free probe regression covers the equivalent external position-change path. It is a single timing sample rather than a latency guarantee.
