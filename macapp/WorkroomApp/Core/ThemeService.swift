import AppKit
import Defaults
import Foundation
import SwiftUI

/// A named theme **family** that bundles a dark and a light variant (issue #36: every theme must
/// support both modes). The user picks one family; the active variant follows the appearance, so
/// "supports dark and light" holds by construction. Power users can override either slot
/// independently (`Defaults[.darkThemeOverride]` / `[.lightThemeOverride]`).
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
  ]

  /// Current chrome tokens. Recomputed only inside `applyActiveTheme()`, so chrome never re-parses
  /// a theme file per frame. `@Observable` → SwiftUI views reading `tokens` repaint on change.
  private(set) var tokens: ThemeTokens

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

  /// The active variant file name for an appearance: a per-slot override if set, else the selected
  /// family's variant, else the Workroom default. Always sanitised (safe to write into the conf).
  nonisolated static func activeThemeName(isDark: Bool) -> String {
    let override = isDark ? Defaults[.darkThemeOverride] : Defaults[.lightThemeOverride]
    let resolved =
      override?.nilIfBlank
      ?? family(named: Defaults[.themeFamily])?.variant(isDark: isDark)
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
    onApplyTerminals?(force)
    NotificationCenter.default.post(name: .themeDidChange, object: nil)
  }

  func applyFamily(_ name: String) {
    Defaults[.themeFamily] = name
    Defaults[.darkThemeOverride] = nil
    Defaults[.lightThemeOverride] = nil
    applyActiveTheme()
  }

  func applyOverride(_ name: String?, isDark: Bool) {
    if isDark {
      Defaults[.darkThemeOverride] = name?.nilIfBlank
    } else {
      Defaults[.lightThemeOverride] = name?.nilIfBlank
    }
    applyActiveTheme()
  }

  /// If the stored family/override no longer resolves to a real theme file (e.g. a `~/.config`
  /// theme was deleted, or an old key references a renamed family), reset to the Workroom default
  /// so the terminal (ghostty) and chrome don't diverge onto different fallbacks.
  private func validateSelection() {
    if Self.family(named: Defaults[.themeFamily]) == nil {
      Defaults[.themeFamily] = Self.defaultFamilyName
    }
    if let name = Defaults[.darkThemeOverride]?.nilIfBlank, Self.themePreview(named: name) == nil {
      Defaults[.darkThemeOverride] = nil
    }
    if let name = Defaults[.lightThemeOverride]?.nilIfBlank, Self.themePreview(named: name) == nil {
      Defaults[.lightThemeOverride] = nil
    }
  }

  // MARK: Discovery (picker)

  /// All available themes, deduped, with `~/.config` overriding bundled (matching ghostty's
  /// terminal precedence), Workroom variants pinned first. Off-main so opening the picker never
  /// hitches.
  func loadThemes() async -> [ThemePreview] {
    await Task.detached { Self.discoverThemes() }.value
  }

  nonisolated static func discoverThemes() -> [ThemePreview] {
    var byName: [String: ThemePreview] = [:]
    // Iterate bundled first, then `~/.config` — last write wins, so user files override bundled
    // (the same precedence ghostty uses for the terminal).
    for dir in themeDirectories().reversed() {
      guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
      for file in files where file != "SOURCE.md" && file != "LICENSE" {
        guard let theme = parseThemeFile(atPath: dir + "/" + file, name: file) else { continue }
        byName[theme.name] = theme
      }
    }
    let pinned = Set(families.first(where: { $0.name == defaultFamilyName })!.variantNames)
    return byName.values.sorted {
      let p0 = pinned.contains($0.name)
      let p1 = pinned.contains($1.name)
      if p0 != p1 { return p0 }
      return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  /// Resolve one theme name to its parsed colours, with `~/.config` winning over bundled — the
  /// SAME precedence as `discoverThemes` and as ghostty's terminal resolution, so chrome and
  /// terminal never diverge for an overridden name.
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

extension ThemeFamily {
  var variantNames: [String] { [dark, light] }
}

extension String {
  fileprivate var nilIfBlank: String? {
    let t = trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
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
