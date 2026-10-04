# Lyric matching

Scoring version 19 retains automatic selection and the user's source-priority mode. It assumes music providers usually return usable lyrics and improves comparisons between those candidates rather than requiring manual confirmation for ordinary playback.

## Evidence used for ranking

Provider-reported track duration is the primary duration signal. A difference within two seconds or one percent earns the full 300 points; larger differences reduce that bonus, and a difference above twelve percent retains the existing 250-point penalty. Missing or zero duration is unknown, not a mismatch. When reported duration is unavailable, the last useful lyric timestamp supplies a weaker bonus of at most 100 points. Lyrics extending more than five seconds past the track retain their existing penalties. Blank timestamps and lyric credits do not supply an endpoint or contribute to the line-count bonus. An instrumental outro does not reduce the duration bonus when the reported track duration matches.

Word timing must parse into at least two useful lines with distinct line timestamps and nondecreasing word starts within each line. Invalid or fragmentary tracks fall back to the candidate's LRC before ranking, preview and persistence. Valid word timing retains its 400-point preference. This validation establishes basic usability, not alignment to the audio; playback still applies its existing timeline normalization.

Content agreement counts each other provider once. Comparisons use normalized adjacent character triples so punctuation and capitalization differences are tolerated across English and Chinese while a shared bag of words is insufficient. Supporting candidates must have matching song/artist information and no identified recording-version conflict. Content agreement does not validate timestamps or establish that providers obtained their lyrics independently.

Recording-version comparison recognizes performance differences such as live, acoustic, karaoke and demo in titles and album metadata, including attached Chinese labels. Album detection of English live recordings uses explicit forms such as `Live at`, `Live in` and `(Live)` rather than any appearance of the word. A candidate without requested version information receives a smaller penalty than an explicit version mismatch. Remaster labels, including a preceding year, do not incur a recording-version penalty. If another usable candidate matches the title or recording version better, a conflicting candidate cannot use its word-timing bonus to overcome that difference. A sole usable candidate with incomplete version metadata remains selectable.

Only fully identical candidates are deduplicated. Different albums, timestamps, translations or word tracks remain available for comparison. Equal scores within a source use a deterministic tie-break so response order does not decide the winner.

The search result carries the specific winning candidate through automatic saving, re-matching and default search-window selection. A provider name identifies a source, not one candidate: a source can return several recordings or an instrumental marker before a timed lyric. Saved lyrics, translation, word timing and score must all come from the selected candidate. Searches with only plain text or instrumental results continue through their existing fallback handling. This application change does not alter scoring version 19.

## Validation and limits

The matching selftest covers repeated-provider votes, independent votes, reordered words, English and Chinese punctuation, invalid/partial/decreasing word timing, long outros, blank and credit endpoints, unknown durations, distinct same-source variants, deterministic ties, karaoke/live/acoustic conflicts, remaster labels and source-priority selection. Workflow tests verify fallback persistence, scoring-version metadata and saving the better same-source variant alongside the existing search, editing and playback regressions.

A read-only compatibility check of the local 123-entry cache found 121 timed lyrics and 89 word tracks; all 89 word tracks passed the new basic validation. Personal lyrics and audit outputs are not included in the repository. This check confirms compatibility for that cache, not a measured matching-accuracy improvement.

Existing cache records are not re-scored or overwritten on launch. New searches record version 19; explicit re-matching evaluates the new rules while retaining the existing protections for manual edits and calibrated lyrics. The score remains a heuristic ordering rather than a probability of correctness. This change introduces neither a universal score threshold nor an audio-based synchronization check.
