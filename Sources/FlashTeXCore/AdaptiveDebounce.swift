import Foundation

// AdaptiveDebounce — a small pure helper that widens the local-render debounce
// as the machine gets slower, so a busy system coalesces keystrokes instead of
// spawning doomed pdflatex runs. Fully deterministic → unit-testable.

public enum AdaptiveDebounce {

    /// Effective local delay in seconds.
    ///
    ///   * starts from the user's setting (`baseMs`)
    ///   * grows with the last full-compile duration (heavy documents take
    ///     longer to re-run, so wait longer before committing to an isolated
    ///     render)
    ///   * widens further when the machine is busy
    ///
    /// Clamped to [0.06, 0.6] seconds.
    public static func localDelay(baseMs: Double, lastFullCompileSeconds: Double?,
                                  isBusy: Bool) -> Double {
        let base = max(0.06, baseMs / 1000.0)
        var delay = base
        if let last = lastFullCompileSeconds, last > 2.0 {
            delay = min(0.6, base + last * 0.05)
        }
        if isBusy {
            delay = min(0.6, delay + 0.15)
        }
        return delay
    }
}