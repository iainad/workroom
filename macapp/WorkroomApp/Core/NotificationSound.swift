import AppKit

/// Plays the in-app arrival chime for a foreground notification (issue #31). macOS exposes no
/// public API to play the exact OS *default notification* sound from inside an app, so this uses a
/// built-in named system sound (the same library the Sound preferences pane lists). The native
/// banner keeps its own `UNNotificationSound.default` for the backgrounded case — the two paths are
/// mutually exclusive (see `NotificationGate`), so there's never a double chime.
///
/// The caller decides *whether* to play (only when the app is frontmost); this helper just plays.
enum NotificationSound {
  /// The system sound name to play. `NSSound(named:)` resolves it from the standard sound library;
  /// returns nil (and we no-op) if the name is ever unavailable.
  static let name = NSSound.Name("Ping")

  static func play() {
    NSSound(named: name)?.play()
  }
}
