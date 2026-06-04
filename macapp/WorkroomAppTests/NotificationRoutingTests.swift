import XCTest

@testable import Workroom

/// Routing + banner-gating + native-request mapping for notifications (issue #10). These are the
/// pure pieces of the click loop; the SwiftUI/window glue is verified manually (decision 3.1).
final class NotificationRoutingTests: XCTestCase {

  // MARK: TerminalTarget.ID → SidebarID reverse-lookup (AppStore.sidebarID)

  func testReverseLookupRoot() {
    let p = Project(path: "/a", vcs: "git", workrooms: [])
    XCTAssertEqual(AppStore.sidebarID(forTargetID: "root|/a", in: [p]), .root(project: "/a"))
  }

  func testReverseLookupWorkroom() {
    let w = Workroom(name: "foo", path: "/a/foo", vcsName: "git", warnings: [])
    let p = Project(path: "/a", vcs: "git", workrooms: [w])
    XCTAssertEqual(
      AppStore.sidebarID(forTargetID: "wr|/a|foo", in: [p]), .workroom(project: "/a", name: "foo"))
  }

  func testReverseLookupMissingIsNil() {
    let p = Project(path: "/a", vcs: "git", workrooms: [])
    XCTAssertNil(AppStore.sidebarID(forTargetID: "wr|/a|gone", in: [p]))
    XCTAssertNil(AppStore.sidebarID(forTargetID: "root|/gone", in: [p]))
  }

  // MARK: Banner gating (NotificationGate)

  func testBannerOnlyWhenBackgrounded() {
    XCTAssertTrue(NotificationGate.shouldPostBanner(recorded: true, appActive: false))
    XCTAssertFalse(NotificationGate.shouldPostBanner(recorded: true, appActive: true))
    XCTAssertFalse(NotificationGate.shouldPostBanner(recorded: false, appActive: false))
  }

  // MARK: Native request mapping (SystemNotifier.payload)

  func testPayloadIdentifierIsTabAndCarriesIDs() {
    let tab = UUID()
    let notifID = UUID()
    let n = WorkroomNotification(
      id: notifID, targetID: "wr|/a|foo", tabID: tab, kind: .osc, source: "a / foo", title: "T",
      body: "B", date: Date(timeIntervalSince1970: 0), isRead: false, count: 1)
    let p = SystemNotifier.payload(for: n)
    XCTAssertEqual(p.identifier, tab.uuidString)  // one banner per tab → re-post replaces
    XCTAssertEqual(p.title, "T")
    XCTAssertEqual(p.subtitle, "a / foo")  // project/workroom shown as the banner subtitle
    XCTAssertEqual(p.body, "B")
    XCTAssertEqual(p.userInfo["targetID"], "wr|/a|foo")
    XCTAssertEqual(p.userInfo["tabID"], tab.uuidString)
    XCTAssertEqual(p.userInfo["notifID"], notifID.uuidString)
  }

  func testPayloadShowsCoalescedCount() {
    let n = WorkroomNotification(
      id: UUID(), targetID: "t", tabID: UUID(), kind: .bell, source: "", title: "Terminal activity",
      body: "Bell", date: Date(timeIntervalSince1970: 0), isRead: false, count: 4)
    let p = SystemNotifier.payload(for: n)
    XCTAssertEqual(p.body, "Bell (4)")
    XCTAssertNil(p.subtitle)  // empty source → no subtitle
  }
}
