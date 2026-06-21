import AppKit
import SwiftUI

/// What the `WhatsNewSheet` is currently showing. All cases share one stable `id` so the menu path
/// can swap `.loading` → `.notes`/`.empty`/`.error` in place without dismissing and re-presenting the
/// sheet. The auto (post-update) path always opens straight to `.notes`.
enum WhatsNewSheetContent: Identifiable {
  case loading
  case notes([ReleaseNote])
  case empty
  case error

  var id: String { "whatsNew" }
}

/// The "What's New" dialog: a scrollable list of release notes, shown automatically the first launch
/// after an update and reopenable via Help ▸ What's New…. The menu path shows loading / empty / error
/// states (it was user-invoked, so it always gives feedback); the auto path only ever opens to notes.
struct WhatsNewSheet: View {
  let content: WhatsNewSheetContent
  let onClose: () -> Void

  @Environment(\.openURL) private var openURL
  private let theme = ThemeService.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      body(for: content)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      footer
    }
    .frame(width: 520, height: 600)
    .accessibilityIdentifier("whatsNew.sheet")
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable().scaledToFit().frame(width: 40, height: 40)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("What’s New in Workroom").font(.headline)
        Text("Recent updates").font(.subheadline).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(16)
  }

  @ViewBuilder
  private func body(for content: WhatsNewSheetContent) -> some View {
    switch content {
    case .loading:
      VStack {
        Spacer()
        ProgressView("Loading release notes…")
        Spacer()
      }
    case .notes(let notes):
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          ForEach(notes) { note in releaseSection(note) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    case .empty:
      message(
        "You’re up to date", detail: "No release notes to show for this version.",
        showReleasesLink: true)
    case .error:
      message(
        "Couldn’t load release notes", detail: "Check your connection and try again.",
        showReleasesLink: true)
    }
  }

  private func releaseSection(_ note: ReleaseNote) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(note.title).font(.title3.bold())
        Spacer()
        if let date = note.date {
          Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
        }
      }
      ReleaseNotesMarkdown(markdown: note.bodyMarkdown)
      if let url = note.url {
        Button("View on GitHub ↗") { openURL(url) }
          .buttonStyle(.link)
          .font(.callout)
      }
    }
  }

  private func message(_ title: String, detail: String, showReleasesLink: Bool) -> some View {
    VStack(spacing: 8) {
      Spacer()
      Text(title).font(.headline)
      Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
      if showReleasesLink {
        Button("View on GitHub ↗") { openURL(GitHubReleasesClient.releasesPageURL) }
          .buttonStyle(.link)
      }
      Spacer()
    }
    .padding(24)
  }

  private var footer: some View {
    HStack {
      Spacer()
      Button("Done") { onClose() }
        .keyboardShortcut(.defaultAction)
    }
    .padding(16)
  }
}
