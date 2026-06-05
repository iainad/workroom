import Combine
import Sparkle

/// Wraps Sparkle's standard updater so SwiftUI can drive it: the "Check for Updates…" menu
/// command and the Settings toggle bind here. The controller starts the updater at launch, so
/// (with SUEnableAutomaticChecks on) it runs scheduled background checks against the appcast
/// feed declared by SUFeedURL in Info.plist, verifying downloads against SUPublicEDKey.
final class Updater: ObservableObject {
  private let controller: SPUStandardUpdaterController

  /// Mirrors `SPUUpdater.canCheckForUpdates` so the menu item disables itself while a check is
  /// already in flight.
  @Published var canCheckForUpdates = false

  init() {
    controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    controller.updater.publisher(for: \.canCheckForUpdates)
      .assign(to: &$canCheckForUpdates)
  }

  /// Show the updater UI now — the user-initiated "Check for Updates…" path.
  func checkForUpdates() {
    controller.updater.checkForUpdates()
  }

  /// Whether Sparkle runs scheduled background checks. Bound to the Settings toggle; Sparkle
  /// persists it under SUEnableAutomaticChecks in UserDefaults.
  var automaticallyChecksForUpdates: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set { controller.updater.automaticallyChecksForUpdates = newValue }
  }
}
