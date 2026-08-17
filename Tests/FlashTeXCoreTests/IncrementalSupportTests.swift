import Foundation
import XCTest
@testable import FlashTeXCore

final class IncrementalSupportTests: XCTestCase {

    // MARK: - AdaptiveDebounce

    func testLocalDelayBase() {
        let d = AdaptiveDebounce.localDelay(baseMs: 250, lastFullCompileSeconds: nil, isBusy: false)
        XCTAssertEqual(d, 0.25, accuracy: 0.0001)
    }

    func testLocalDelayFloor() {
        let d = AdaptiveDebounce.localDelay(baseMs: 10, lastFullCompileSeconds: nil, isBusy: false)
        XCTAssertEqual(d, 0.06, accuracy: 0.0001)
    }

    func testLocalDelayGrowsWithLastCompile() {
        let base = AdaptiveDebounce.localDelay(baseMs: 250, lastFullCompileSeconds: nil, isBusy: false)
        let slow = AdaptiveDebounce.localDelay(baseMs: 250, lastFullCompileSeconds: 5, isBusy: false)
        XCTAssertGreaterThan(slow, base)
        XCTAssertEqual(slow, 0.25 + 5 * 0.05, accuracy: 0.0001)
    }

    func testLocalDelayClamped() {
        let d = AdaptiveDebounce.localDelay(baseMs: 250, lastFullCompileSeconds: 60, isBusy: false)
        XCTAssertEqual(d, 0.6, accuracy: 0.0001)
    }

    func testLocalDelayBusyWidens() {
        let calm = AdaptiveDebounce.localDelay(baseMs: 200, lastFullCompileSeconds: nil, isBusy: false)
        let busy = AdaptiveDebounce.localDelay(baseMs: 200, lastFullCompileSeconds: nil, isBusy: true)
        XCTAssertGreaterThan(busy, calm)
        XCTAssertEqual(busy, min(0.6, 0.2 + 0.15), accuracy: 0.0001)
    }

    // MARK: - IncrementalMetrics

    func testMetricsCountsAndTimings() {
        let m = IncrementalMetrics()
        m.recordDecision(.local(block: dummyBlock()), reasons: [])
        m.recordDecision(.local(block: dummyBlock()), reasons: [])
        m.recordDecision(.regional, reasons: [])
        m.recordDecision(.global, reasons: ["no syncTeX column"])
        m.recordLocalApplied(naturalSize: CGSize(width: 100, height: 30))
        m.recordCacheHit()
        m.recordCacheMiss()
        m.recordLocalRender(time: 0.5)
        m.recordLocalRender(time: 1.5)
        m.recordFullCompile(time: 3.0)

        XCTAssertEqual(m.localAttempts, 2)
        XCTAssertEqual(m.localApplied, 1)
        XCTAssertEqual(m.regionalCount, 1)
        XCTAssertEqual(m.globalCount, 1)
        XCTAssertEqual(m.cacheHits, 1)
        XCTAssertEqual(m.cacheMisses, 1)
        XCTAssertEqual(m.promoteReasons["no syncTeX column"], 1)
        XCTAssertEqual(m.averageLocalRenderTime ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(m.lastFullCompileTime, 3.0)
        XCTAssertTrue(m.summary().contains("local attempts: 2"))
    }

    func testMetricsFallbackAndStale() {
        let m = IncrementalMetrics()
        m.recordFallback()
        m.recordStaleDiscard()
        XCTAssertEqual(m.promoteReasons["geometry changed"], 1)
        XCTAssertEqual(m.staleDiscards, 1)
    }

    private func dummyBlock() -> TeXMathBlock {
        TeXMathBlock(index: 0, kind: .dollarDisplay, range: NSRange(location: 0, length: 4),
                     display: true, body: "x", raw: "$$x$$", lineStart: 1, lineEnd: 1)
    }
}