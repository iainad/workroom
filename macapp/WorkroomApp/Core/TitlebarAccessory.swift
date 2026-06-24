import AppKit
import SwiftUI

/// A titlebar-accessory controller that pins its hosted view to FILL the accessory clip view's height
/// (the full ~52pt title-bar height), so the embedded SwiftUI bar — which fills and vertically centres
/// its buttons — sits on the traffic-light line.
///
/// Why a subclass + `viewDidLayout`: the hosted view's `superview` is **nil immediately after**
/// `addTitlebarAccessoryViewController` on a normally-launched window (it's placed in the clip view a
/// layout pass later), so pinning at install time silently no-ops — the bug that made this look fine in
/// a fixture run (different timing) but render high on a real launch. `viewDidLayout` runs once the view
/// is in the hierarchy. We add the constraints exactly once (the `didPin` guard) — declarative Auto
/// Layout, never a `setFrameOrigin` in a layout pass, which re-enters the accessory's frame-change
/// handler and crashes.
final class FillingTitlebarAccessoryViewController: NSTitlebarAccessoryViewController {
  /// When true, the hosted view is stretched to span the title bar from its (AppKit-placed) leading
  /// edge — just right of the traffic lights — to the window's trailing edge, so a single full-width bar
  /// (leading controls + workroom tabs + trailing controls) fills the whole row. Width is recomputed
  /// every layout pass, so it tracks live window resizes.
  var fillsWidth = false
  private var didPin = false
  private var widthConstraint: NSLayoutConstraint?

  override func viewDidLayout() {
    super.viewDidLayout()
    guard let container = view.superview else { return }
    if !didPin {
      didPin = true
      view.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: container.topAnchor),
        view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      ])
      if fillsWidth {
        let c = view.widthAnchor.constraint(equalToConstant: 0)
        c.isActive = true
        widthConstraint = c
      }
    }
    // `container.frame.minX` is where AppKit placed the accessory (just right of the traffic lights);
    // the rest of the window width, less a small trailing inset, is ours to fill. Recomputed each pass
    // so a window resize re-stretches the bar.
    if fillsWidth, let window = view.window, let widthConstraint {
      let target = max(0, window.frame.width - container.frame.minX - 8)
      if abs(widthConstraint.constant - target) > 0.5 { widthConstraint.constant = target }
    }
  }
}

/// An `NSHostingView` that refuses to let a mouse-down move the window. A title bar is window-draggable
/// by default, and that drag begins on mouse-down — *before* a SwiftUI `DragGesture`'s minimum distance
/// is met — so without this an interactive control hosted in the bar (notably the workroom tab chips,
/// which tap-to-select and drag-to-reorder / drag-into-a-split) would just move the window instead.
/// Returning `false` makes the view claim the mouse-down, so the event reaches SwiftUI. The window stays
/// draggable by its empty regions (the gap between the leading and trailing accessories isn't covered by
/// any hosting view).
final class NonMovableHostingView<Content: View>: NSHostingView<Content> {
  /// Interactive (non-draggable) sub-regions of the bar — the leading controls, the workroom-tab run,
  /// and the trailing controls — in this view's own (flipped, top-left) coordinate space. Published
  /// from a SwiftUI preference by the hosting `Coordinator` (see `titlebarInteractive()`); used to keep
  /// a double-click on a control from being read as an empty-title-bar zoom.
  var interactiveRegions: TitlebarInteractiveRegions?

  override var mouseDownCanMoveWindow: Bool { false }

