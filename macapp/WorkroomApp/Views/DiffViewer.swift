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
  /// Syntax-highlighted new-side lines, keyed by 1-based new-file line number. Empty ⇒ render plain
  /// (the always-available fallback). Built asynchronously off the diff render — highlighting can
  /// never block or break the diff.
  @State private var highlightedLines: [Int: AttributedString] = [:]
  /// Bumped when a diff finishes loading, so the highlight task (keyed on it) re-runs against the
  /// freshly loaded diff without re-fetching the diff on every theme change.
  @State private var loadToken = 0
  /// Intra-line change emphasis (line-relative byte ranges) for replaced lines — deletions by
  /// `oldLine`, additions by `newLine`. Computed synchronously from the diff in `load()`.
  @State private var emphasis: (deletions: [Int: Range<Int>], additions: [Int: Range<Int>]) =
    ([:], [:])
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
      .background(theme.tokens.bg)
      // Re-fetch whenever the file or its source revision changes (preview retarget, tab switch).
      .task(id: "\(descriptor.source)\u{1F}\(descriptor.path)") { await load() }
      // Build (or rebuild) highlighting once a diff is loaded, and re-colour on theme change. Keyed
      // on source+path+theme-generation+load-token so a superseded run is cancelled and a stale
      // result (wrong file or old theme) is never applied.
      .task(id: highlightKey) { await applyHighlight() }
  }

  /// Identity of the current highlight: file + revision + theme generation + which diff load it's
  /// for. Any change cancels the in-flight highlight and starts a fresh, correctly-keyed one.
  private var highlightKey: String {
    "\(descriptor.source)\u{1F}\(descriptor.path)\u{1F}\(theme.generation)\u{1F}\(loadToken)"
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
    highlightedLines = [:]  // drop any previous file's colours immediately (no stale flash)
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
    // Intra-line (character-level) change emphasis is computed straight from the diff (no fetch),
    // so it's available for the immediate render — additions/context get it folded into their
    // syntax-highlighted run later, deletions and pre-parse lines use it directly in `lineRow`.
    if case .loaded(let diff) = state {
      emphasis = IntraLineDiff.emphasis(for: diff)
    } else {
      emphasis = ([:], [:])
    }
    loadToken &+= 1  // signal the highlight task to (re)build against this diff
  }

  /// Build syntax highlighting for the loaded diff, off-main and cancellable. Any miss (no grammar,
  /// no/blocked content, parse failure, stale/cancelled) leaves the diff rendering plain — this can
  /// never block or break the diff. Only additions + context are coloured; deletions stay plain.
  private func applyHighlight() async {
    guard case .loaded(let diff) = state else {
      highlightedLines = [:]
      return
    }
    // Resolve a grammar from the new path, falling back to the old (rename/delete) path.
    let grammar =
      SyntaxLanguage.grammar(forPath: descriptor.path)
      ?? diff.renamedFrom.flatMap { SyntaxLanguage.grammar(forPath: $0) }
    guard let grammar else {
      highlightedLines = [:]
      return
    }
    // New-side content: canned in fixture mode, else the guarded VCS fetch folded into DiffResolver.
    let content =
      UITestFixture.isActive
      ? UITestFixture.fileContent(for: descriptor)
      : await DiffResolver().fileContent(for: descriptor, in: directory)
    guard !Task.isCancelled else { return }
    guard let content else {
      highlightedLines = [:]
      return
    }
    // Parse + resolve captures off the main actor — CPU-bound, bounded by the byte cap.
    let spans = await Task.detached(priority: .utility) {
      SyntaxHighlighter.shared.spans(for: content, grammar: grammar)
    }.value
    guard !Task.isCancelled else { return }
    let lines = DiffHighlightMapper.attributedLines(
      diff: diff, content: content, spans: spans, tokens: theme.tokens,
      additionEmphasis: emphasis.additions)
    guard !Task.isCancelled else { return }
    highlightedLines = lines
  }

  // MARK: Diff body

  private func diffBody(_ diff: UnifiedDiff) -> some View {
    // Vertical-only scroll, eager `VStack` (not `LazyVStack`): the rows soft-wrap via
    // `fixedSize(vertical:)`, and a lazy stack caches a bad height estimate for not-yet-materialised
    // wrapping rows — leaving a blank band in the middle of a tall diff until you scroll it into
    // view. `UnifiedDiff.parse`'s 2000-line cap bounds the row count, so laying them all out up
    // front is affordable and gap-free.
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 0) {
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
    // Deletions never carry syntax highlighting (no new side); additions/context use the highlighted
    // run when one was built. Intra-line change emphasis (deletions + not-yet-highlighted additions)
    // is folded in synchronously here; highlighted additions already carry it from the mapper.
    let highlighted: AttributedString? =
      line.kind == .deletion ? nil : line.newLine.flatMap { highlightedLines[$0] }
    let emphasized: AttributedString? = highlighted == nil ? emphasizedLine(line) : nil

    // `.top` so the gutters + marker align to the first visual line when a long line wraps.
    return HStack(alignment: .top, spacing: 0) {
      gutter(line.oldLine).padding(.leading, 4)
      gutter(line.newLine)
      Text(marker(line.kind))
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(foreground(line.kind))
        .frame(width: 14, alignment: .center)
      Group {
        if let highlighted {
          Text(highlighted)  // syntax foreground + intra-line emphasis background
        } else if let emphasized {
          Text(emphasized)  // plain foreground + intra-line emphasis background
        } else {
          Text(line.text.isEmpty ? " " : line.text).foregroundStyle(foreground(line.kind))
        }
      }
      .font(.system(.body, design: .monospaced))
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
    // A test-observable marker that highlighting was applied (XCUITest can't see colours).
    .accessibilityValue(highlighted != nil ? "highlighted" : "plain")
  }

  /// The intra-line-emphasised text for a replaced line (deeper tint behind the changed bytes), or
  /// `nil` for context lines / lines with no intra-line change. Used for deletions and additions not
  /// yet syntax-highlighted; highlighted additions get the emphasis from the mapper instead.
  private func emphasizedLine(_ line: UnifiedDiff.Line) -> AttributedString? {
    let range: Range<Int>?
    let bg: Color
    switch line.kind {
    case .deletion:
      range = line.oldLine.flatMap { emphasis.deletions[$0] }
      bg = theme.tokens.diffRemoveEmphasisBg
    case .addition:
      range = line.newLine.flatMap { emphasis.additions[$0] }
      bg = theme.tokens.diffAddEmphasisBg
    case .context:
      return nil
    }
    guard let range, !line.text.isEmpty else { return nil }
    return Self.emphasizedPlain(line.text, fg: foreground(line.kind), range: range, bg: bg)
  }

  /// Build a single-colour line with `bg` drawn behind the `range` (line-relative UTF-8 bytes).
  static func emphasizedPlain(_ text: String, fg: Color, range: Range<Int>, bg: Color)
    -> AttributedString
  {
    let bytes = Array(text.utf8)
    let lo = max(0, min(range.lowerBound, bytes.count))
    let hi = max(lo, min(range.upperBound, bytes.count))
    func seg(_ r: Range<Int>, _ background: Color?) -> AttributedString {
      var a = AttributedString(String(decoding: bytes[r], as: UTF8.self))
      a.foregroundColor = fg
      if let background { a.backgroundColor = background }
      return a
    }
    var out = AttributedString()
    if lo > 0 { out.append(seg(0..<lo, nil)) }
    if hi > lo { out.append(seg(lo..<hi, bg)) }
    if hi < bytes.count { out.append(seg(hi..<bytes.count, nil)) }
    return out
  }

  /// A right-aligned, dim line-number cell (blank when the line doesn't exist on that side).
  private func gutter(_ number: Int?) -> some View {
    Text(number.map(String.init) ?? "")
      .font(.system(.caption2, design: .monospaced))
      .foregroundStyle(theme.tokens.fgMuted)
      .frame(width: 26, alignment: .trailing)
      .padding(.trailing, 3)
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
