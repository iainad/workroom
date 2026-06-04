import XCTest

@testable import Workroom

/// `NotificationCenterStore` coalescing, computed counts, read-state, and eviction (issue #10).
/// `@MainActor` because the store is main-actor isolated; a fixed clock keeps ordering stable.
@MainActor
final class NotificationStoreTests: XCTestCase {
  private let target = "wr|/p|foo"
  private let otherTarget = "root|/p"

  private func makeStore(cap: Int = 500) -> NotificationCenterStore {
    NotificationCenterStore(cap: cap, now: { Date(timeIntervalSince1970: 0) })
  }

  func testFocusedEventIsDropped() {
    let s = makeStore()
    let tab = UUID()
    XCTAssertNil(s.record(targetID: target, tabID: tab, activity: .bell, focused: true))
    XCTAssertTrue(s.items.isEmpty)
    XCTAssertEqual(s.totalUnread, 0)
  }

  func testBellCoalescesPerTab() {
    let s = makeStore()
    let tab = UUID()
    for _ in 0..<3 {
      s.record(targetID: target, tabID: tab, activity: .bell, focused: false)
    }
    XCTAssertEqual(s.items.count, 1)
    XCTAssertEqual(s.items[0].count, 3)
    XCTAssertEqual(s.unread(tab: tab), 3)
  }

  func testOSCItemsStayDistinct() {
    let s = makeStore()
    let tab = UUID()
    s.record(targetID: target, tabID: tab, activity: .osc(title: "one", body: nil), focused: false)
    s.record(targetID: target, tabID: tab, activity: .osc(title: "two", body: nil), focused: false)
    XCTAssertEqual(s.items.count, 2)
    XCTAssertEqual(s.unread(tab: tab), 2)
  }

  func testCountsRollUpTabToTargetToTotal() {
    let s = makeStore()
    let tabA = UUID()
    let tabB = UUID()
    s.record(targetID: target, tabID: tabA, activity: .osc(title: "a", body: nil), focused: false)
    s.record(targetID: target, tabID: tabB, activity: .osc(title: "b", body: nil), focused: false)
    s.record(targetID: otherTarget, tabID: UUID(), activity: .bell, focused: false)
    XCTAssertEqual(s.unread(tab: tabA), 1)
    XCTAssertEqual(s.unread(target: target), 2)
    XCTAssertEqual(s.totalUnread, 3)
  }

  func testMarkReadByTabLeavesOthers() {
    let s = makeStore()
    let tabA = UUID()
    let tabB = UUID()
    s.record(targetID: target, tabID: tabA, activity: .osc(title: "a", body: nil), focused: false)
    s.record(targetID: target, tabID: tabB, activity: .osc(title: "b", body: nil), focused: false)
    s.markRead(tab: tabA)
    XCTAssertEqual(s.unread(tab: tabA), 0)
    XCTAssertEqual(s.unread(tab: tabB), 1)
    XCTAssertTrue(s.hasUnread)
  }

  func testMarkAllRead() {
    let s = makeStore()
    s.record(targetID: target, tabID: UUID(), activity: .bell, focused: false)
    s.markAllRead()
    XCTAssertFalse(s.hasUnread)
    XCTAssertEqual(s.totalUnread, 0)
  }

  func testBellReArmsAfterRead() {
    let s = makeStore()
    let tab = UUID()
    s.record(targetID: target, tabID: tab, activity: .bell, focused: false)
    s.markRead(tab: tab)
    s.record(targetID: target, tabID: tab, activity: .bell, focused: false)
    // The read bell isn't coalesced into; a fresh unread item is created.
    XCTAssertEqual(s.items.count, 2)
    XCTAssertEqual(s.unread(tab: tab), 1)
  }

  func testRemoveForTargetReturnsTabsAndDropsItems() {
    let s = makeStore()
    let tabA = UUID()
    let tabB = UUID()
    s.record(targetID: target, tabID: tabA, activity: .osc(title: "a", body: nil), focused: false)
    s.record(targetID: otherTarget, tabID: tabB, activity: .bell, focused: false)
    let dropped = s.removeForTarget(target)
    XCTAssertEqual(dropped, [tabA])
    XCTAssertEqual(s.unread(target: target), 0)
    XCTAssertEqual(s.totalUnread, 1)
  }

  func testHistoryTrimsToCapDroppingOldest() {
    let s = makeStore(cap: 3)
    for i in 0..<5 {
      s.record(
        targetID: target, tabID: UUID(), activity: .osc(title: "\(i)", body: nil), focused: false)
    }
    XCTAssertEqual(s.items.count, 3)
    XCTAssertEqual(s.items.first?.title, "2")  // "0" and "1" evicted
  }
}
