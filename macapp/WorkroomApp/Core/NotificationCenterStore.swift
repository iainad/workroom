import Foundation

/// A notification-worthy signal a terminal emitted. Detection is explicit-only: the program
/// (or shell) asks for attention via an OSC escape sequence, or the terminal rings the bell.
/// Plain output is deliberately NOT a signal (see issue #10 review, decision 1.1b).
enum TerminalActivity: Equatable {
  case bell
  case osc(title: String, body: String?)
}

/// One entry in the in-memory notification history. Named `WorkroomNotification` (not
/// `Notification`) to avoid clashing with `Foundation.Notification`. Identity for routing a
/// click back to a live terminal is `(targetID, tabID)`; both are session-scoped (tab ids are
/// per-launch UUIDs), so history is intentionally session-only — see `NotificationCenterStore`.
struct WorkroomNotification: Identifiable, Equatable {
  enum Kind: Equatable { case bell, osc }

  let id: UUID
  let targetID: TerminalTarget.ID
  let tabID: TerminalTab.ID
  let kind: Kind
  /// Human-readable origin captured at record time — the project name (and workroom, for a
  /// workroom terminal), e.g. "platform" or "platform / fix-auth". Shown in the panel + banner.
  let source: String
  var title: String
  var body: String?
  var date: Date
  var isRead: Bool
  /// Number of coalesced events this entry represents (bells coalesce per tab; OSC entries
  /// stay distinct, so theirs is always 1).
  var count: Int
}

/// The notification spine: an in-memory, session-only history that drives every surface
/// (system banner, sidebar/tab/toolbar badges, the inspector panel). Owned by `AppStore`
/// (`let notifications = NotificationCenterStore()`), mirroring `let terminals = TerminalSessions()`.
///
/// Unread counts are COMPUTED by scanning `items` (capped at 500) rather than maintained as
/// incremental tallies — there is nothing to keep in sync, so a badge can't drift (issue #10
/// review, cross-model tension 1).
///
/// ```
///   record(target,tab,activity, focused) ─▶ focused? drop
///                                          ─▶ bell: coalesce into the tab's unread bell item
///                                          ─▶ osc:  append a distinct item
///                                          ─▶ trim to 500 (drop oldest)
///   unread(tab|target) / totalUnread  = scan items where !isRead, sum .count
///   markRead(...) / removeForTarget    = in-place flag / filter
/// ```
@MainActor
final class NotificationCenterStore: ObservableObject {
  @Published private(set) var items: [WorkroomNotification] = []

  /// Bounds memory and keeps the panel list snappy under a chatty emitter (decision 4.1).
  private let cap: Int
  /// Injectable clock so coalescing/ordering is unit-testable (mirrors `BranchResolver`'s runner).
  private let now: () -> Date

  init(cap: Int = 500, now: @escaping () -> Date = Date.init) {
    self.cap = cap
    self.now = now
  }

  // MARK: Recording

  /// Record an activity event. Returns the resulting entry when something was recorded (so the
  /// caller can decide whether to also post a system banner), or `nil` when the event was
  /// dropped because the user is already looking at that terminal.
  @discardableResult
  func record(
    targetID: TerminalTarget.ID, tabID: TerminalTab.ID, source: String = "",
    activity: TerminalActivity, focused: Bool
  ) -> WorkroomNotification? {
    guard !focused else { return nil }

    switch activity {
    case .bell:
      // Coalesce into this tab's existing unread bell entry so a script ringing the bell in a
      // loop doesn't spawn hundreds of items (the badge just counts up).
      if let idx = items.firstIndex(where: { $0.tabID == tabID && $0.kind == .bell && !$0.isRead })
      {
        items[idx].count += 1
        items[idx].date = now()
        return items[idx]
      }
      return append(
        WorkroomNotification(
          id: UUID(), targetID: targetID, tabID: tabID, kind: .bell, source: source,
          title: "Terminal activity", body: "Bell", date: now(), isRead: false, count: 1))

    case .osc(let title, let body):
      // OSC notifications carry a real message — keep each one distinct in the history.
      return append(
        WorkroomNotification(
          id: UUID(), targetID: targetID, tabID: tabID, kind: .osc, source: source,
          title: title.isEmpty ? "Notification" : title, body: body, date: now(), isRead: false,
          count: 1))
    }
  }

