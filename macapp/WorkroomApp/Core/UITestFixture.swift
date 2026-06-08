import Foundation

/// UI-testing fixture seam (issue #3 UI tests). When the app is launched with
/// `-WorkroomUITestFixture 1`, `AppStore` loads this deterministic set of fake projects and
/// workrooms instead of reading the developer's real `~/.config/workroom`. The XCUITests
/// (`WorkroomAppUITests`) pass that flag so they're hermetic — they never touch real projects,
/// never depend on what happens to be configured on the machine, and run the same everywhere.
///
/// The fixture targets point at freshly-created temp directories so their terminals still spawn a
/// real login shell (libghostty needs a valid working directory) — the surface mounts and appears
/// in the accessibility tree exactly as it would for a real workroom, which is what the split-pane
/// tests assert on. The app remains a normal app: a regular user never passes the flag, so this
/// code is inert in production.
enum UITestFixture {
  /// The launch-argument / `UserDefaults` key the tests set (highest-priority argument domain).
  static let defaultsKey = "WorkroomUITestFixture"

  /// Whether the app was launched in UI-test fixture mode.
  static var isActive: Bool {
    UserDefaults.standard.bool(forKey: defaultsKey)
  }

  /// Stable display name of the fixture project (also its sidebar accessibility id suffix:
  /// `sidebar.project.<name>`). Deliberately obvious so it never reads as a real project in logs.
  static let projectName = "UITestProject"
  /// Stable name of the fixture workroom (`sidebar.workroom.<name>`).
  static let workroomName = "uitest-room"

  /// The fake project list. Idempotent within a launch: the backing temp directories are created if
  /// missing so each target's terminal can start a shell. The project is reported as `git` so the
  /// sidebar's root row renders normally; no real VCS call is ever made (loading is short-circuited
  /// in `AppStore`, which also skips branch resolution for these paths).
  static func projects() -> [Project] {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("workroom-uitest", isDirectory: true)
    let projectDir = base.appendingPathComponent(projectName, isDirectory: true)
    let workroomDir = base.appendingPathComponent("workrooms", isDirectory: true)
      .appendingPathComponent(workroomName, isDirectory: true)
    for dir in [projectDir, workroomDir] {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return [
      Project(
        path: projectDir.path,
        vcs: "git",
        workrooms: [
          Workroom(name: workroomName, path: workroomDir.path, vcsName: "git", warnings: [])
        ])
    ]
  }
}
