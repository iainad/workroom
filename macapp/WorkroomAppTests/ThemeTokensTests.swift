import AppKit
import SwiftUI
import XCTest

@testable import Workroom

/// Derivation tests for `ThemeTokens` (issue #36): one bg + fg + palette must yield the accent,
/// the alpha-variant fills, the diff colours, and the right `colorScheme`. UI- and
/// filesystem-free — previews are built in-memory.
@MainActor
final class ThemeTokensTests: XCTestCase {
  private func ns(_ hex: String) -> NSColor { ThemeService.parseHex(hex)! }

  private func preview(bg: String, fg: String, palette: [String]) -> ThemePreview {
    ThemePreview(name: "T", background: ns(bg), foreground: ns(fg), palette: palette.map(ns))
  }

  /// sRGB components of a SwiftUI Color, for robust comparison.
  private func rgb(_ color: Color) -> (CGFloat, CGFloat, CGFloat) {
    let c = NSColor(color).usingColorSpace(.sRGB)!
    return (c.redComponent, c.greenComponent, c.blueComponent)
  }

  private func assertRGB(_ color: Color, _ hex: String, line: UInt = #line) {
    let got = rgb(color)
    let want = ns(hex).usingColorSpace(.sRGB)!
    XCTAssertEqual(got.0, want.redComponent, accuracy: 0.01, line: line)
    XCTAssertEqual(got.1, want.greenComponent, accuracy: 0.01, line: line)
    XCTAssertEqual(got.2, want.blueComponent, accuracy: 0.01, line: line)
  }

  private func full(
    bg: String, fg: String, accent4: String, green2: String = "#00ff00",
    red1: String = "#ff0000", cyan6: String = "#00ffff", yellow3: String = "#ffff00"
  ) -> ThemePreview {
    var pal = Array(repeating: "#808080", count: 16)
    pal[1] = red1
    pal[2] = green2
    pal[3] = yellow3
    pal[4] = accent4
    pal[6] = cyan6
    return preview(bg: bg, fg: fg, palette: pal)
  }

  func testAccentIsPaletteIndexFour() {
    let t = ThemeTokens(preview: full(bg: "#1c1c1e", fg: "#d8d8dc", accent4: "#3b9ec4"))
    assertRGB(t.accent, "#3b9ec4")
  }

  func testDiffColoursFromPalette() {
    let t = ThemeTokens(preview: full(bg: "#1c1c1e", fg: "#d8d8dc", accent4: "#3b9ec4"))
    assertRGB(t.diffAddFg, "#00ff00")  // palette[2]
    assertRGB(t.diffRemoveFg, "#ff0000")  // palette[1]
    assertRGB(t.diffHunkFg, "#00ffff")  // palette[6]
    assertRGB(t.warning, "#ffff00")  // palette[3]
  }

  func testColorSchemeFromBackgroundLuminance() {
    XCTAssertEqual(
      ThemeTokens(preview: full(bg: "#fbfbfd", fg: "#1d1d1f", accent4: "#1e7fa8")).colorScheme,
      .light)
    XCTAssertEqual(
      ThemeTokens(preview: full(bg: "#1c1c1e", fg: "#d8d8dc", accent4: "#3b9ec4")).colorScheme,
      .dark)
  }

  func testContrastingForeground() {
    XCTAssertEqual(ThemeTokens.contrastingForeground(for: ns("#ffffff")), .black)
    XCTAssertEqual(ThemeTokens.contrastingForeground(for: ns("#000000")), .white)
    XCTAssertEqual(ThemeTokens.contrastingForeground(for: ns("#1c1c1e")), .white)
  }

  func testLuminanceBounds() {
    XCTAssertEqual(ThemeTokens.luminance(of: ns("#ffffff")), 1.0, accuracy: 0.001)
    XCTAssertEqual(ThemeTokens.luminance(of: ns("#000000")), 0.0, accuracy: 0.001)
  }

  func testTerminalDimIsBackgroundAndFocusedIsForeground() {
    let t = ThemeTokens(preview: full(bg: "#1c1c1e", fg: "#d8d8dc", accent4: "#3b9ec4"))
    XCTAssertEqual(
      t.nsTerminalDim.usingColorSpace(.sRGB)?.redComponent ?? -1, 0x1c / 255, accuracy: 0.01)
    let focused = t.nsFocused.usingColorSpace(.sRGB)!
    XCTAssertEqual(focused.redComponent, 0xd8 / 255, accuracy: 0.01)  // fg hue
    XCTAssertEqual(focused.alphaComponent, 0.55, accuracy: 0.01)  // fixed alpha
  }

  func testFallbackToSystemColoursWhenNoPreview() {
    // No theme resolved (first launch / deleted file) → degrade to the pre-theming native look.
    let t = ThemeTokens(preview: nil)
    XCTAssertEqual(t.nsBg, .textBackgroundColor)
    XCTAssertEqual(t.nsFg, .textColor)
  }

  func testAlphaVariantsDeriveFromForeground() {
    let t = ThemeTokens(preview: full(bg: "#000000", fg: "#ffffff", accent4: "#3b9ec4"))
    // surface/border/hover are foreground at low alpha — over a black bg they read as faint greys.
    let surface = NSColor(t.surface).usingColorSpace(.sRGB)!
    XCTAssertEqual(surface.alphaComponent, 0.08, accuracy: 0.01)
  }
}
