import AppKit
import SwiftUI

/// A snapshot of every derived UI colour for the active theme, computed once per theme change from
/// the resolved palette (see `ThemeService.applyActiveTheme`). One bg + fg + palette drives the
/// whole chrome: foreground alpha variants give muted/dim text and the faint surface/border/hover
/// fills, the accent comes from `palette[4]` (each theme's signature colour — see issue #36 review).
///
/// SwiftUI views read these via `@Environment(ThemeService.self).tokens.*`, which tracks the
/// dependency so they repaint on a theme change. AppKit / non-SwiftUI sites (terminal focus border,
/// dim scrim) read `ThemeService.shared.tokens` and refresh on `.themeDidChange`.
///
/// Derivation mirrors muxy's `MuxyTheme.Snapshot`. When no theme resolves (first launch before a
/// theme is applied, or a deleted file), the fallbacks are the macOS system colours, so the chrome
/// degrades to the pre-theming native look rather than crashing.
struct ThemeTokens {
  // Bases.
  let nsBg: NSColor
  let nsFg: NSColor
  let bg: Color
  let fg: Color
  // The chrome panel surrounding the terminals (tab bar, pane gutters, title bar): the theme
  // background nudged slightly toward the foreground, so the panel reads as a distinct surface from
  // the terminals themselves (subtly lighter in dark themes, darker in light) without breaking the
  // overall blend.
  let panel: Color
  let nsPanel: NSColor
  let fgMuted: Color  // fg @ 0.65 — secondary text
  let fgDim: Color  // fg @ 0.40 — tertiary text / placeholders
  let surface: Color  // fg @ 0.08 — raised row / panel fill
  let border: Color  // fg @ 0.12 — hairline dividers
  let hover: Color  // fg @ 0.06 — hover wash

  // Accent (palette[4]).
  let accent: Color
  let accentSoft: Color  // accent @ 0.10 — selection wash
  let accentForeground: Color  // black/white for legibility on the accent
  let warning: Color  // palette[3] (yellow)

  // Diff / VCS semantics (palette green/red/cyan).
  let diffAddFg: Color
  let diffRemoveFg: Color
  let diffHunkFg: Color
  let diffAddBg: Color
  let diffRemoveBg: Color
  let diffHunkBg: Color

  // Focused-pane border + unfocused-pane scrim (issue #23 follow-up). Both Color (SwiftUI) and
  // NSColor (AppKit) forms.
  let focused: Color
  let terminalDim: Color
  let nsFocused: NSColor
  let nsTerminalDim: NSColor

  let colorScheme: ColorScheme

  /// Resolve a parsed theme (or fall back to system colours) into the full token set.
  init(
    preview: ThemePreview?,
    fallbackBackground: NSColor = .textBackgroundColor,
    fallbackForeground: NSColor = .textColor
  ) {
    let palette = preview?.palette ?? []
    func p(_ index: Int) -> NSColor? { palette.indices.contains(index) ? palette[index] : nil }

    let bgColor = preview?.background ?? fallbackBackground
    let fgColor = preview?.foreground ?? fallbackForeground
    let accentColor = p(4) ?? .controlAccentColor

    nsBg = bgColor
    nsFg = fgColor
    bg = Color(nsColor: bgColor)
    fg = Color(nsColor: fgColor)
    let panelColor =
      bgColor.usingColorSpace(.sRGB)?
      .blended(withFraction: 0.055, of: fgColor.usingColorSpace(.sRGB) ?? fgColor) ?? bgColor
    nsPanel = panelColor
    panel = Color(nsColor: panelColor)
    fgMuted = Color(nsColor: fgColor.withAlphaComponent(0.65))
    fgDim = Color(nsColor: fgColor.withAlphaComponent(0.40))
    surface = Color(nsColor: fgColor.withAlphaComponent(0.08))
    border = Color(nsColor: fgColor.withAlphaComponent(0.12))
    hover = Color(nsColor: fgColor.withAlphaComponent(0.06))

    accent = Color(nsColor: accentColor)
    accentSoft = Color(nsColor: accentColor.withAlphaComponent(0.10))
    accentForeground = Color(nsColor: Self.contrastingForeground(for: accentColor))
    warning = Color(nsColor: p(3) ?? .systemYellow)

    let addColor = p(2) ?? .systemGreen
    let removeColor = p(1) ?? .systemRed
    let hunkColor = p(6) ?? accentColor
    diffAddFg = Color(nsColor: addColor)
    diffRemoveFg = Color(nsColor: removeColor)
    diffHunkFg = Color(nsColor: hunkColor)
    diffAddBg = Color(nsColor: addColor.withAlphaComponent(0.16))
    diffRemoveBg = Color(nsColor: removeColor.withAlphaComponent(0.16))
    diffHunkBg = Color(nsColor: hunkColor.withAlphaComponent(0.10))

    // The unfocused-pane scrim is the terminal's own background, so it's invisible *over* the
    // background and only washes the pane's text toward it (issue #23 follow-up). The focus border
    // is a soft mid-tone foreground that reads as "the focused one" against the faint hairline.
    nsTerminalDim = bgColor
    nsFocused = fgColor.withAlphaComponent(0.55)
    terminalDim = Color(nsColor: bgColor)
    focused = Color(nsColor: fgColor.withAlphaComponent(0.55))

    colorScheme = Self.luminance(of: bgColor) > 0.5 ? .light : .dark
  }

  /// Relative luminance (sRGB, Rec. 709 coefficients), 0…1.
  static func luminance(of color: NSColor) -> CGFloat {
    guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
    return 0.2126 * srgb.redComponent + 0.7152 * srgb.greenComponent + 0.0722 * srgb.blueComponent
  }

  /// Black on light accents, white on dark ones — for text/icons drawn *on* the accent fill.
  static func contrastingForeground(for color: NSColor) -> NSColor {
    luminance(of: color) > 0.6 ? .black : .white
  }
}
