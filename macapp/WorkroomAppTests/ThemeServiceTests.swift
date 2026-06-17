import AppKit
import Defaults
import XCTest

@testable import Workroom

/// Pure-logic tests for the theming engine (issue #36): the ghostty theme-file parser, name
/// sanitisation, and family/override resolution. Filesystem- and UI-free — `activeThemeName`
/// resolves names from the family table + `Defaults`, so it never touches the bundle.
@MainActor
final class ThemeServiceTests: XCTestCase {
  // Save/restore the theme Defaults each test mutates, so tests don't leak into each other or the
  // running app's prefs.
  private var savedFamily: String!
  private var savedAppearance: ThemePreference!

  override func setUp() {
    savedFamily = Defaults[.themeFamily]
    savedAppearance = Defaults[.theme]
  }

  override func tearDown() {
    Defaults[.themeFamily] = savedFamily
    Defaults[.theme] = savedAppearance
  }

  // MARK: parseHex

  func testParseHexWithAndWithoutHash() {
    let a = ThemeService.parseHex("#282a36")
    let b = ThemeService.parseHex("282a36")
    for c in [a, b] {
      let srgb = c?.usingColorSpace(.sRGB)
      XCTAssertEqual(srgb?.redComponent ?? -1, 0x28 / 255, accuracy: 0.001)
      XCTAssertEqual(srgb?.greenComponent ?? -1, 0x2a / 255, accuracy: 0.001)
      XCTAssertEqual(srgb?.blueComponent ?? -1, 0x36 / 255, accuracy: 0.001)
    }
  }

  func testParseHexRejectsBadInput() {
    XCTAssertNil(ThemeService.parseHex("#fff"))  // 3-char shorthand not supported by ghostty files
    XCTAssertNil(ThemeService.parseHex("#12345"))  // wrong length
    XCTAssertNil(ThemeService.parseHex("nothex"))
    XCTAssertNil(ThemeService.parseHex(""))
  }

  // MARK: parseThemeFile

  private func writeTheme(_ contents: String) -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! contents.write(to: url, atomically: true, encoding: .utf8)
    return url.path
  }

  func testParseValidThemeFile() {
    var lines = (0..<16).map { "palette = \($0)=#0000\(String(format: "%02x", $0))" }
    lines.append("background = #1c1c1e")
    lines.append("foreground = #d8d8dc")
    lines.append("cursor-color = #3b9ec4")  // ignored by the parser
    let path = writeTheme(lines.joined(separator: "\n"))
    let preview = ThemeService.parseThemeFile(atPath: path, name: "T")
    XCTAssertNotNil(preview)
    XCTAssertEqual(preview?.palette.count, 16)
    XCTAssertEqual(
      preview?.background.usingColorSpace(.sRGB)?.blueComponent ?? -1, 0x1e / 255, accuracy: 0.001)
    XCTAssertEqual(
      preview?.palette[4].usingColorSpace(.sRGB)?.blueComponent ?? -1, 0x04 / 255, accuracy: 0.001)
  }

  func testParseMissingBackgroundReturnsNil() {
    let path = writeTheme("foreground = #ffffff\npalette = 0=#000000")
    XCTAssertNil(ThemeService.parseThemeFile(atPath: path, name: "T"))
  }

  func testParseIgnoresForeignAndDashedLines() {
    // background-blur / foreground-... and comments must not be mistaken for background/foreground.
    let path = writeTheme(
      "# a comment\nbackground-blur = true\nbackground = #102030\nforeground = #fefefe\nrandom junk"
    )
    let preview = ThemeService.parseThemeFile(atPath: path, name: "T")
    XCTAssertEqual(
      preview?.background.usingColorSpace(.sRGB)?.redComponent ?? -1, 0x10 / 255, accuracy: 0.001)
    // No palette entries → empty palette, but still valid because bg + fg are present.
    XCTAssertEqual(preview?.palette.count, 0)
  }

  // MARK: sanitisation

  func testSanitizeStripsDangerousCharacters() {
    XCTAssertEqual(ThemeService.sanitizedThemeName("Foo\"\n\rBar"), "FooBar")
    XCTAssertEqual(ThemeService.sanitizedThemeName("../etc/passwd"), "..etcpasswd")
    XCTAssertEqual(ThemeService.sanitizedThemeName("Catppuccin Mocha"), "Catppuccin Mocha")
  }

  // MARK: family / override resolution

  func testActiveNamePicksFamilyVariantPerAppearance() {
    Defaults[.theme] = .dark
    Defaults[.themeFamily] = "Catppuccin"
    XCTAssertEqual(ThemeService.activeThemeName(isDark: true), "Catppuccin Mocha")
    XCTAssertEqual(ThemeService.activeThemeName(isDark: false), "Catppuccin Latte")
  }

  func testUnknownFamilyFallsBackToWorkroom() {
    Defaults[.themeFamily] = "DoesNotExist"
    XCTAssertEqual(ThemeService.activeThemeName(isDark: true), "Workroom")
    XCTAssertEqual(ThemeService.activeThemeName(isDark: false), "Workroom Light")
  }

  func testEveryBundledFamilyIsPairComplete() {
    // Issue #36: every theme supports dark AND light — both variant names must be non-empty and
    // distinct (a family is never a single-variant orphan).
    for family in ThemeService.families {
      XCTAssertFalse(family.dark.isEmpty, "\(family.name) missing dark variant")
      XCTAssertFalse(family.light.isEmpty, "\(family.name) missing light variant")
      XCTAssertNotEqual(family.dark, family.light, "\(family.name) dark == light")
    }
  }

  func testWorkroomFamilyIsFirst() {
    XCTAssertEqual(ThemeService.families.first?.name, ThemeService.defaultFamilyName)
  }

  // MARK: dark/light quick toggle (issue #57)

  func testToggledLightDarkFlipsForcedModes() {
    XCTAssertEqual(ThemePreference.light.toggledLightDark, .dark)
    XCTAssertEqual(ThemePreference.dark.toggledLightDark, .light)
  }

  func testToggledLightDarkFromSystemIsAlwaysForced() {
    // From System the toggle resolves the live appearance and lands on a forced mode — never
    // `.system` — so repeat presses flip cleanly between light and dark.
    XCTAssertNotEqual(ThemePreference.system.toggledLightDark, .system)
  }
}
