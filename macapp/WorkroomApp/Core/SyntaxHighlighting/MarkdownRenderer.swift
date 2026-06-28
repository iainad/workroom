import AppKit
import Foundation

/// Renders Markdown source into a styled `NSAttributedString` for the file viewer's preview mode,
/// using Foundation's `AttributedString(markdown:)` (full block syntax) — no third-party dependency.
/// Walks the parsed document block-by-block (`presentationIntent`) applying heading sizes, list
/// bullets/indents, code blocks, block quotes, thematic breaks, and inline emphasis/code/links/strike.
/// Covers READMEs and plan docs; tables and images are not rendered (the inline text is kept).
enum MarkdownRenderer {
  static let baseSize: CGFloat = 13.5

  static func attributedString(_ markdown: String, tokens: ThemeTokens) -> NSAttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      allowsExtendedAttributes: true,
      interpretedSyntax: .full,
      failurePolicy: .returnPartiallyParsedIfPossible)
    guard let doc = try? AttributedString(markdown: markdown, options: options) else {
      return NSAttributedString(
        string: markdown,
        attributes: [.font: NSFont.systemFont(ofSize: baseSize), .foregroundColor: tokens.nsFg])
    }

    let out = NSMutableAttributedString()
    var firstBlock = true

    for (intent, range) in doc.runs[\.presentationIntent] {
      let info = blockInfo(intent)
      if !firstBlock { out.append(NSAttributedString(string: "\n")) }
      firstBlock = false

      if info.isThematicBreak {
        out.append(thematicBreak(tokens: tokens))
        continue
      }

      let paragraph = paragraphStyle(for: info)
      let headingSize = info.headerLevel.map(headerSize) ?? baseSize

      // List bullet / ordinal marker.
      if info.listDepth > 0, let ordinal = info.listItemOrdinal {
        let marker = info.isOrderedList ? "\(ordinal). " : "•  "
        out.append(
          NSAttributedString(
            string: marker,
            attributes: [
              .font: font(size: baseSize, bold: false, italic: false, monospace: false),
              .foregroundColor: NSColor(tokens.fgMuted), .paragraphStyle: paragraph,
            ]))
      }

      // Inline runs within the block.
      let blockSlice = doc[range]
      for run in blockSlice.runs {
        let text = String(blockSlice[run.range].characters)
        guard !text.isEmpty else { continue }
        let inline = run.inlinePresentationIntent ?? []
        let isCode = info.isCodeBlock || inline.contains(.code)
        let bold = info.headerLevel != nil || inline.contains(.stronglyEmphasized)
        let italic = inline.contains(.emphasized)
        let size = (isCode && !info.isCodeBlock) ? baseSize - 0.5 : headingSize

        var attrs: [NSAttributedString.Key: Any] = [
          .paragraphStyle: paragraph,
          .font: font(size: size, bold: bold, italic: italic, monospace: isCode),
          .foregroundColor: info.isBlockQuote ? NSColor(tokens.fgMuted) : tokens.nsFg,
        ]
        if isCode {
          attrs[.backgroundColor] = NSColor(tokens.fgMuted).withAlphaComponent(0.12)
        }
        if inline.contains(.strikethrough) {
          attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = run.link {
          attrs[.foregroundColor] = NSColor(tokens.accent)
          attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
          attrs[.link] = link
        }
        out.append(NSAttributedString(string: text, attributes: attrs))
      }
    }
    return out
  }

  // MARK: Block classification

  private struct BlockInfo {
    var headerLevel: Int?
    var isCodeBlock = false
    var isBlockQuote = false
    var isThematicBreak = false
    var listItemOrdinal: Int?
    var isOrderedList = false
    var listDepth = 0
  }

  private static func blockInfo(_ intent: PresentationIntent?) -> BlockInfo {
    var info = BlockInfo()
    guard let intent else { return info }
    for component in intent.components {
      switch component.kind {
      case .header(let level): info.headerLevel = level
      case .codeBlock: info.isCodeBlock = true
      case .blockQuote: info.isBlockQuote = true
      case .thematicBreak: info.isThematicBreak = true
      case .listItem(let ordinal): info.listItemOrdinal = ordinal
      case .orderedList:
        info.isOrderedList = true
        info.listDepth += 1
      case .unorderedList:
        info.listDepth += 1
      default: break
      }
    }
    return info
  }

  // MARK: Styling

  private static func headerSize(_ level: Int) -> CGFloat {
    switch level {
    case 1: return 26
    case 2: return 21
    case 3: return 17
    case 4: return 15
    case 5: return 14
    default: return baseSize
    }
  }

  private static func paragraphStyle(for info: BlockInfo) -> NSParagraphStyle {
    let p = NSMutableParagraphStyle()
    p.lineSpacing = 2
    p.paragraphSpacing = info.headerLevel != nil ? 6 : 9
    if info.headerLevel != nil { p.paragraphSpacingBefore = 10 }
    if info.listDepth > 0 {
      let indent = CGFloat(info.listDepth) * 22
      p.headIndent = indent
      p.firstLineHeadIndent = indent - 18
      p.paragraphSpacing = 3
    }
    if info.isBlockQuote {
      p.headIndent += 18
      p.firstLineHeadIndent += 18
    }
    return p
  }

  private static func font(size: CGFloat, bold: Bool, italic: Bool, monospace: Bool) -> NSFont {
    if monospace {
      let base = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
      return italic ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
    }
    var traits: NSFontDescriptor.SymbolicTraits = []
    if bold { traits.insert(.bold) }
    if italic { traits.insert(.italic) }
    let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withSymbolicTraits(traits)
    return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size)
  }

  private static func thematicBreak(tokens: ThemeTokens) -> NSAttributedString {
    let p = NSMutableParagraphStyle()
    p.paragraphSpacingBefore = 6
    p.paragraphSpacing = 6
    return NSAttributedString(
      string: String(repeating: "─", count: 40),
      attributes: [
        .font: NSFont.systemFont(ofSize: baseSize),
        .foregroundColor: NSColor(tokens.fgMuted).withAlphaComponent(0.4),
        .paragraphStyle: p,
      ])
  }
}
