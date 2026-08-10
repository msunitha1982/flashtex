import Foundation

// TeX — shared TeX environment helpers.
//
// GUI apps launched from Finder do not inherit the shell's PATH, so we
// explicitly synthesize one that includes the common TeX/Brew locations and
// hand it to every engine Process we spawn:
//   * pdflatex with `-shell-escape` needs PATH to find `asy`
//   * MathRenderer needs PATH so kpsewhich can locate standalone.cls & co.

enum TeX {

    /// PATH candidates for a GUI-launched app, most specific first.
    static let pathCandidates = [
        "/Library/TeX/texbin",
        "/usr/texbin",
        "/usr/local/bin",
        "/opt/homebrew/bin",
    ]

    /// The current process environment with the TeX/Brew PATH entries
    /// prepended. Prepended entries win over the inherited PATH.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var components = pathCandidates
        if let existing = env["PATH"] {
            components.append(existing)
        }
        var seen = Set<String>()
        components = components.filter { seen.insert($0).inserted }
        env["PATH"] = components.joined(separator: ":")
        return env
    }

    /// Locate an executable by name, checking the synthesized PATH plus the
    /// fixed TeX/Brew locations.
    static func findExecutable(_ name: String) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let path = environment()["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/\(name)" }
        }
        candidates += pathCandidates.map { "\($0)/\(name)" }
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
