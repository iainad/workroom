import AppKit
import Defaults
import Foundation
import SwiftUI

/// A named theme **family** that bundles a dark and a light variant (issue #36: every theme must
/// support both modes). The user picks one family; the active variant follows the appearance, so
/// "supports dark and light" holds by construction.
struct ThemeFamily: Identifiable, Hashable {
  let name: String
  let dark: String  // dark-variant theme-file name (resolved by ghostty + parsed for chrome)
  let light: String  // light-variant theme-file name

  var id: String { name }

  func variant(isDark: Bool) -> String { isDark ? dark : light }
}

/// A parsed ghostty theme file: the colours we need for chrome tokens and picker swatches.
/// (The *terminal* gets these straight from ghostty's native `theme=` resolution; we parse the same
/// file so the chrome derives from identical colours — see `GhosttyApp.writeThemeConfig`.)
struct ThemePreview: Identifiable, Hashable {
  let name: String
  let background: NSColor
  let foreground: NSColor
  let palette: [NSColor]
  var id: String { name }
}

@MainActor @Observable
final class ThemeService {
  static let shared = ThemeService()

  nonisolated static let defaultFamilyName = "Workroom"

  /// The curated, pair-complete bundled families. Each variant name is a file in
  /// `Resources/ghostty/themes` (and resolvable by ghostty). `Workroom` is pinned first.
  nonisolated static let families: [ThemeFamily] = [
    ThemeFamily(name: "Workroom", dark: "Workroom", light: "Workroom Light"),
    ThemeFamily(name: "Catppuccin", dark: "Catppuccin Mocha", light: "Catppuccin Latte"),
    ThemeFamily(name: "Tokyo Night", dark: "TokyoNight Night", light: "TokyoNight Day"),
    ThemeFamily(name: "Gruvbox", dark: "Gruvbox Dark", light: "Gruvbox Light"),
    ThemeFamily(name: "Nord", dark: "Nord", light: "Nord Light"),
    ThemeFamily(name: "One Half", dark: "One Half Dark", light: "One Half Light"),
    ThemeFamily(name: "GitHub", dark: "GitHub Dark", light: "GitHub Light Default"),
    ThemeFamily(name: "Rosé Pine", dark: "Rose Pine", light: "Rose Pine Dawn"),
    ThemeFamily(name: "Everforest", dark: "Everforest Dark Hard", light: "Everforest Light Med"),
    ThemeFamily(name: "Ayu", dark: "Ayu Mirage", light: "Ayu Light"),
    ThemeFamily(name: "Kanagawa", dark: "Kanagawa Wave", light: "Kanagawa Lotus"),
    ThemeFamily(name: "Kanso", dark: "Kanso Zen", light: "Kanso Pearl"),
    ThemeFamily(name: "Monokai Pro", dark: "Monokai Pro", light: "Monokai Pro Light"),
    ThemeFamily(name: "Solarized", dark: "iTerm2 Solarized Dark", light: "iTerm2 Solarized Light"),
    ThemeFamily(name: "Xcode", dark: "Xcode Dark", light: "Xcode Light"),
    ThemeFamily(name: "Flexoki", dark: "Flexoki Dark", light: "Flexoki Light"),
    ThemeFamily(name: "Atom One", dark: "Atom One Dark", light: "Atom One Light"),
    ThemeFamily(name: "Nightfox", dark: "Nightfox", light: "Dayfox"),
    ThemeFamily(name: "Melange", dark: "Melange Dark", light: "Melange Light"),
    ThemeFamily(name: "Modus", dark: "Modus Vivendi", light: "Modus Operandi"),
    ThemeFamily(name: "Iceberg", dark: "Iceberg Dark", light: "Iceberg Light"),
    ThemeFamily(name: "Selenized", dark: "Selenized Dark", light: "Selenized Light"),
    ThemeFamily(
      name: "Gruvbox Material", dark: "Gruvbox Material Dark", light: "Gruvbox Material Light"),
    ThemeFamily(name: "Tomorrow", dark: "Tomorrow Night", light: "Tomorrow"),
    ThemeFamily(name: "Duskfox", dark: "Duskfox", light: "Dawnfox"),
    ThemeFamily(name: "Seoulbones", dark: "Seoulbones Dark", light: "Seoulbones Light"),
    ThemeFamily(name: "Pencil", dark: "Pencil Dark", light: "Pencil Light"),
  ]

  /// Current chrome tokens. Recomputed only inside `applyActiveTheme()`, so chrome never re-parses
  /// a theme file per frame. `@Observable` → SwiftUI views reading `tokens` repaint on change.
  private(set) var tokens: ThemeTokens

  /// Monotonic counter bumped on every theme apply. Diff syntax highlighting keys its async
  /// recolour task on this (plus source+path) so a theme switch rebuilds the coloured lines and a
  /// result computed against the old theme is discarded as stale.
  private(set) var generation: Int = 0

  /// Set once at startup (by the app) to the terminal re-theme step — keeps the surface iteration
  /// in `TerminalSessions` while `applyActiveTheme()` stays the single chokepoint every trigger
  /// routes through. `force` re-themes even when the appearance is unchanged (a same-mode theme
  /// switch).
  var onApplyTerminals: ((_ force: Bool) -> Void)?

  init() {
    let isDark = Self.isCurrentAppearanceDark()
    tokens = ThemeTokens(preview: Self.themePreview(named: Self.activeThemeName(isDark: isDark)))
  }

  // MARK: Resolution (static — also called by GhosttyApp.writeThemeConfig without the instance)

  nonisolated static func family(named name: String) -> ThemeFamily? {
    families.first { $0.name == name }
  }