  /// Claiming the mouse-down (above) also swallows AppKit's native double-click-to-zoom: a
  /// double-click on the title bar normally reaches the window's frame view, which performs the
  /// system "double-click a window's title bar to…" action — but this view now covers the whole
  /// title-bar row, so that click lands here instead and nothing happens (issue #85). Re-implement it
  /// for the *empty* part of the bar only: a double-click that misses every interactive region runs
  /// the user's configured action (`AppleActionOnDoubleClick`: Minimize / Maximize / None —
  /// Maximize/zoom is the macOS default). A double-click on a control, and every single click and
  /// drag, falls through to SwiftUI untouched, so tab tap-to-select and drag-to-reorder keep working;
  /// genuinely empty bar regions also still hit-test nil and get AppKit's native handling.
  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2, let window, !hitsInteractiveRegion(event) {
      switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
      case "Minimize": window.performMiniaturize(nil)
      case "None": break
      default: window.performZoom(nil)
      }
      return
    }
    super.mouseDown(with: event)
  }

  private func hitsInteractiveRegion(_ event: NSEvent) -> Bool {
    guard let rects = interactiveRegions?.rects, !rects.isEmpty else { return false }
    let point = convert(event.locationInWindow, from: nil)
    return rects.contains { $0.contains(point) }
  }
}

/// A box the SwiftUI bar fills with the frames of its interactive controls (in the hosting view's
/// coordinate space) so `NonMovableHostingView` can tell a control double-click from an
/// empty-title-bar one. A reference type so the hosting view and the preference sink share one
/// mutable list without re-creating the view on every layout.
final class TitlebarInteractiveRegions {
  var rects: [CGRect] = []
}

/// The named coordinate space the interactive-region frames are measured in — rooted on the bar's
/// content by the hosting `Coordinator`, so the frames line up with the hosting view's bounds.
let titlebarInteractiveSpace = "workroom.titlebar.interactive"

/// Collects every `titlebarInteractive()` frame into one list for the hosting view.
struct TitlebarInteractiveRectsKey: PreferenceKey {
  static var defaultValue: [CGRect] = []
  static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
    value.append(contentsOf: nextValue())
  }
}

extension View {
  /// Marks this view as an interactive region of the title bar (issue #85): a double-click here is a
  /// control interaction, not an empty-title-bar zoom. Publishes the view's frame — in
  /// `titlebarInteractiveSpace` — up to `NonMovableHostingView`, which excludes it from
  /// double-click-to-zoom. Apply to each control cluster (leading controls, the tab run, trailing
  /// controls), not the full-width bar.
  func titlebarInteractive() -> some View {
    background(
      GeometryReader { geo in
        Color.clear.preference(
          key: TitlebarInteractiveRectsKey.self,
          value: [geo.frame(in: .named(titlebarInteractiveSpace))])
      }
    )
  }
}

/// Hosts arbitrary SwiftUI content as an `NSTitlebarAccessoryViewController` pinned to one edge of
/// the window's title bar — the AppKit escape hatch for the placement control SwiftUI's `.toolbar`
/// withholds.
///
/// Why this exists: in a `NavigationSplitView`, `.toolbar`'s `placement:` is *semantic and
/// column-scoped* — `.primaryAction` means "trailing edge of *this column*", not "trailing edge of
/// the window", and within a placement the only ordering lever is declaration order. A titlebar
/// accessory sidesteps that entirely: its `view` is a plain `NSView` we lay out ourselves, so an
/// embedded SwiftUI `HStack` gets exact spacing, alignment, and ordering across the full window
/// width, independent of the split's columns.
///
/// Mechanics mirror `WindowBackgroundThemer`/`SplitViewAutosave`: a zero-size probe locates the host
/// `NSWindow` once it's mounted, then installs (once, keyed by `identifier`) an accessory whose view
/// is an `NSHostingView`. The hosted SwiftUI tree observes `@EnvironmentObject`/`@Default` normally,
/// so pass any environment objects *inside* the `content` closure (they're captured at install and,
/// being reference types, keep updating the bar live).
struct TitlebarAccessory<Content: View>: NSViewRepresentable {
  /// `.trailing` or `.leading` — the title-bar edge the accessory docks to. (`.bottom` is also legal
  /// but stacks a full-width strip under the title bar, which isn't what we want here.)
  var edge: NSLayoutConstraint.Attribute
  /// Stable id so the accessory is installed exactly once even if SwiftUI re-creates the probe.
  var identifier: NSUserInterfaceItemIdentifier
  /// Stretch the accessory to span the title bar to the window's trailing edge (see
  /// `FillingTitlebarAccessoryViewController.fillsWidth`). Use for the single full-width bar.
  var fillsWidth: Bool = false
  @ViewBuilder var content: () -> Content

