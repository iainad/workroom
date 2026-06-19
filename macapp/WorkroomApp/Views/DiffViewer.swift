import SwiftUI

/// Renders a single file's diff inside a content tab (issue #66): a unified, inline view (old/new
/// gutter + colored +/- lines), themed with the shared `diffAdd*/diffRemove*/diffHunk*` tokens.
///
/// Fetch is on-appear via `.task(id:)` keyed on the descriptor's file + revision, so switching to a
/// diff tab (or retargeting the preview to a new file) re-runs `DiffResolver` for the current state —
/// the diff is always fresh, and SwiftUI cancels an in-flight fetch when the view goes away (the
/// command runner SIGKILLs the abandoned git/jj child). Lines render in a `LazyVStack`, so a large
/// diff only builds its visible rows; `UnifiedDiff.parse`'s line cap bounds a pathological file.
struct DiffViewer: View {
  let descriptor: DiffDescriptor
  /// The workroom directory the VCS runs in (resolves the repo-relative path / picks the worktree).
  let directory: String

  @State private var state: LoadState = .loading
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let theme = ThemeService.shared

  enum LoadState: Equatable {
    case loading
    case loaded(UnifiedDiff)
    case binary
    case empty
    case failed(String)
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(theme.tokens.surface)
      // Re-fetch whenever the file or its source revision changes (preview retarget, tab switch).
      .task(id: "\(descriptor.source)\u{1F}\(descriptor.path)") { await load() }
  }

  @ViewBuilder private var content: some View {
    switch state {
    case .loading:
      centered { ProgressView().controlSize(.small) }
    case .loaded(let diff):
      diffBody(diff)
    case .binary:
      message("Binary file", systemImage: "doc.fill", detail: "No text diff to show.")
    case .empty:
      message("No changes", systemImage: "checkmark.circle", detail: nil)
    case .failed(let reason):
      message("Diff unavailable", systemImage: "exclamationmark.triangle", detail: reason)
    }
  }

  private func load() async {
    state = .loading
    // In UI-test fixture mode the workroom path is a fake temp dir with no repo, so serve a canned
    // diff instead of shelling out to git/jj (issue #66 UI tests).
    let result =
      UITestFixture.isActive
      ? UITestFixture.diff(for: descriptor)
      : await DiffResolver().resolve(descriptor, in: directory)
    switch result {
    case .diff(let diff): state = diff.hunks.isEmpty ? .empty : .loaded(diff)
    case .binary: state = .binary
    case .empty: state = .empty
    case .failed(let reason): state = .failed(reason)
    }
  }

  // MARK: Diff body

  private func diffBody(_ diff: UnifiedDiff) -> some View {
    // Vertical-only scroll: a `LazyVStack` needs a bounded cross-axis to lay out, and a
    // bidirectional `ScrollView` proposes an unbounded height that scatters the rows with gaps.
    // Long lines soft-wrap (`fixedSize(vertical:)` on the text) rather than scroll horizontally, so
    // the whole line is always visible and the layout stays gap-free.
    ScrollView(.vertical) {
      LazyVStack(alignment: .leading, spacing: 0) {
        if let from = diff.renamedFrom {
          headerNote("Renamed from \(from)")
        }
        ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
          hunkHeader(hunk.header)
          ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
            lineRow(line)
          }
        }
        if diff.truncated {
          headerNote("Diff truncated — file too large to show in full.")
        }
      }
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
    }
  }

  private func hunkHeader(_ header: String) -> some View {
    Text(header)
      .font(.system(.caption, design: .monospaced))
      .foregroundStyle(theme.tokens.diffHunkFg)
      .padding(.horizontal, 8).padding(.vertical, 3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(theme.tokens.diffHunkBg)
      .accessibilityLabel("Hunk \(header)")
  }

  private func lineRow(_ line: UnifiedDiff.Line) -> some View {
    // `.top` so the gutters + marker align to the first visual line when a long line wraps.
    HStack(alignment: .top, spacing: 0) {
      gutter(line.oldLine)
      gutter(line.newLine)
      Text(marker(line.kind))
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(foreground(line.kind))
        .frame(width: 14, alignment: .center)
      Text(line.text.isEmpty ? " " : line.text)
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(foreground(line.kind))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)  // wrap long lines, never truncate
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(rowBackground(line.kind))
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier("diff.line")
    .accessibilityLabel(accessibilityLabel(line))
  }

  /// A right-aligned, dim line-number cell (blank when the line doesn't exist on that side).
  private func gutter(_ number: Int?) -> some View {
    Text(number.map(String.init) ?? "")
      .font(.system(.caption2, design: .monospaced))
      .foregroundStyle(theme.tokens.fgMuted)
      .frame(width: 40, alignment: .trailing)
      .padding(.trailing, 6)
  }

  private func headerNote(_ text: String) -> some View {
    Text(text)
      .font(.footnote)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8).padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: Empty / error states

  private func message(_ title: String, systemImage: String, detail: String?) -> some View {
    centered {
      VStack(spacing: 6) {
        Image(systemName: systemImage).font(.title2).foregroundStyle(.tertiary)
        Text(title).font(.callout).foregroundStyle(.secondary)
        if let detail, !detail.isEmpty {
          Text(detail).font(.footnote).foregroundStyle(.tertiary)
            .multilineTextAlignment(.center).lineLimit(3)
        }
      }
      .padding(24)
    }
  }

  private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
    inner().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  // MARK: Styling

  private func marker(_ kind: UnifiedDiff.Line.Kind) -> String {
    switch kind {
    case .addition: return "+"
    case .deletion: return "-"
    case .context: return " "
    }
  }

  private func foreground(_ kind: UnifiedDiff.Line.Kind) -> Color {
    switch kind {
    case .addition: return theme.tokens.diffAddFg
    case .deletion: return theme.tokens.diffRemoveFg
    case .context: return .primary
    }
  }

  private func rowBackground(_ kind: UnifiedDiff.Line.Kind) -> Color {
    switch kind {
    case .addition: return theme.tokens.diffAddBg
    case .deletion: return theme.tokens.diffRemoveBg
    case .context: return .clear
    }
  }

  private func accessibilityLabel(_ line: UnifiedDiff.Line) -> String {
    let prefix: String
    switch line.kind {
    case .addition: prefix = "added"
    case .deletion: prefix = "removed"
    case .context: prefix = "unchanged"
    }
    return "\(prefix): \(line.text)"
  }
}
