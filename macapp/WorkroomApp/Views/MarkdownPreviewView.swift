import AppKit
import SwiftUI

/// Read-only, selectable rendered-Markdown view (preview mode of the file viewer). Hosts an
/// `NSTextView` showing `MarkdownRenderer`'s styled `NSAttributedString` — wrapping, no line-number
/// gutter, with clickable links. Same bare-document-view setup as the source viewer (any added
/// subview/ruler blanks the layer-backed text view under SwiftUI's hosting).
struct MarkdownPreviewView: NSViewRepresentable {
  let attributed: NSAttributedString
  /// Bumped when `attributed` is replaced (content / theme change) so the text storage resets then.
  let version: Int
  let tokens: ThemeTokens

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = true
    scrollView.backgroundColor = NSColor(tokens.bg)

    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    storage.addLayoutManager(layoutManager)
    let container = NSTextContainer(
      containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    layoutManager.addTextContainer(container)

    let textView = NSTextView(
      frame: NSRect(x: 0, y: 0, width: 600, height: 200), textContainer: container)
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = true
    textView.usesFontPanel = false
    textView.allowsUndo = false
    textView.isAutomaticLinkDetectionEnabled = false  // links come from the rendered attributes
    textView.drawsBackground = true
    textView.backgroundColor = NSColor(tokens.bg)
    textView.textColor = tokens.nsFg
    textView.linkTextAttributes = [
      .foregroundColor: NSColor(tokens.accent),
      .underlineStyle: NSUnderlineStyle.single.rawValue,
      .cursor: NSCursor.pointingHand,
    ]
    textView.textContainerInset = NSSize(width: 14, height: 12)
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]

    scrollView.documentView = textView
    context.coordinator.textView = textView
    textView.textStorage?.setAttributedString(attributed)
    context.coordinator.appliedVersion = version
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = context.coordinator.textView else { return }
    textView.backgroundColor = NSColor(tokens.bg)
    scrollView.backgroundColor = NSColor(tokens.bg)
    if context.coordinator.appliedVersion != version {
      textView.textStorage?.setAttributedString(attributed)
      context.coordinator.appliedVersion = version
    }
  }

  final class Coordinator {
    weak var textView: NSTextView?
    var appliedVersion = -1
  }
}
