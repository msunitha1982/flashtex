import Foundation

// CompletionRanker — orders matching candidates by how likely the user's
// learned history says they are, on top of the base matcher.
//
// The base matcher (LaTeXCompletion.matches) is untouched: it filters the
// canonical dictionary down to a candidate list. This ranker only re-orders
// that list using the tracker's signals, so:
//
//   * with no learned history every candidate scores 0 and ties fall back to
//     alphabetical order — the panel behaves exactly as before (cold start)
//   * once the user starts accepting completions, their favourites rise
//   * a completion that has never been chosen still appears, ranked by the
//     base order (personalization never removes or suppresses candidates)
//
// A single accidental pick is not allowed to reshuffle the whole list: the
// personalization layer only engages once the exact query prefix has at least
// `minPrefixObservations` recorded acceptances across its candidates.

public enum CompletionRanker {

    /// Minimum total prefix observations before personalization may reorder.
    public static let minPrefixObservations = 2

    /// Sort `candidates` for the given query prefix, most likely first. Ties
    /// resolve case-insensitively by name for a stable list.
    public static func rank(
        _ candidates: [String],
        prefix: String,
        using tracker: CompletionUsageTracker = .shared
    ) -> [String] {
        guard candidates.count > 1 else { return candidates }
        let evidence = candidates.reduce(0) { $0 + tracker.prefixCount(completionID: $1, prefix: prefix) }
        guard evidence >= minPrefixObservations else { return candidates }
        return candidates.sorted { a, b in
            let sa = tracker.rankingScore(for: a, prefix: prefix)
            let sb = tracker.rankingScore(for: b, prefix: prefix)
            if sa != sb { return sa > sb }
            return a.lowercased() < b.lowercased()
        }
    }
}