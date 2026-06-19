import AppKit
import XCTest

@testable import Workroom

/// Multi-window foundations (issue #70): windows share one `ProjectStore` but keep independent
/// per-window `AppStore` state, and `WindowRegistry` tracks windows + aggregates their unread counts.
@MainActor
final class MultiWindowTests: XCTestCase {
  private func project(_ path: String, workrooms: [String] = []) -> Project {
    Project(
      path: path, vcs: "jj",
      workrooms: workrooms.map {
        Workroom(name: $0, path: "\(path)/\($0)", vcsName: "jj", warnings: [])
      }
    )
  }

  private func notification(_ targetID: String) -> WorkroomNotification {
    WorkroomNotification(
      id: UUID(), targetID: targetID, tabID: UUID(), kind: .osc, source: "src",
      title: "t", body: nil, date: Date(timeIntervalSince1970: 0), count: 1)
  }

  // MARK: ProjectStore sharing

  func testWindowsShareProjectsButNotSelection() {
    let shared = ProjectStore()
    let a = AppStore(projectStore: shared)
    let b = AppStore(projectStore: shared)

    shared.projects = [project("/p", workrooms: ["w"])]
    XCTAssertEqual(a.projects.map(\.id), ["/p"])
    XCTAssertEqual(b.projects.map(\.id), ["/p"], "both windows read the one shared project list")

    a.selectedTargetID = .root(project: "/p")
    XCTAssertEqual(a.selectedTargetID, .root(project: "/p"))
    XCTAssertNil(b.selectedTargetID, "selection is per-window, not shared")
  }

  func testProxyWritesThroughToSharedStore() {
    let shared = ProjectStore()
    let a = AppStore(projectStore: shared)
    let b = AppStore(projectStore: shared)

    a.projects = [project("/x")]
    XCTAssertEqual(
      shared.projects.map(\.id), ["/x"], "writing via one window updates the shared store")
    XCTAssertEqual(b.projects.map(\.id), ["/x"], "…and is visible to the other window")
  }

  func testIsolatedStoresDoNotShareProjects() {
    let a = AppStore()  // default: its own fresh ProjectStore
    let b = AppStore()
    a.projects = [project("/only-a")]
    XCTAssertTrue(
      b.projects.isEmpty, "bare AppStore() is isolated, so tests never pollute each other")
  }

  // MARK: Blank new windows

  func testInitialRestoreIsOneShot() {
    let shared = ProjectStore()
    XCTAssertTrue(
      shared.consumeInitialRestore(), "the first restoring window claims the saved selection")
    XCTAssertFalse(shared.consumeInitialRestore(), "every later window (incl. ⌘N) starts blank")
    XCTAssertFalse(shared.consumeInitialRestore())
  }

  // MARK: WindowRegistry

  func testRegistryTracksWindowsAndRoutesByWindow() {
    let registry = WindowRegistry()
    let shared = ProjectStore()
    let a = AppStore(projectStore: shared)
    let b = AppStore(projectStore: shared)
    let winA = NSWindow()
    let winB = NSWindow()

    registry.register(window: winA, store: a)
    registry.register(window: winB, store: b)

    XCTAssertEqual(registry.allStores.count, 2)
    XCTAssertTrue(registry.store(for: winA) === a)
    XCTAssertTrue(registry.store(for: winB) === b)

    registry.unregister(window: winA)
    XCTAssertEqual(registry.allStores.count, 1)
    XCTAssertNil(registry.store(for: winA))
  }

  func testRegistryReRegisterIsIdempotent() {
    let registry = WindowRegistry()
    let store = AppStore(projectStore: ProjectStore())
    let win = NSWindow()
    registry.register(window: win, store: store)
    registry.register(window: win, store: store)
    XCTAssertEqual(
      registry.allStores.count, 1, "re-resolving the same window doesn't double-register")
  }

  func testRegistryAggregatesUnreadAcrossWindows() {
    let registry = WindowRegistry()
    let a = AppStore(projectStore: ProjectStore())
    let b = AppStore(projectStore: ProjectStore())
    registry.register(window: NSWindow(), store: a)
    registry.register(window: NSWindow(), store: b)

    a.notifications.seedForTesting([notification("t1")])
    b.notifications.seedForTesting([notification("t2"), notification("t3")])
    registry.recomputeBadge()

    XCTAssertEqual(
      registry.aggregateUnread, 3, "the badge/menu-bar count sums every window's unread")
  }
}
