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