  /// The active variant file name for an appearance: the selected family's variant for that mode,
  /// else the Workroom default. Always sanitised (safe to write into the conf).
  nonisolated static func activeThemeName(isDark: Bool) -> String {
    let resolved =
      family(named: Defaults[.themeFamily])?.variant(isDark: isDark)
      ?? family(named: defaultFamilyName)!.variant(isDark: isDark)
    return sanitizedThemeName(resolved)
  }

  /// Strip anything that would break or inject into the generated `ghostty.conf` (the name is
  /// written as `theme = "<name>"`), and reject path separators so a crafted `~/.config` filename
  /// can't escape the themes dir.
  nonisolated static func sanitizedThemeName(_ name: String) -> String {
    name.filter { $0 != "\"" && $0 != "\n" && $0 != "\r" && $0 != "/" && $0 != "\\" }
  }

  // MARK: The chokepoint

  /// THE single apply path. Every trigger (picker selection, appearance change, first run) routes
  /// here. Steps: (1) validate the active name resolves — reset to Workroom if not, so terminal
  /// *and* chrome fall back to the *same* theme; (2) recompute chrome tokens; (3) re-theme live
  /// terminals (regenerates the conf with the new `theme=` and force-reloads); (4) notify AppKit
  /// sites that read `ThemeService.shared.tokens` outside SwiftUI.
  func applyActiveTheme(force: Bool = true) {
    validateSelection()
    let isDark = Self.isCurrentAppearanceDark()
    tokens = ThemeTokens(preview: Self.themePreview(named: Self.activeThemeName(isDark: isDark)))
    generation &+= 1
    onApplyTerminals?(force)
    NotificationCenter.default.post(name: .themeDidChange, object: nil)
  }

  func applyFamily(_ name: String) {
    Defaults[.themeFamily] = name
    applyActiveTheme()
  }

  /// If the stored family no longer resolves (e.g. an old key references a renamed family), reset
  /// to the Workroom default so the terminal (ghostty) and chrome don't diverge onto different
  /// fallbacks.
  private func validateSelection() {
    if Self.family(named: Defaults[.themeFamily]) == nil {
      Defaults[.themeFamily] = Self.defaultFamilyName
    }
  }

  // MARK: Resolution

  /// Resolve one theme name to its parsed colours, with `~/.config` winning over bundled — the
  /// SAME precedence as ghostty's terminal resolution, so chrome and terminal never diverge for a
  /// user-overridden theme file.
  nonisolated static func themePreview(named name: String) -> ThemePreview? {
    for dir in themeDirectories() {
      let path = dir + "/" + name
      if FileManager.default.fileExists(atPath: path),
        let theme = parseThemeFile(atPath: path, name: name)
      {
        return theme
      }
    }
    return nil
  }

  /// User config dir first (wins on resolution), bundled dir second.
  nonisolated static func themeDirectories() -> [String] {
    var dirs = [NSHomeDirectory() + "/.config/ghostty/themes"]
    if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes").path {
      dirs.append(bundled)
    }
    return dirs
  }

  // MARK: Theme-file parser (ported from muxy — pure)

  nonisolated static func parseThemeFile(atPath path: String, name: String) -> ThemePreview? {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    var bg: NSColor?
    var fg: NSColor?
    var palette: [Int: NSColor] = [:]
    for line in content.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("background"), !trimmed.hasPrefix("background-") {
        bg = extractColor(from: trimmed)
      } else if trimmed.hasPrefix("foreground"), !trimmed.hasPrefix("foreground-") {
        fg = extractColor(from: trimmed)
      } else if trimmed.hasPrefix("palette") {
        parsePaletteEntry(trimmed, into: &palette)
      }
    }
    guard let bg, let fg else { return nil }
    let sorted = (0..<16).compactMap { palette[$0] }
    return ThemePreview(name: name, background: bg, foreground: fg, palette: sorted)
  }

  nonisolated private static func parsePaletteEntry(
    _ line: String, into palette: inout [Int: NSColor]
  ) {
    guard let eq = line.firstIndex(of: "=") else { return }
    let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
    guard let eq2 = value.firstIndex(of: "="), let index = Int(value[..<eq2]),
      (0..<16).contains(index),
      let color = parseHex(String(value[value.index(after: eq2)...]))
    else { return }
    palette[index] = color
  }

  nonisolated private static func extractColor(from line: String) -> NSColor? {
    guard let eq = line.firstIndex(of: "=") else { return nil }
    return parseHex(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
  }

  nonisolated static func parseHex(_ hex: String) -> NSColor? {
    var h = hex
    if h.hasPrefix("#") { h = String(h.dropFirst()) }
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
    return NSColor(
      srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
      green: CGFloat((v >> 8) & 0xFF) / 255,
      blue: CGFloat(v & 0xFF) / 255,
      alpha: 1)
  }

  // MARK: Appearance

  nonisolated static func isCurrentAppearanceDark() -> Bool {
    // Honour a forced ThemePreference; otherwise follow the OS effective appearance.
    switch Defaults[.theme] {
    case .light: return false
    case .dark: return true
    case .system:
      return NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
  }
}

extension Notification.Name {
  /// Posted by `ThemeService.applyActiveTheme` after tokens + terminals are re-themed, so AppKit
  /// sites that read `ThemeService.shared.tokens` outside a SwiftUI body can refresh.
  static let themeDidChange = Notification.Name("workroom.themeDidChange")

  /// Posted by the `Theme…` (⌘⇧K) command; `RootView` presents the picker as a sheet (a menu
  /// command can't anchor a popover).
  static let showThemePicker = Notification.Name("workroom.showThemePicker")
}
