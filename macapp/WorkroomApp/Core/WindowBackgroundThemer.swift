import AppKit
import SwiftUI

/// Extends the active theme into the window's title bar (issue #36). The toolbar's own material is
/// hidden (`.toolbarBackground(.hidden)` in `RootView`) and the title bar is made transparent, so
/// the window's background colour — set here to the active theme background — shows through the top
/// strip. This is the canonical themed-terminal-app look: the title bar matches the terminal and
/// chrome instead of staying system grey/white. Re-applies on `.themeDidChange` so a theme switch
/// repaints the title bar live.
///
/// A zero-size probe view locates the host `NSWindow` once it's mounted.
struct WindowBackgroundThemer: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let probe = NSView(frame: .zero)
    DispatchQueue.main.async { [weak probe] in Self.apply(to: probe?.window) }
    context.coordinator.observer = NotificationCenter.default.addObserver(
      forName: .themeDidChange, object: nil, queue: .main
    ) { [weak probe] _ in
      MainActor.assumeIsolated { Self.apply(to: probe?.window) }
    }
    // AppKit re-lays the traffic lights on resize/fullscreen, resetting our centring — re-apply it.
    context.coordinator.resizeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification, object: nil, queue: .main
    ) { [weak probe] note in
      guard let window = probe?.window, note.object as? NSWindow === window else { return }
      MainActor.assumeIsolated { Self.positionTrafficLights(in: window) }
    }
    return probe
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    Self.apply(to: nsView.window)
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    var observer: NSObjectProtocol?
    var resizeObserver: NSObjectProtocol?
    deinit {
      if let observer { NotificationCenter.default.removeObserver(observer) }
      if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }
  }

  @MainActor private static func apply(to window: NSWindow?) {
    guard let window else { return }
    // Content extends up under the (transparent) title bar so the custom bar can be drawn as the
    // top strip of the content at any height — see `WorkroomTitlebar` / `TitlebarBars`.
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    // No title text in the bar — the leading/trailing title-bar accessories (the unified toolbar) and
    // the workroom tabs carry the chrome; an app-name title would just clutter the row.
    window.titleVisibility = .hidden
    // Hide NavigationSplitView's own toolbar. It looks itemless — `.toolbar(removing: .sidebarToggle)`
    // is meant to clear it (our `LeadingTitlebarBar` carries the real sidebar toggle) — but that removal
    // does NOT take: the live toolbar still carries SwiftUI's `navigationSplitView.toggleSidebar`, a
    // `NSToolbarFlexibleSpaceItem`, and the `splitViewSeparator` tracking item. Our single full-width
    // `.leading` titlebar accessory (TitlebarAccessory, `fillsWidth`) starves the toolbar's content
    // region to ~0pt, so all three items clip into AppKit's "more toolbar items" (») overflow popup —
    // which surfaces centred in the bar whenever nothing opaque (a selected workroom's tab bar /
    // trailing controls) happens to paint over it, e.g. the "Nothing selected" state on a wide/zoomed
    // window. Hiding the toolbar removes the overflow entirely; we use none of its items (the accessory
    // replicates them), and the `.unified` style still applies so the taller title-bar row — the
    // breathing room above/below the controls + workroom tabs — is preserved. `.unified` (vs the
    // shorter `.unifiedCompact`) gives a taller bar with more space beneath it. (Replacing the toolbar
    // outright crashes — SwiftUI owns it — so hide, don't replace.) `.none` separator so no hairline
    // rule appears under the bar when the terminal scrolls.
    window.toolbar?.isVisible = false
    window.toolbarStyle = .unified
    window.titlebarSeparatorStyle = .none
    // The title bar belongs to the chrome panel, so it takes the panel colour (a subtle step off
    // the terminal background) — title bar + tab bar + panel read as one surface, terminals as
    // another (issue #36).
    window.backgroundColor = ThemeService.shared.tokens.nsPanel

    positionTrafficLights(in: window)
    // The buttons are re-laid by AppKit after this pass on first show; re-apply next runloop tick so
    // our centring sticks.
    DispatchQueue.main.async { positionTrafficLights(in: window) }
  }

  /// Vertically centre the traffic-light cluster in the custom title bar. The buttons live in the
  /// native ~32pt title-bar container (centred in it); our bar is taller and drawn as the top strip
  /// of the content, so without this the lights sit too high. Their container is not flipped (y=0 at
  /// its bottom = window top edge), so centring the button on `barHeight/2`-from-the-top means
  /// `origin.y = containerHeight − buttonHeight/2 − barHeight/2`. Re-applied on resize (AppKit resets
  /// the frames). For very tall bars the buttons move below the 32pt container, which is fine — the
  /// content (and our bar) fill the full window with `.fullSizeContentView`.
  @MainActor static func positionTrafficLights(in window: NSWindow) {
    let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    for type in types {
      guard let button = window.standardWindowButton(type), let container = button.superview
      else { continue }
      let targetY = container.bounds.height - button.frame.height / 2 - WorkroomTitlebar.height / 2
      if abs(button.frame.origin.y - targetY) > 0.5 {
        button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: targetY))
      }
    }
  }
}
