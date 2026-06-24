import XCTest

@testable import Workroom

/// Tests for the live filesystem watch that keeps the selected workroom's VCS status current
/// (issue #24 follow-up): the FSEvents watcher fires on a real change, and the jj-internal path
/// filter that breaks the snapshot self-trigger loop.
final class WorkroomFileWatcherTests: XCTestCase {

  // MARK: - jj-internal path filter (AppStore.isJJInternalPath)

  func testIsJJInternalPath() {
    // A `.jj` path component ⇒ internal (the jj snapshot writes here; must be ignored for jj).
    XCTAssertTrue(AppStore.isJJInternalPath("/repo/.jj/working_copy/checkout"))
    XCTAssertTrue(AppStore.isJJInternalPath("/repo/.jj"))
    // Working files are not internal — these must still trigger a refresh.
    XCTAssertFalse(AppStore.isJJInternalPath("/repo/src/main.swift"))
    XCTAssertFalse(AppStore.isJJInternalPath("/repo"))
    // Component-based, so a file merely *named* like `.jj…` isn't treated as internal.
    XCTAssertFalse(AppStore.isJJInternalPath("/repo/.jjconfig.toml"))
  }

  // MARK: - VCS metadata dir (AppStore.vcsMetadataDir — root-branch watch target, #3)

  func testVCSMetadataDir() {
    // git/jj map to the metadata dir whose changes signal a branch/bookmark move.
    XCTAssertEqual(AppStore.vcsMetadataDir(path: "/repo", vcs: "git"), "/repo/.git")
    XCTAssertEqual(AppStore.vcsMetadataDir(path: "/repo", vcs: "jj"), "/repo/.jj")
    // Trailing slash is normalized by appendingPathComponent (no double slash).
    XCTAssertEqual(AppStore.vcsMetadataDir(path: "/repo/", vcs: "git"), "/repo/.git")
    // Unknown vcs ⇒ no watch target.
    XCTAssertNil(AppStore.vcsMetadataDir(path: "/repo", vcs: "hg"))
  }

  // MARK: - WorkroomFileWatcher (real FSEvents)

  @MainActor
  func testWatcherFiresOnFileChange() async throws {
    let dir = NSTemporaryDirectory() + "wfw-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let changed = expectation(description: "watcher reports a filesystem change")
    changed.assertForOverFulfill = false  // FSEvents may coalesce into ≥1 callbacks
    let watcher = WorkroomFileWatcher(latency: 0.2) { _ in changed.fulfill() }
    watcher.start(path: dir)
    defer { watcher.stop() }

    // Give FSEvents a beat to arm before mutating, so the write lands inside the stream's window.
    try await Task.sleep(nanoseconds: 300_000_000)
    try "hello".write(toFile: dir + "/file.txt", atomically: true, encoding: .utf8)

    await fulfillment(of: [changed], timeout: 5)
  }

  /// `stop()` is idempotent and safe before any `start` (deinit path / no-selection teardown).
  @MainActor
  func testWatcherStopWithoutStartIsSafe() {
    let watcher = WorkroomFileWatcher { _ in }
    watcher.stop()
    watcher.stop()
  }
}
