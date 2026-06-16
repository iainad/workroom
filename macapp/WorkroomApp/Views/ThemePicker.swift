import Defaults
import SwiftUI

/// Theme chooser (issue #36). A searchable list of **families**, each row a dual (light + dark)
/// swatch — pick one and its variant follows the appearance. The selected family is pinned above
/// the search. Used in Settings and from the `Theme…` (⌘⇧K) command (presented as a sheet).
struct ThemePicker: View {
  private let theme = ThemeService.shared
  @Environment(\.dismiss) private var dismiss
  @Default(.themeFamily) private var familyName

  /// When true (the ⌘⇧K sheet) the view shows a title bar + Done button; embedded in Settings it
  /// doesn't.
  var presentedAsSheet = false

  @State private var query = ""
  /// Index into `filteredFamilies` of the keyboard-highlighted row (↑/↓ move it, ⏎ applies).
  @State private var highlighted = 0

  private var filteredFamilies: [ThemeFamily] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return ThemeService.families }
    return ThemeService.families.filter { $0.name.localizedCaseInsensitiveContains(q) }
  }

  /// The currently selected family, pinned at the top of the list.
  private var selected: ThemeFamily? {
    ThemeService.families.first { $0.name == familyName }
  }

  private func familyRow(_ family: ThemeFamily, highlighted: Bool = false) -> some View {
    FamilyRow(
      family: family,
      isActive: family.name == familyName,
      isHighlighted: highlighted,
      dark: ThemeService.themePreview(named: family.dark),
      light: ThemeService.themePreview(named: family.light)
    )
    .contentShape(Rectangle())
    .onTapGesture { theme.applyFamily(family.name) }
  }

  /// Move the highlight by `delta` (clamped) and apply that family live — ↑/↓ change the theme
  /// immediately, no ⏎ needed.
  private func moveHighlight(_ delta: Int) {
    guard !filteredFamilies.isEmpty else { return }
    highlighted = min(max(highlighted + delta, 0), filteredFamilies.count - 1)
    theme.applyFamily(filteredFamilies[highlighted].name)
  }

  /// Start the highlight on the currently-selected family (or the top), clamped to the list.
  private func resetHighlight() {
    let idx = filteredFamilies.firstIndex { $0.name == familyName } ?? 0
    highlighted = min(max(idx, 0), max(filteredFamilies.count - 1, 0))
  }

  var body: some View {
    VStack(spacing: 0) {
      if presentedAsSheet {
        HStack {
          Text("Theme").font(.headline)
          Spacer()
          Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
        Divider()
      }

      // The selected family is pinned above the search with a rule beneath it, so the current
      // choice is always visible — and it ALSO stays in the searchable list below.
      if let selected {
        familyRow(selected)
          .padding(.horizontal, 10)
          .padding(.top, 8)
        Rectangle()
          .fill(theme.tokens.border)
          .frame(height: 1)
          .padding(.horizontal, 10)
          .padding(.top, 7)
      }

      searchField

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 2) {
            if filteredFamilies.isEmpty {
              Text("No themes match “\(query)”")
                .font(.footnote)
                .foregroundStyle(theme.tokens.fgMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
              ForEach(Array(filteredFamilies.enumerated()), id: \.element.id) { index, family in
                familyRow(family, highlighted: index == highlighted)
                  .id(family.id)
              }
            }
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
        }
        .onChange(of: highlighted) { _, new in
          if filteredFamilies.indices.contains(new) {
            withAnimation(.easeInOut(duration: 0.1)) { proxy.scrollTo(filteredFamilies[new].id) }
          }
        }
      }
    }
    .frame(width: 300, height: presentedAsSheet ? 460 : 420)
    // ↑/↓ move the highlight through the list, ⏎ applies it. The search field keeps text focus;
    // single-line fields don't consume the arrow keys, so they bubble here.
    .onKeyPress(.upArrow) {
      moveHighlight(-1)
      return .handled
    }
    .onKeyPress(.downArrow) {
      moveHighlight(1)
      return .handled
    }
    .onKeyPress(.return) {
      dismiss()
      return .handled
    }
    .onAppear { resetHighlight() }
    .onChange(of: query) { _, _ in highlighted = 0 }
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").foregroundStyle(theme.tokens.fgDim)
      TextField("Search themes", text: $query)
        .textFieldStyle(.plain)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain).foregroundStyle(theme.tokens.fgDim)
        .help("Clear search")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(theme.tokens.surface)
        .overlay(
          RoundedRectangle(cornerRadius: 8).strokeBorder(theme.tokens.border, lineWidth: 0.5))
    )
    .padding(10)
  }
}

/// One family row: the family name + a dual swatch (dark variant left, light variant right).
private struct FamilyRow: View {
  private let theme = ThemeService.shared
  let family: ThemeFamily
  let isActive: Bool
  var isHighlighted = false
  let dark: ThemePreview?
  let light: ThemePreview?
  @State private var hovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(family.name)
          .font(.system(size: 12, weight: isActive ? .semibold : .medium))
          .foregroundStyle(isActive ? theme.tokens.accent : theme.tokens.fg)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(family.name)
        Spacer(minLength: 0)
        if isActive {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(theme.tokens.accent)
        }
      }
      HStack(spacing: 4) {
        Swatch(preview: dark)
        Swatch(preview: light)
      }
      .frame(height: 16)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(
          isActive
            ? theme.tokens.accentSoft
            : (isHighlighted ? theme.tokens.surface : (hovered ? theme.tokens.hover : .clear)))
    )
    // Accent ring on the selected family; a fainter ring on the keyboard-highlighted row so ↑/↓
    // focus is visible even when it isn't the selected one.
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(
          isActive ? theme.tokens.accent : (isHighlighted ? theme.tokens.fgDim : .clear),
          lineWidth: 1.5)
    )
    .onHover { hovered = $0 }
  }
}

/// A single variant preview: the background with an "Ab" sample over a strip of the 16 palette
/// colours — the muxy swatch pattern.
private struct Swatch: View {
  private let theme = ThemeService.shared
  let preview: ThemePreview?

  var body: some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(preview.map { Color(nsColor: $0.background) } ?? theme.tokens.surface)
        .overlay(
          Text("Ab")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(preview.map { Color(nsColor: $0.foreground) } ?? theme.tokens.fgMuted)
        )
        .frame(width: 26)
      ForEach(Array((preview?.palette ?? []).enumerated()), id: \.offset) { _, c in
        Rectangle().fill(Color(nsColor: c))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 3))
    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.tokens.border, lineWidth: 0.5))
  }
}
