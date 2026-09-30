# Lyric display stability and accompaniment

Validated locally on 2026-09-30 using the currently playing song supplied by the user, plus synthetic timing fixtures. Raw personal cache data and sampling logs stay outside the repository.

## Confirmed failures

The current-song cache contained 18 LRC blank markers falling inside normalized YRC singing intervals. One blank was at 120,150 ms while its YRC word line continued until 122,970 ms. Inserting the blank into the word timeline prematurely cleared the line and also shortened its final word through the next-line clamp. A fixture using those timings reproduced a missing line and a final word shortened from 4,390 ms to 1,430 ms. The fixed engine ignores coarser clear markers that fall inside an active word interval. Legitimate blanks between sung lines remain supported.

A separate fixture reproduced an ordinary position correction moving the running clock from 13,000 ms back to 11,700 ms. That behavior could rewind the highlighted words. Ordinary drift now uses the existing gradual clock correction; genuine discontinuities and small seeks across line boundaries still correct promptly. The lyric boundary timer accounts for both the correction period and the subsequent normal playback speed.

Both old behaviors produced four failed assertions before the fixes. Those same cases pass afterward. A direct check against the user's actual cache checked all 18 conflicting markers and found zero unexpected vocal clears after the fix.

## Menu-bar behavior

A pause shorter than 3 seconds holds the just-finished lyric. This applies to both a gap after word timing and an explicit LRC blank, including consecutive blanks. The completed fill and reading position stay visible, including a long line that has already scrolled to its end. The next sentence appears when its singing begins rather than replacing the previous sentence during a brief breath.

An accompaniment segment of at least 3 seconds displays three progress dots until the next vocal line begins. The threshold uses the known segment length from the lyric timeline. Dots use 70% of the normal menu-bar font size; the same font is used to measure their fill path and render both base/fill bitmaps. The fill is a Core Animation keyframe animation, without a periodic SwiftUI redraw or a new polling timer. Switching back to vocals, pausing and seeking reuse the existing playback-clock handling.

The opening introduction retains the song-title fallback. A whole track without synchronized lyrics retains its existing configured fallback. This change does not infer accompaniment from audio: word endpoints and explicit lyric clears supply its timing. For plain LRC without a clear marker or word endpoints, only the existing long-interval heuristic can identify an instrumental segment. Incorrect upstream word timestamps remain a data limitation.

## Verification

The 48 workflow cases include sustained-word protection, continuous ordinary correction, the 500/1,000/2,000/2,999/3,000/5,000 ms pause threshold, consecutive blanks, intro/outro separation, progress-dot fill and seeks, and exact 70% font sizing. An AppKit/Core Animation test checks installed fill keyframes during speed correction and intentional forward/backward seeks. Existing per-millisecond scheduler comparisons, external seeks without notifications, pause/lock/demand cancellation, native position replies, lyric editing and asynchronous search regressions also pass. The parsing/matching/cache/crypto/sync selftest passes.
