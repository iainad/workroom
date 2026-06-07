import Foundation
import Sentry

/// Sentry SDK setup, kept out of `WorkroomApp.init()` so the app entry point stays readable.
///
/// macOS-trimmed option set: Workroom is macOS-only, so the iOS-only features in Sentry's
/// quick-start are deliberately left off — Session Replay, watchdog-termination tracking, and
/// screenshot/view-hierarchy attachment aren't supported on macOS. What remains is the coverage
/// that's valid here: crash reporting, app-hang detection, tracing, profiling, and metrics.
///
/// The DSN is a *public* client key (safe to embed — it only permits sending events, not reading
/// them), so it ships in the binary; `SENTRY_DSN` overrides it for local experiments. Structured
/// logs (`enableLogs`) are off: it wouldn't pick up the app's existing `os.Logger` calls anyway —
/// surfacing those would need explicit `SentrySDK.capture(...)` at the call sites (the `GhosttyApp`
/// terminal-startup failures being the prime candidates).
enum SentryConfig {
  /// Public ingest DSN. Overridable via `SENTRY_DSN` to point local runs at a different project.
  private static let dsn =
    "https://01c27f42380699d6072a6e30abe6e175@o272130.ingest.us.sentry.io/4511524517249024"

  static func start() {
    SentrySDK.start { options in
      options.dsn = ProcessInfo.processInfo.environment["SENTRY_DSN"] ?? dsn

      // Tag dev builds so local crashes/traces don't pollute the production environment in Sentry.
      // `SENTRY_ENVIRONMENT` overrides either default.
      #if DEBUG
        let defaultEnvironment = "development"
      #else
        let defaultEnvironment = "production"
      #endif
      options.environment =
        ProcessInfo.processInfo.environment["SENTRY_ENVIRONMENT"] ?? defaultEnvironment
      // releaseName defaults to "<bundle id>@<version>+<build>", which release.sh already drives.

      // Error monitoring: crashes + app hangs. Watchdog-termination tracking and the
      // non-fully-blocking app-hang report (`enableReportNonFullyBlockingAppHangs`) are both
      // iOS/tvOS/visionOS-only — unavailable on macOS — so they're left out entirely.
      options.enableCrashHandler = true
      options.enableAppHangTracking = true

      // Don't attach PII (IP address / user context). The SDK default, restated for intent: a local
      // dev tool gains little from it, and it keeps user-identifying data out of events.
      options.sendDefaultPii = false

      // Tracing — auto-instruments app launch, network, and SwiftUI. A desktop app sees low
      // transaction volume, so full sampling is affordable; lower this if that ever changes.
      options.tracesSampleRate = 1.0

      // Profiling (macOS-supported). `.trace` lifecycle ties profiles to sampled transactions.
      options.configureProfiling = {
        $0.sessionSampleRate = 1.0
        $0.lifecycle = .trace
      }

      // Metrics are on by default in SDK 9.12+; explicit for intent.
      options.enableMetrics = true
    }
  }
}
