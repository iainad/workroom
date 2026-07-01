import AppKit
import XCTest

@testable import Workroom

/// Unit tests for `MarkdownRenderer` — the pure Markdown→`NSAttributedString` renderer behind the
/// file viewer's preview mode. Asserts the block/inline styling contract (headings, lists, code,
/// links, thematic breaks) on the produced attributed string; no view or repo needed. `@MainActor`
/// only because the theme snapshot is read from the main-actor `ThemeService`.
@MainActor
final class MarkdownRendererTests: XCTestCase {
  private var tokens: ThemeTokens { ThemeService.shared.tokens }

  /// Collect every distinct value of `key` across the string (nil entries skipped).
  private func values<T>(_ s: NSAttributedString, _ key: NSAttributedString.Key, as: T.Type) -> [T]
  {
    var out: [T] = []
    s.enumerateAttribute(key, in: NSRange(location: 0, length: s.length)) { value, _, _ in
      if let v = value as? T { out.append(v) }
    }
    return out
  }

  func testPlainParagraphKeepsText() {
    let s = MarkdownRenderer.attributedString("just some text", tokens: tokens)
    XCTAssertEqual(s.string, "just some text")
  }

  func testHeadingIsEnlarged() {
    let s = MarkdownRenderer.attributedString("# Title", tokens: tokens)
    XCTAssertEqual(s.string, "Title")
    let sizes = values(s, .font, as: NSFont.self).map(\.pointSize)
    XCTAssertTrue(
      sizes.contains { $0 > MarkdownRenderer.baseSize },
      "a level-1 heading should render larger than body text; got \(sizes)")
  }

  func testBoldRunHasBoldTrait() {
    let s = MarkdownRenderer.attributedString("normal **strong** normal", tokens: tokens)
    XCTAssertEqual(s.string, "normal strong normal")
    let bold = values(s, .font, as: NSFont.self).contains {
      $0.fontDescriptor.symbolicTraits.contains(.bold)
    }
    XCTAssertTrue(bold, "**strong** should carry a bold font trait")
  }

  func testLinkCarriesURLAndUnderline() {
    let s = MarkdownRenderer.attributedString("[label](https://example.com)", tokens: tokens)
    XCTAssertEqual(s.string, "label")
    XCTAssertEqual(values(s, .link, as: URL.self), [URL(string: "https://example.com")])
    XCTAssertFalse(values(s, .underlineStyle, as: Int.self).isEmpty, "links are underlined")
  }

  func testUnorderedListRendersBulletMarker() {
    let s = MarkdownRenderer.attributedString("- alpha\n- beta", tokens: tokens)
    XCTAssertTrue(s.string.contains("•"), "unordered items get a bullet marker; got \(s.string)")
    XCTAssertTrue(s.string.contains("alpha") && s.string.contains("beta"))
  }

  func testOrderedListRendersOrdinalMarkers() {
    let s = MarkdownRenderer.attributedString("1. first\n2. second", tokens: tokens)
    XCTAssertTrue(s.string.contains("1. ") && s.string.contains("2. "), "got \(s.string)")
    XCTAssertTrue(s.string.contains("first") && s.string.contains("second"))
  }

  func testCodeBlockHasBackgroundFill() {
    let s = MarkdownRenderer.attributedString("```\nlet x = 1\n```", tokens: tokens)
    XCTAssertTrue(s.string.contains("let x = 1"))
    XCTAssertFalse(
      values(s, .backgroundColor, as: NSColor.self).isEmpty, "fenced code gets a background fill")
  }

  func testThematicBreakRendersRule() {
    let s = MarkdownRenderer.attributedString("above\n\n---\n\nbelow", tokens: tokens)
    XCTAssertTrue(
      s.string.contains(String(repeating: "─", count: 40)), "a `---` renders a horizontal rule")
    XCTAssertTrue(s.string.contains("above") && s.string.contains("below"))
  }

  func testEmptyMarkdownIsEmpty() {
    XCTAssertEqual(MarkdownRenderer.attributedString("", tokens: tokens).string, "")
  }
}
