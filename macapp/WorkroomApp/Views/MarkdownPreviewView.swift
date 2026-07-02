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
    textView.delegate = context.coordinator  // gate link clicks to web/mail schemes only
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

  final class Coordinator: NSObject, NSTextViewDelegate {
    weak var textView: NSTextView?
    var appliedVersion = -1

    /// Web/mail schemes a rendered-Markdown link may open. A workroom file is untrusted content, so
    /// a `file:` / `javascript:` / custom-scheme link must not reach `NSWorkspace` — its default
    /// click action would launch an app or invoke a scheme handler on one click.
    private static let openableSchemes: Set<String> = ["http", "https", "mailto"]

    /// Intercept link clicks so only allowlisted schemes open; anything else is dropped. Returning
    /// `true` suppresses AppKit's default `NSWorkspace.open` for every link.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      let url: URL? =
        switch link {
        case let value as URL: value
        case let value as String: URL(string: value)
        default: nil
        }
      if let url, let scheme = url.scheme?.lowercased(), Self.openableSchemes.contains(scheme) {
        NSWorkspace.shared.open(url)
      }
      return true
    }
  }
}
