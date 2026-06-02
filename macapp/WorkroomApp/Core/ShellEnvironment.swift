import Foundation

/// PATH and shell helpers. A `.app` launched from Finder inherits a minimal PATH
/// (`/usr/bin:/bin:/usr/sbin:/sbin`) that excludes Homebrew, where git/jj usually
/// live — so both the bundled `workroom` (which execs git/jj) and the embedded
/// terminals need an augmented PATH.
enum ShellEnvironment {
    static func loginShell() -> String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    static func path() -> String {
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        // Prepend common tool locations (arm64 + Intel Homebrew, /usr/local).
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        var parts: [String] = []
        for p in extra + base.split(separator: ":").map(String.init) where !parts.contains(p) {
            parts.append(p)
        }
        return parts.joined(separator: ":")
    }
}
