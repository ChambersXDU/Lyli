import Foundation

@MainActor var workflowFailures = 0

@MainActor func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
                                         file: StaticString = #fileID, line: UInt = #line) {
    if actual != expected {
        workflowFailures += 1
        print("FAIL \(file):\(line): \(actual) != \(expected)")
    }
}

@MainActor func require<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else { throw MissingValue(location: "\(file):\(line)") }
    return value
}

private struct MissingValue: Error { let location: String }

@main struct WorkflowSelftest {
    @MainActor static func main() async {
        let suite = LyricsWorkflowTests()
        let playback = PlaybackEnergyTests()
        let tests: [(String, () async throws -> Void)] = [
            ("manual-pick-survives-automatic-search", suite.testAutomaticResultDoesNotOverwriteManualPick),
            ("edited-lyrics-replace-old-word-timing", suite.testEditingLyricsInvalidatesOldWordTimingAndDisplaysNewText),
            ("translation-edit-keeps-word-timing", suite.testTranslationOnlyEditPreservesWordTiming),
            ("empty-search-completes", suite.testEmptyAutomaticSearchRecordsCompletion),
            ("automatic-plain-text-fallback", suite.testAutomaticSearchSavesPlainTextFallback),
            ("rematch-plain-text-fallback", suite.testRematchCanReachFallbackForHealthyPlainTextResponse),
            ("rematch-instrumental", suite.testRematchCanReachInstrumentalHandling),
            ("failed-sources-keep-existing-lyrics", suite.testFailedSourcesDoNotProduceANegativeMatchDecision),
            ("stop-search-discards-late-result", suite.testStopSearchCancelsProviderAndDiscardsLateResult),
            ("unlocked-pick-survives-automatic-search", suite.testUnlockedManualPickAlsoSurvivesAutomaticSearch),
            ("manual-plain-text-survives-automatic-search", suite.testManualPlainTextSurvivesAutomaticSearch),
            ("other-song-edit-preserves-search", suite.testEditingAnotherSongDoesNotDiscardAutomaticResult),
            ("network-failure-can-retry", suite.testFailedAutomaticSearchCanRetryAfterNetworkRecovers),
            ("cancelled-search-can-retry", suite.testCancelledSearchCanRetryAndClearCancellation),
            ("different-song-stop-keeps-search", suite.testStoppingDifferentSongDoesNotCancelCurrentSearch),
            ("automatic-stop-keeps-manual-search", suite.testStoppingAutomaticSearchPreservesManualSearch),
            ("partial-empty-search-completes", suite.testPartialHealthyEmptySearchDoesNotStaySearching),
            ("replacement-keeps-new-word-timing", suite.testExplicitReplacementKeepsNewWordTiming),
            ("failed-save-is-reported", suite.testFailedSaveIsReportedAsFailure),
            ("cached-track-switch-discards-old-search", suite.testSwitchingToCachedSongDiscardsPreviousAutomaticResult),
            ("unchanged-ticks-do-not-publish", { playback.testUnchangedTicksDoNotPublish() }),
            ("line-boundary-publishes-immediately", { playback.testLineBoundaryPublishesImmediately() }),
            ("seek-updates-without-waiting", { playback.testSeekUpdatesWithoutWaitingForTimer() }),
            ("playing-seek-updates-anchor-and-line", { playback.testPlayingSeekUpdatesAnchorAndLineImmediately() }),
            ("offset-keeps-boundary-timing", { playback.testOffsetCorrectionKeepsBoundaryTiming() }),
            ("word-fill-settles-with-same-line", { playback.testWordFillSettlesWithoutChangingLine() }),
            ("clear-and-reload-update-immediately", { playback.testClearingAndReloadingLyricsUpdatesImmediately() }),
            ("gap-and-upcoming-line-update", { playback.testGapAndUpcomingLineUpdateWithoutActiveLineChange() }),
            ("scheduled-updates-match-every-millisecond", { playback.testScheduledUpdatesMatchEveryMillisecond() }),
            ("scheduler-replans-and-stops", { playback.testSchedulerReplansSeekAndStopsWhenUnneeded() }),
            ("scheduled-timer-switches-line", { playback.testScheduledTimerActuallySwitchesLine() }),
            ("position-probe-corrects-small-seek", { playback.testPositionProbeCorrectsSmallSeekAcrossLineBoundary() }),
            ("probe-timer-detects-external-seek", playback.testProbeTimerDetectsExternalSeekWithoutNotification),
            ("stopped-source-discards-in-flight-probe", playback.testStoppedSourceDiscardsInFlightProbe),
            ("position-probe-follows-music-activity", { playback.testPositionProbeCadenceFollowsMusicActivity() }),
            ("cached-music-samples-preserve-clock", { playback.testCachedMusicSamplesDoNotRepeatedlyResetClock() }),
            ("same-line-forward-seek-corrects-clock", { playback.testForwardSeekWithinSameLineCorrectsClock() }),
            ("native-position-request-and-reply", { playback.testNativePositionRequestAndFractionalReply() }),
            ("native-position-failure-keeps-anchor", { playback.testNativePositionFailuresDoNotBecomeZero() }),
            ("missing-music-does-not-send", { playback.testMissingMusicOrInvalidTimeoutDoesNotSend() }),
            ("plain-clear-keeps-sustained-word", { playback.testPlainClearDoesNotCutOffSustainedWord() }),
            ("ordinary-drift-keeps-clock-continuous", { playback.testOrdinaryDriftDoesNotJumpClockBackwards() }),
            ("short-accompaniment-and-intro", { playback.testShortAccompanimentAndIntroRemainDistinct() }),
            ("plain-blank-shows-accompaniment", { playback.testPlainBlankUsesAccompanimentRatherThanTitle() }),
            ("accompaniment-dots-follow-progress", { playback.testAccompanimentDotsFillContinuouslyAndSeek() }),
            ("boundary-delay-includes-correction-end", { playback.testBoundaryDelayIncludesCorrectionEnd() }),
            ("menu-bar-animation-keeps-clock-continuous", { playback.testMenuBarAnimationUsesContinuousCorrectedClock() }),
            ("short-pauses-hold-line-and-smaller-dots", { playback.testShortPausesHoldFinishedLineAndDotsAreSmaller() }),
        ]
        for (name, test) in tests {
            let failuresBefore = workflowFailures
            do {
                try await suite.setUp()
                try await test()
            } catch {
                workflowFailures += 1
                print("FAIL \(name): \(error)")
            }
            do { try await suite.tearDown() }
            catch { workflowFailures += 1; print("FAIL cleanup: \(error)") }
            print("\(workflowFailures == failuresBefore ? "PASS" : "FAIL") \(name)")
        }
        print(workflowFailures == 0 ? "ALL WORKFLOW TESTS PASS (\(tests.count))" : "WORKFLOW TESTS FAILED (\(workflowFailures))")
        exit(workflowFailures == 0 ? 0 : 1)
    }
}
