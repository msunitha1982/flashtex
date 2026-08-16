import Foundation

// CompletionUsageTracker — learns which completions the user actually picks.
//
// Inspired by blink.cmp's frecency and VS Code's recentlyUsedByPrefix. Each
// accepted completion feeds two time-decayed histories:
//
//   * a global frecency score  — how much the user generally likes a completion
//   * a per-prefix affinity    — what the user usually wants given the exact
//                                query prefix that was typed (e.g. "\f")
//
// The score for an item is the sum of its selection events, each decaying
// exponentially with time:
//
//   score(now) = Σ exp(−λ·Δtᵢ)
//
// which is maintained incrementally — on every event the running score is
// multiplied by exp(−λ·Δt) then incremented by one — so we never keep an
// unbounded event log. Old selections fade out, so a completion that was used
// thousands of times months ago can be overtaken by a new favourite.
//
// The final ranking contribution combines that global frecency with the
// prefix-specific affinity gated by a confidence factor C(n) = n/(n+k): a
// single observation is weak evidence, dozens are strong. A completion with no
// history contributes nothing, so the base matcher keeps full control for
// anything the user has never picked.
//
// State lives in memory (read on the main thread) and is persisted to a small
// JSON file asynchronously on a debounced timer; `flush()` is called at
// termination for a final synchronous write.

public final class CompletionUsageTracker {

    public static let shared = CompletionUsageTracker()

    // MARK: - Persisted model

    private struct PrefixStat: Codable {
        var count = 0
        var score = 0.0
        var lastUpdate = Date()
    }

    private struct Record: Codable {
        var completionID: String
        var score = 0.0
        var lastUpdate = Date()
        var total = 0
        var prefixes: [String: PrefixStat] = [:]
    }

    private struct PersistedState: Codable {
        var version = 1
        var records: [String: Record] = [:]
    }

    // MARK: - Tuning

    /// Exponential decay per day (half-life ≈ ln2 / λ ≈ 14 days).
    private let decayPerDay: Double = 0.05
    /// Saturation knee of the saturating transforms (x/(x+k)).
    private let saturatingGlobalK: Double = 25
    private let saturatingPrefixK: Double = 25
    /// Confidence grows as n/(n+k) — k small so ~10 picks already mean something.
    private let confidenceK: Double = 4
    /// Relative weight of the global vs prefix terms.
    private let weightGlobal: Double = 0.5
    private let weightPrefix: Double = 1.0

    private var state = PersistedState()
    private let lock = NSLock()
    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "flashtex.completion-usage", qos: .utility)
    private let saveDelay: TimeInterval = 1.0

    /// - Parameter fileURL: where the JSON history lives. The default resolves
    ///   to `~/Library/Application Support/FlashTeX/completion-usage.json`.
    ///   Tests pass a temporary URL so they never touch real user data.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultDirectory()
        load()
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("FlashTeX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("completion-usage.json")
    }

    // MARK: - Recording

    /// A single accepted completion. Only real acceptances should call this —
    /// tab/return/mouse all funnel through one path — never mere display or
    /// dismissal.
    public func recordSelection(completionID: String, prefix: String, timestamp: Date = Date()) {
        lock.lock(); defer { lock.unlock() }

        var record = state.records[completionID] ?? Record(completionID: completionID)
        record.score = decay(record.score, since: record.lastUpdate, now: timestamp) + 1
        record.lastUpdate = timestamp
        record.total += 1

        var pstat = record.prefixes[prefix] ?? PrefixStat()
        pstat.score = decay(pstat.score, since: pstat.lastUpdate, now: timestamp) + 1
        pstat.lastUpdate = timestamp
        pstat.count += 1
        record.prefixes[prefix] = pstat

        state.records[completionID] = record
        scheduleSave()
    }

    // MARK: - Queries

    /// Global frecency for a completion, decayed to `now`.
    public func frecency(for completionID: String, now: Date = Date()) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let r = state.records[completionID] else { return 0 }
        return decay(r.score, since: r.lastUpdate, now: now)
    }

    /// How strongly this completion is associated with an exact prefix.
    public func prefixAffinity(completionID: String, prefix: String, now: Date = Date()) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let r = state.records[completionID], let p = r.prefixes[prefix] else { return 0 }
        return decay(p.score, since: p.lastUpdate, now: now)
    }

    /// Number of times this completion was picked for this exact prefix.
    public func prefixCount(completionID: String, prefix: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let r = state.records[completionID], let p = r.prefixes[prefix] else { return 0 }
        return p.count
    }

    /// Total times this completion was accepted.
    public func totalSelections(for completionID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return state.records[completionID]?.total ?? 0
    }

    /// The combined ranking signal for a candidate under a query prefix.
    public func rankingScore(for completionID: String, prefix: String, now: Date = Date()) -> Double {
        lock.lock(); defer { lock.unlock() }

        var g = 0.0, p = 0.0
        if let r = state.records[completionID] {
            g = saturating(decay(r.score, since: r.lastUpdate, now: now), k: saturatingGlobalK)
            if let ps = r.prefixes[prefix] {
                let affinity = decay(ps.score, since: ps.lastUpdate, now: now)
                let confidence = Double(ps.count) / (Double(ps.count) + confidenceK)
                p = saturating(affinity, k: saturatingPrefixK) * confidence
            }
        }
        return weightGlobal * g + weightPrefix * p
    }

    // MARK: - Reset / persistence

    /// Clear all learned history (and remove the file).
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        state = PersistedState()
        saveWorkItem?.cancel()
        saveWorkItem = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Blocking write of the current state. Call at application termination so
    /// the last few selections are not lost to the debounce.
    public func flush() {
        lock.lock(); defer { lock.unlock() }
        saveWorkItem?.cancel()
        saveWorkItem = nil
        writeNow()
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        saveWorkItem = work
        saveQueue.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    private func writeNow() {
        let data: Data
        do {
            data = try JSONEncoder().encode(state)
        } catch {
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Non-fatal: history just won't persist if the disk is unavailable.
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return
        }
        state = loaded
    }

    // MARK: - Math

    private func decay(_ score: Double, since: Date, now: Date) -> Double {
        let days = now.timeIntervalSince(since) / 86_400
        guard days > 0 else { return score }
        return score * exp(-decayPerDay * days)
    }

    private func saturating(_ x: Double, k: Double) -> Double {
        x / (x + k)
    }
}