import XCTest

@testable import Workroom

/// `NotificationCenterStore` computed counts, dismissal, and eviction (issue #10). There is no
/// read state — dismissing deletes — so "seen" notifications never linger. `@MainActor` because the
/// store is main-actor isolated; a fixed clock keeps ordering stable. (Bell coalescing was removed
/// with the libghostty migration — the bell is no longer a recorded activity; see C1.)
@MainActor
final class NotificationStoreTests: XCTestCase {
  private let target = "wr|/p|foo"
  private let otherTarget = "root|/p"

  private func makeStore(cap: Int = 500) -> NotificationCenterStore {
    NotificationCenterStore(cap: cap, now: { Date(timeIntervalSince1970: 0) })
  }

  private func osc(_ title: String) -> TerminalActivity { .osc(title: title, body: nil) }

  func testFocusedEventIsDropped() {
    let s = makeStore()
    let tab = UUID()
    XCTAssertNil(s.record(targetID: target, tabID: tab, activity: osc("x"), focused: true))
    XCTAssertTrue(s.items.isEmpty)
    XCTAssertEqual(s.total, 0)
  }

  func testOSCItemsStayDistinct() {
    let s = makeStore()
    let tab = UUID()
    s.record(targetID: target, tabID: tab, activity: osc("one"), focused: false)
    s.record(targetID: target, tabID: tab, activity: osc("two"), focused: false)
    XCTAssertEqual(s.items.count, 2)
    XCTAssertEqual(s.count(tab: tab), 2)
  }

  func testCountsRollUpTabToTargetToTotal() {
    let s = makeStore()
    let tabA = UUID()
    let tabB = UUID()
    s.record(targetID: target, tabID: tabA, activity: osc("a"), focused: false)
    s.record(targetID: target, tabID: tabB, activity: osc("b"), focused: false)
    s.record(targetID: otherTarget, tabID: UUID(), activity: osc("c"), focused: false)
    XCTAssertEqual(s.count(tab: tabA), 1)
    XCTAssertEqual(s.count(target: target), 2)
    XCTAssertEqual(s.total, 3)
  }

  func testDismissByTabDeletesItsItemsAndLeavesOthers() {
    let s = makeStore()
    let tabA = UUID()
    let tabB = UUID()
    s.record(targetID: target, tabID: tabA, activity: osc("a"), focused: false)
    s.record(targetID: target, tabID: tabB, activity: osc("b"), focused: false)
    s.dismiss(tab: tabA)
    // Dismissed ⇒ gone (not flagged): the item is removed, the other survives.
    XCTAssertEqual(s.items.count, 1)
    XCTAssertEqual(s.count(tab: tabA), 0)
    XCTAssertEqual(s.count(tab: tabB), 1)
    XCTAssertEqual(s.total, 1)
  }

  func testDismissByNotifIDDeletesJustThatItem() {
    let s = makeStore()
    let tab = UUID()
    let one = s.record(targetID: target, tabID: tab, activity: osc("one"), focused: false)
    s.record(targetID: target, tabID: tab, activity: osc("two"), focused: false)
    s.dismiss(notifID: one!.id)
    XCTAssertEqual(s.items.map(\.title), ["two"])
  }

  func testClearRemovesEverything() {
    let s = makeStore()
    s.record(targetID: target, tabID: UUID(), activity: osc("x"), focused: false)
    s.clear()
    XCTAssertTrue(s.items.isEmpty)
    XCTAssertEqual(s.total, 0)
  }

  func testRemoveForTargetReturnsTabsAndDropsItems() {
    let s = makeStore()
    let tabA = UUID()
    let tabB = UUID()
    s.record(targetID: target, tabID: tabA, activity: osc("a"), focused: false)
    s.record(targetID: otherTarget, tabID: tabB, activity: osc("b"), focused: false)
    let dropped = s.removeForTarget(target)
    XCTAssertEqual(dropped, [tabA])
    XCTAssertEqual(s.count(target: target), 0)
    XCTAssertEqual(s.total, 1)
  }

  func testHistoryTrimsToCapDroppingOldest() {
    let s = makeStore(cap: 3)
    for i in 0..<5 {
      s.record(targetID: target, tabID: UUID(), activity: osc("\(i)"), focused: false)
    }
    XCTAssertEqual(s.items.count, 3)
    XCTAssertEqual(s.items.first?.title, "2")  // "0" and "1" evicted
  }
}
