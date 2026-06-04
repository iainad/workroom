import AppKit
import SwiftTerm

/// A `LocalProcessTerminalView` that keeps its background/foreground in step with the app's
/// light/dark appearance, using the macOS dynamic system colors (`.textColor` /
/// `.textBackgroundColor` — the same colors the setup-log panel uses, so the two read as one
/// surface). Out of the box SwiftTerm paints with hardcoded defaults (black background, gray
/// foreground) and never reacts to appearance changes, so the embedded terminal ignored the
/// theme toggle entirely.
///
/// Subclassing is the clean lever here: the appearance hooks (`viewDidChangeEffectiveAppearance`,
/// `viewDidMoveToWindow`) are `NSView` methods and overridable, unlike SwiftTerm's
/// `public`-not-`open` mouse methods that the rest of this module routes around (see
/// `CopyOnSelect`). `applyTheme()` is driven from three places because no single one covers
/// everything:
///   - the initializer, so the first paint is themed (no flash of default black);
///   - `viewDidChangeEffectiveAppearance`, for live OS appearance flips while mounted (System
///     mode — no app code is in that loop);
///   - `viewDidMoveToWindow`, so a tab that was detached during a theme change re-themes the
///     instant it remounts.
/// A detached background tab gets none of these, so `TerminalSessions.applyThemeToAll()` sweeps
/// every live terminal on an explicit toggle.
///
/// Non-`final` so `ActivityTerminalView` can layer notification detection (OSC 9/99/777 + bell)
/// on top of theming — both are concerns of the one terminal subclass the app instantiates, kept
/// in separate files. `TerminalSessions.applyThemeToAll()`'s `as? ThemedTerminalView` cast still
/// matches the `ActivityTerminalView` subclass.
class ThemedTerminalView: LocalProcessTerminalView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    applyTheme()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    applyTheme()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { applyTheme() }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyTheme()
  }

  /// Repaint the terminal in the colors of its current effective appearance.
  func applyTheme() {
    // Resolve the dynamic system colors against THIS view's effective appearance: the native
    // color setters flatten the NSColor to concrete RGB immediately (via
    // `usingColorSpace(.deviceRGB)`, which reads the current drawing appearance), so we must
    // make the right appearance current first — true also when called outside a draw cycle (the
    // central sweep) or on a window-less detached view.
    effectiveAppearance.performAsCurrentDrawingAppearance {
      nativeForegroundColor = .textColor
      nativeBackgroundColor = .textBackgroundColor
      // The setters don't touch the layer; mirror the one assignment SwiftTerm makes at setup so
      // the rounded-container edge/margin matches the cells.
      layer?.backgroundColor = nativeBackgroundColor.cgColor
    }
    // Setting the native colors neither clears the per-cell attribute caches nor redraws, so
    // already-drawn cells keep their old colors. `colorChanged(idx: nil)` clears the caches and
    // forces a full repaint; unlike `installColors`, it leaves the 16 ANSI colors alone.
    colorChanged(source: getTerminal(), idx: nil)
  }
}