  func makeNSView(context: Context) -> NSView {
    context.coordinator.content = content
    let probe = NSView(frame: .zero)
    DispatchQueue.main.async { [weak probe] in
      context.coordinator.install(
        in: probe?.window, edge: edge, identifier: identifier, fillsWidth: fillsWidth)
    }
    return probe
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    // Re-feed the latest closure so a parent re-render (new values captured in `content`) reaches the
    // hosted tree even when SwiftUI's own observation wouldn't.
    context.coordinator.content = content
    context.coordinator.refresh()
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    MainActor.assumeIsolated { coordinator.remove() }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  @MainActor final class Coordinator {
    var content: (() -> Content)?
    private weak var window: NSWindow?
    private var accessory: NSTitlebarAccessoryViewController?
    private var hosting: NonMovableHostingView<AnyView>?
    /// Shared with the hosting view; the SwiftUI sink below keeps it filled with the live frames of
    /// the bar's interactive controls so a double-click on one isn't read as an empty-bar zoom.
    private let regions = TitlebarInteractiveRegions()

    /// Wrap the bar content so (1) interactive-region frames are measured in `titlebarInteractiveSpace`
    /// — rooted here on the content, which fills the hosting view — and (2) their collected frames flow
    /// into the shared `regions` box the hosting view reads in `mouseDown`.
    private func wrapped(_ inner: AnyView) -> AnyView {
      AnyView(
        inner
          .coordinateSpace(name: titlebarInteractiveSpace)
          .onPreferenceChange(TitlebarInteractiveRectsKey.self) { [regions] rects in
            regions.rects = rects
          }
      )
    }

    func install(
      in window: NSWindow?, edge: NSLayoutConstraint.Attribute,
      identifier: NSUserInterfaceItemIdentifier, fillsWidth: Bool
    ) {
      guard let window, let content else { return }
      self.window = window

      // Idempotent: if a previous probe already installed our accessory, adopt it instead of
      // stacking duplicates (SwiftUI may make/dismantle the probe across body re-evaluations).
      if let existing = window.titlebarAccessoryViewControllers.first(where: {
        $0.identifier == identifier
      }) {
        accessory = existing
        hosting = existing.view as? NonMovableHostingView<AnyView>
        hosting?.interactiveRegions = regions
        refresh()
        return
      }

      let host = NonMovableHostingView(rootView: wrapped(AnyView(content())))
      host.interactiveRegions = regions
      host.translatesAutoresizingMaskIntoConstraints = false
      // Size to the SwiftUI content; AppKit pins it to `edge`. Without a concrete frame the accessory
      // can collapse to zero width on first layout.
      host.frame = NSRect(origin: .zero, size: host.fittingSize)

      let controller = FillingTitlebarAccessoryViewController()
      controller.identifier = identifier
      controller.layoutAttribute = edge
      controller.fillsWidth = fillsWidth
      controller.view = host

      window.addTitlebarAccessoryViewController(controller)
      accessory = controller
      hosting = host
    }

    func refresh() {
      guard let content, let hosting else { return }
      hosting.rootView = wrapped(AnyView(content()))
      // Only size the host before Auto Layout owns it. Once the accessory's view is placed in the
      // window's clip view (`superview != nil`), `FillingTitlebarAccessoryViewController` pins it
      // top/bottom + full width, so re-setting the frame here fights those constraints — and, since
      // the hosted `HStack { … }.frame(maxHeight: .infinity)` reports its compact natural height as
      // `fittingSize`, collapses the host before the next layout pass springs it back. That makes the
      // title bar visibly jump on every content update while a command streams output (issue #90).
      if hosting.superview == nil {
        hosting.frame.size = hosting.fittingSize
      }
    }

    func remove() {
      guard let window, let accessory,
        let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory)
      else { return }
      window.removeTitlebarAccessoryViewController(at: index)
      self.accessory = nil
      self.hosting = nil
    }
  }
}
