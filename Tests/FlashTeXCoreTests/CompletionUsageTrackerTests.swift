import XCTest
@testable import FlashTeXCore

// Tests for the adaptive, personalized completion ranking (frecency + prefix
// affinity + confidence), mirroring the required behaviours: no-history base
// order, repeated selection, prefix-specific learning, competing candidates,
// recency, cold start, persistence, no false learning, one-event-per-accept,
// and accidental-selection resistance.

final class CompletionUsageTrackerTests: XCTestCase {

    /// Commands the base matcher returns for `\f`, in base (alphabetical) order.
    private let baseForF = ["\\footnote", "\\foreach", "\\frac", "\\frame"]

    private var tempURL: URL!
    private var tracker: CompletionUsageTracker!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashtex-tests-\(UUID().uuidString).json")
        tracker = CompletionUsageTracker(fileURL: tempURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    /// Record `n` selections of `completion` for `prefix`, spread over the last
    /// `days` days (so the most recent lands at `now`).
    private func record(_ completion: String, prefix: String, times n: Int, over days: Double = 0) {
        let now = Date()
        for i in 0..<n {
            let t = now.addingTimeInterval(-days * 86_400 + Double(i))
            tracker.recordSelection(completionID: completion, prefix: prefix, timestamp: t)
        }
    }

    // Test 1 — no history: personalization has no influence; base order holds.
    func testNoHistoryKeepsBaseOrder() {
        let ranked = CompletionRanker.rank(baseForF, prefix: "\\f", using: tracker)
        XCTAssertEqual(ranked, baseForF)
    }

    // Test 2 — repeated selection moves the item up.
    func testRepeatedSelectionMovesItemUp() {
        record("\\frac", prefix: "\\f", times: 5)
        let ranked = CompletionRanker.rank(baseForF, prefix: "\\f", using: tracker)
        XCTAssertEqual(ranked.first, "\\frac")
    }

    // Test 3 — prefix-specific learning: both `\f` and `\fr` learn `\frac`.
    func testPrefixSpecificLearning() {
        record("\\frac", prefix: "\\f", times: 5)
        record("\\frac", prefix: "\\fr", times: 5)
        XCTAssertEqual(tracker.prefixAffinity(completionID: "\\frac", prefix: "\\f") > 0, true)
        XCTAssertEqual(tracker.prefixAffinity(completionID: "\\frac", prefix: "\\fr") > 0, true)
        let rankedF = CompletionRanker.rank(baseForF, prefix: "\\f", using: tracker)
        let rankedFr = CompletionRanker.rank(baseForF, prefix: "\\fr", using: tracker)
        XCTAssertEqual(rankedF.first, "\\frac")
        XCTAssertEqual(rankedFr.first, "\\frac")
    }

    // Test 4 — competing completion: many `\frac` picks beat a single `\footnote`.
    func testCompetingCompletion() {
        record("\\footnote", prefix: "\\f", times: 1)
        record("\\frac", prefix: "\\f", times: 5)
        let ranked = CompletionRanker.rank(baseForF, prefix: "\\f", using: tracker)
        XCTAssertEqual(ranked.first, "\\frac")
        XCTAssertLessThan(ranked.firstIndex(of: "\\frac")!,
                          ranked.firstIndex(of: "\\footnote")!)
    }

    // Test 5 — recency: stale `\frac` usage loses to recent `\footnote` usage.
    func testRecencyOverridesStaleDominance() {
        record("\\frac", prefix: "\\f", times: 8, over: 60)
        record("\\footnote", prefix: "\\f", times: 6)
        let ranked = CompletionRanker.rank(baseForF, prefix: "\\f", using: tracker)
        XCTAssertEqual(ranked.first, "\\footnote")
        XCTAssertLessThan(ranked.firstIndex(of: "\\footnote")!, ranked.firstIndex(of: "\\frac")!)
    }

    // Test 6 — cold start: an unused completion still appears via base order.
    func testColdStartUnusedCompletionStillRanks() {
        record("\\frac", prefix: "\\f", times: 5)
        var candidates = baseForF
        candidates.append("\\framebox")           // never seen before
        let ranked = CompletionRanker.rank(candidates, prefix: "\\f", using: tracker)
        XCTAssertTrue(ranked.contains("\\framebox"))
        XCTAssertEqual(ranked.count, candidates.count)   // nothing dropped
    }

    // Test 7 — persistence: history survives a fresh tracker over the same file.
    func testPersistence() {
        record("\\frac", prefix: "\\f", times: 5)
        tracker.flush()
        let reloaded = CompletionUsageTracker(fileURL: tempURL)
        let ranked = CompletionRanker.rank(baseForF, prefix: "\\f", using: reloaded)
        XCTAssertEqual(ranked.first, "\\frac")
        XCTAssertEqual(reloaded.totalSelections(for: "\\frac"), 5)
    }

    // Test 8 — no false learning: never calling recordSelection keeps state zero.
    func testNoFalseLearningOnDismiss() {
        XCTAssertEqual(tracker.totalSelections(for: "\\frac"), 0)
        XCTAssertEqual(tracker.prefixCount(completionID: "\\frac", prefix: "\\f"), 0)
        // Merely querying must not create state.
        _ = tracker.rankingScore(for: "\\frac", prefix: "\\f")
        XCTAssertEqual(tracker.totalSelections(for: "\\frac"), 0)
    }

    // Test 9 — acceptance counts exactly one event per recordSelection call.
    func testEachAcceptanceRecordsOneEvent() {
        record("\\frac", prefix: "\\f", times: 3)
        XCTAssertEqual(tracker.totalSelections(for: "\\frac"), 3)
        XCTAssertEqual(tracker.prefixCount(completionID: "\\frac", prefix: "\\f"), 3)
    }

    // Test 10 — accidental selection resistance: one isolated pick neither
    // reorders the list (evidence gate) nor creates a dominant permanent boost.
    func testAccidentalSelectionResistance() {
        record("\\footnote", prefix: "\\f", times: 1)
        // Evidence below the threshold → base order preserved.
        let ranked = CompletionRanker.rank(baseForF, prefix: "\\f", using: tracker)
        XCTAssertEqual(ranked, baseForF)
        // And even as evidence accumulates elsewhere, a single stale pick fades.
        record("\\frac", prefix: "\\f", times: 5)
        let later = CompletionRanker.rank(baseForF, prefix: "\\f", using: tracker)
        XCTAssertEqual(later.first, "\\frac")
    }

    // Reset clears everything and removes the file.
    func testResetClearsHistory() {
        record("\\frac", prefix: "\\f", times: 5)
        tracker.reset()
        XCTAssertEqual(tracker.totalSelections(for: "\\frac"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }
}