  @discardableResult
  private func append(_ n: WorkroomNotification) -> WorkroomNotification {
    items.append(n)
    if items.count > cap {
      items.removeFirst(items.count - cap)
    }
    return n
  }

  // MARK: Derived counts (computed scans — no incremental state to drift)

  func unread(tab: TerminalTab.ID) -> Int {
    items.lazy.filter { $0.tabID == tab && !$0.isRead }.reduce(0) { $0 + $1.count }
  }

  func unread(target: TerminalTarget.ID) -> Int {
    items.lazy.filter { $0.targetID == target && !$0.isRead }.reduce(0) { $0 + $1.count }
  }

  var totalUnread: Int {
    items.lazy.filter { !$0.isRead }.reduce(0) { $0 + $1.count }
  }

  var hasUnread: Bool { items.contains { !$0.isRead } }

  // MARK: Mutations

  func markRead(notifID: UUID) { markRead { $0.id == notifID } }
  func markRead(tab: TerminalTab.ID) { markRead { $0.tabID == tab } }
  func markRead(target: TerminalTarget.ID) { markRead { $0.targetID == target } }
  func markAllRead() { markRead { _ in true } }

  private func markRead(_ matches: (WorkroomNotification) -> Bool) {
    for i in items.indices where !items[i].isRead && matches(items[i]) {
      items[i].isRead = true
    }
  }

  /// Drop a deleted target's items (so a removed workroom's badges/history disappear). Returns
  /// the affected tab ids so the caller can also withdraw any delivered system banners.
  @discardableResult
  func removeForTarget(_ target: TerminalTarget.ID) -> [TerminalTab.ID] {
    let dropped = Set(items.filter { $0.targetID == target }.map(\.tabID))
    items.removeAll { $0.targetID == target }
    return Array(dropped)
  }

  func clear() { items.removeAll() }
}

/// Pure decode of an OSC notification payload into a `TerminalActivity`. Extracted (and pure)
/// so the grammar is unit-testable without a live terminal — the handler receives the raw,
/// un-decoded bytes after the code (SwiftTerm strips the `ESC ] <code> ;` prefix and the
/// BEL/ST terminator for us).
enum OSCNotification {
  static func parse(code: Int, _ data: ArraySlice<UInt8>) -> TerminalActivity? {
    guard let text = String(bytes: data, encoding: .utf8) else { return nil }
    switch code {
    case 777: return parse777(text)
    case 9: return parse9(text)
    case 99: return parse99(text)
    default: return nil
    }
  }

  /// urxvt/tmux: `notify;<title>;<body…>` (body may itself contain `;`).
  static func parse777(_ text: String) -> TerminalActivity? {
    let parts = text.components(separatedBy: ";")
    guard parts.count >= 3, parts[0] == "notify" else { return nil }
    let title = parts[1]
    let body = parts[2...].joined(separator: ";")
    return .osc(title: title, body: body.isEmpty ? nil : body)
  }

  /// iTerm2-style growl: `9;<message>`. SwiftTerm otherwise claims OSC 9 for ConEmu progress
  /// (`9;4;state;pct`); a leading `4;` is that progress grammar and is ignored (we don't
  /// surface progress). Everything else is treated as the notification message.
  static func parse9(_ text: String) -> TerminalActivity? {
    if text.hasPrefix("4;") { return nil }
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : .osc(title: t, body: nil)
  }

  /// kitty: `<metadata>;<payload>`. v1 handles the common single-message case only; a
  /// `d=0` continuation marker (more chunks coming) is unsupported and ignored.
  static func parse99(_ text: String) -> TerminalActivity? {
    guard let semi = text.firstIndex(of: ";") else {
      let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? nil : .osc(title: t, body: nil)
    }
    let metadata = text[..<semi]
    if metadata.contains("d=0") { return nil }
    let payload = text[text.index(after: semi)...].trimmingCharacters(in: .whitespacesAndNewlines)
    return payload.isEmpty ? nil : .osc(title: payload, body: nil)
  }
}

/// Pure gate for whether an event that was recorded should also raise a native banner: only
/// when the app is NOT frontmost (in-app badges always carry the foreground case). Extracted
/// so the rule is unit-testable without `NSApp` (decision 1.2).
enum NotificationGate {
  static func shouldPostBanner(recorded: Bool, appActive: Bool) -> Bool {
    recorded && !appActive
  }
}
