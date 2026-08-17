import Foundation
import CoreGraphics

// IncrementalMetrics — counters for the incremental rendering subsystem.
//
// Everything the report and the in-app statistics dialog need. Pure value
// type; the app target records into it and reads the summary.

public final class IncrementalMetrics {

    public private(set) var localAttempts = 0
    public private(set) var localApplied = 0
    public private(set) var regionalCount = 0
    public private(set) var globalCount = 0
    public private(set) var cacheHits = 0
    public private(set) var cacheMisses = 0
    public private(set) var staleDiscards = 0
    public private(set) var fullCompileCount = 0

    /// Reason → how many times a local attempt was promoted to full.
    public private(set) var promoteReasons: [String: Int] = [:]

    public private(set) var lastLocalRenderTime: TimeInterval?
    public private(set) var totalLocalRenderTime: TimeInterval = 0
    public private(set) var lastFullCompileTime: TimeInterval?

    public private(set) var lastAppliedPatchPoints: CGSize?

    public init() {}

    public var averageLocalRenderTime: TimeInterval? {
        guard localAttempts > 0 else { return nil }
        return totalLocalRenderTime / Double(localAttempts)
    }

    public func recordDecision(_ scope: EditScope, reasons: [String]) {
        switch scope {
        case .local: localAttempts += 1
        case .regional: regionalCount += 1
        case .global:
            globalCount += 1
            for reason in reasons { promoteReasons[reason, default: 0] += 1 }
        }
    }

    public func recordLocalApplied(naturalSize: CGSize) {
        localApplied += 1
        lastAppliedPatchPoints = naturalSize
    }

    public func recordFallback() {
        globalCount += 1
        promoteReasons["geometry changed", default: 0] += 1
    }

    public func recordCacheHit() { cacheHits += 1 }
    public func recordCacheMiss() { cacheMisses += 1 }
    public func recordStaleDiscard() { staleDiscards += 1 }

    public func recordLocalRender(time: TimeInterval) {
        totalLocalRenderTime += time
        lastLocalRenderTime = time
    }

    public func recordFullCompile(time: TimeInterval) {
        fullCompileCount += 1
        lastFullCompileTime = time
    }

    /// One-line human summary for the in-app statistics dialog.
    public func summary() -> String {
        var s = "Incremental preview\n"
        s += "  local attempts: \(localAttempts), applied: \(localApplied)\n"
        s += "  regional: \(regionalCount), global: \(globalCount)\n"
        s += "  cache: \(cacheHits) hit / \(cacheMisses) miss\n"
        s += "  stale discards: \(staleDiscards)\n"
        if let avg = averageLocalRenderTime {
            s += String(format: "  avg local render: %.2fs (last %.2fs)\n", avg, lastLocalRenderTime ?? 0)
        }
        if let last = lastFullCompileTime {
            s += String(format: "  last full compile: %.2fs\n", last)
        }
        if !promoteReasons.isEmpty {
            s += "  promotions: " + promoteReasons
                .sorted { $0.value > $1.value }
                .map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + "\n"
        }
        return s
    }
}