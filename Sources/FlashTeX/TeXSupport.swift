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
        "/opt/local/bin",       // MacPorts
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    /// Any `bin/*` directories under a versioned TeX Live install (e.g.
    /// /usr/local/texlive/2024/bin/universal-darwin), resolved once and
    /// appended to the lookup list. Symlinks under /Library/TeX/texbin cover
    /// the common case; this catches BasicTeX and parallel TeX Live trees.
    private static let liveBinDirs: [String] = {
        let fm = FileManager.default
        var dirs: [String] = []
        for root in ["/usr/local/texlive", "/usr/local/texlive/2025"] where fm.fileExists(atPath: root) {
            if let years = try? fm.contentsOfDirectory(atPath: root) {
                for year in years where year.allSatisfy({ $0.isNumber }) {
                    let yearDir = "\(root)/\(year)/bin"
                    if let bins = try? fm.contentsOfDirectory(atPath: yearDir) {
                        dirs += bins.map { "\(yearDir)/\($0)" }
                    }
                }
            }
        }
        return dirs
    }()

    /// The current process environment with the TeX/Brew PATH entries
    /// prepended. Prepended entries win over the inherited PATH.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var components = pathCandidates + liveBinDirs
        if let existing = env["PATH"] {
            components.append(existing)
        }
        var seen = Set<String>()
        components = components.filter { seen.insert($0).inserted }
        env["PATH"] = components.joined(separator: ":")
        return env
    }

    /// Locate an executable by name, checking the synthesized PATH plus the
    /// fixed TeX/Brew/TeX Live locations.
    static func findExecutable(_ name: String) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let path = environment()["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/\(name)" }
        }
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// True when at least one TeX engine is installed — i.e. the app can do
    /// useful work. Used by the first-run setup check.
    static func enginesAvailable() -> Bool {
        ["pdflatex", "xelatex", "lualatex"].contains { findExecutable($0) != nil }
    }
}
