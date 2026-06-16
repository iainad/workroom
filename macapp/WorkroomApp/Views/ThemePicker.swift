import Defaults
import SwiftUI

/// Theme chooser (issue #36). Primary surface: a searchable list of **families**, each row a dual
/// (light + dark) swatch — pick one and its variant follows the appearance. An "Advanced" expander
/// exposes per-slot overrides (the only way to select a loose `~/.config` theme). Used in Settings
/// and from the `Theme…` (⌘⇧K) command (presented as a sheet).
struct ThemePicker: View {
  private let theme = ThemeService.shared
  @Environment(\.dismiss) private var dismiss
  @Default(.themeFamily) private var familyName
  @Default(.darkThemeOverride) private var darkOverride
  @Default(.lightThemeOverride) private var lightOverride

  /// When true (the ⌘⇧K sheet) the view shows a title bar + Done button; embedded in Settings it
  /// doesn't.
  var presentedAsSheet = false

  @State private var query = ""
  @State private var showAdvanced = false
  @State private var allThemes: [ThemePreview] = []

  private var filteredFamilies: [ThemeFamily] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return ThemeService.families }
    return ThemeService.families.filter { $0.name.localizedCaseInsensitiveContains(q) }
  }

  /// The currently selected family, pinned at the top of the list.
  private var selected: ThemeFamily? {
    ThemeService.families.first { $0.name == familyName }
  }

  private func familyRow(_ family: ThemeFamily) -> some View {
    FamilyRow(
      family: family,
      isActive: family.name == familyName && darkOverride == nil && lightOverride == nil,
      dark: ThemeService.themePreview(named: family.dark),
      light: ThemeService.themePreview(named: family.light)
    )
    .contentShape(Rectangle())
    .onTapGesture { theme.applyFamily(family.name) }
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

      searchField

      ScrollView {
        LazyVStack(spacing: 2) {
          // The selected family is pinned at the top with a rule beneath it, so the current choice
          // is always visible — and it ALSO stays in the full list below in its normal position.
          if let selected {
            familyRow(selected)
            Rectangle()
              .fill(theme.tokens.border)
              .frame(height: 1)
              .padding(.vertical, 5)
          }
          if filteredFamilies.isEmpty {
            Text("No themes match “\(query)”")
              .font(.footnote)
              .foregroundStyle(theme.tokens.fgMuted)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 16)
          } else {
            ForEach(filteredFamilies) { familyRow($0) }
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
      }

      Divider()
      advancedSection
    }
    .frame(width: 300, height: presentedAsSheet ? 460 : 420)
    .task { allThemes = await theme.loadThemes() }
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

  @ViewBuilder private var advancedSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Custom disclosure so the WHOLE row toggles, not just the chevron.
      Button {
        withAnimation(.easeInOut(duration: 0.15)) { showAdvanced.toggle() }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(theme.tokens.fgMuted)
            .rotationEffect(.degrees(showAdvanced ? 90 : 0))
          Text("Advanced — override each mode")
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if showAdvanced {
        overrideRow(label: "Dark", binding: $darkOverride, isDark: true)
        overrideRow(label: "Light", binding: $lightOverride, isDark: false)
        Text(
          "Overrides pick a specific theme for one mode, including any in ~/.config/ghostty/themes."
        )
        .font(.caption).foregroundStyle(theme.tokens.fgDim)
      }
    }
    .font(.subheadline)
    .padding(12)
  }

  private func overrideRow(label: String, binding: Binding<String?>, isDark: Bool) -> some View {
    HStack {
      Text(label).frame(width: 44, alignment: .leading).foregroundStyle(theme.tokens.fg)
      Picker(
        "",
        selection: Binding(
          get: { binding.wrappedValue ?? "" },
          set: { theme.applyOverride($0.isEmpty ? nil : $0, isDark: isDark) })
      ) {
        Text("Family default").tag("")
        Divider()
        ForEach(allThemes) { t in Text(t.name).tag(t.name) }
      }
      .labelsHidden()
    }
  }
}

/// One family row: the family name + a dual swatch (dark variant left, light variant right).
private struct FamilyRow: View {
  private let theme = ThemeService.shared
  let family: ThemeFamily
  let isActive: Bool
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
        .fill(isActive ? theme.tokens.accentSoft : (hovered ? theme.tokens.hover : .clear))
    )
    // A clear accent ring on the selected family so it stands out from hover and the rest.
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(isActive ? theme.tokens.accent : .clear, lineWidth: 1.5)
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
