import Combine
import Foundation

/// In-file **Find** for the read-only `PlainFileViewer`. Unlike the terminal find (which libghostty
/// owns), the file viewer is our own SwiftUI view, so we search it ourselves: the pure case-insensitive
/// matcher here (`FileFind.matches`, unit-tested) plus a small observable model the focused viewer
/// feeds its lines into and the find bar drives. Only the focused file pane uses the (shared) model —
/// see `FileFindModel`.

/// One match: a 0-based line index and the character-offset range of the hit within that line.
struct FileFindMatch: Equatable {
  let line: Int
  let range: Range<Int>
}

enum FileFind {
  /// Cap on total matches, so a one-character needle in a huge file can't produce an unbounded list
  /// (and the per-keystroke re-search stays cheap). Beyond this the extra hits simply aren't tracked.
  static let matchCap = 5000

  /// Every case-insensitive match of `needle` across `lines`, in document order (top to bottom,
  /// left to right). An empty needle yields no matches. Pure — unit-tested without a view.
  static func matches(in lines: [String], needle: String) -> [FileFindMatch] {
    guard !needle.isEmpty else { return [] }
    var result: [FileFindMatch] = []
    for (index, line) in lines.enumerated() {
      var searchStart = line.startIndex
      while searchStart < line.endIndex,
        let hit = line.range(
          of: needle, options: .caseInsensitive, range: searchStart..<line.endIndex)
      {
        let lo = line.distance(from: line.startIndex, to: hit.lowerBound)
        let hi = line.distance(from: line.startIndex, to: hit.upperBound)
        result.append(FileFindMatch(line: index, range: lo..<hi))
        if result.count >= matchCap { return result }
        // Advance past this hit; guard against a zero-width range (shouldn't happen for a non-empty
        // needle, but keeps the loop strictly progressing).
        searchStart =
          hit.upperBound > hit.lowerBound ? hit.upperBound : line.index(after: hit.lowerBound)
      }
    }
    return result
  }
}

/// Observable state for the file find bar. The focused `PlainFileViewer` feeds its lines via
/// `setSource`; the bar binds `needle` and reads `matches`/`current`; the viewer reads the same to
/// highlight hits and scroll the current one into view. One shared instance (only the focused file
/// pane searches), owned by `AppStore`.
@MainActor
final class FileFindModel: ObservableObject {
  @Published private(set) var isOpen = false
  @Published private(set) var needle = ""
  @Published private(set) var matches: [FileFindMatch] = []
  /// Index into `matches` of the highlighted hit (0-based); 0 when there are none.
  @Published private(set) var current = 0

  private var lines: [String] = []

  /// Point the model at the focused viewer's content and re-search with the current needle. Called
  /// when the focused file changes (or its content loads).
  func setSource(_ lines: [String]) {
    self.lines = lines
    recompute(resetCurrent: true)
  }

  func open() { isOpen = true }

  func close() {
    isOpen = false
    needle = ""
    matches = []
    current = 0
  }

  /// Set the search text (from the bar's field) and re-search.
  func setNeedle(_ text: String) {
    needle = text
    recompute(resetCurrent: true)
  }

  func next() {
    guard !matches.isEmpty else { return }
    current = (current + 1) % matches.count
  }

  func previous() {
    guard !matches.isEmpty else { return }
    current = (current - 1 + matches.count) % matches.count
  }

  private func recompute(resetCurrent: Bool) {
    matches = FileFind.matches(in: lines, needle: needle)
    current = resetCurrent ? 0 : min(current, max(0, matches.count - 1))
  }

  var currentMatch: FileFindMatch? { matches.indices.contains(current) ? matches[current] : nil }

  var hasMatches: Bool { !matches.isEmpty }

  /// "3/12", "No results", or "" while the field is empty.
  var summary: String {
    if needle.isEmpty { return "" }
    return matches.isEmpty ? "No results" : "\(current + 1)/\(matches.count)"
  }

  /// The hits on a given line with whether each is the current one — for the viewer's per-line
  /// highlighting. Empty for lines with no hits (the common case), so most rows do no work.
  func highlights(onLine line: Int) -> [(range: Range<Int>, isCurrent: Bool)] {
    guard isOpen, !matches.isEmpty else { return [] }
    var out: [(range: Range<Int>, isCurrent: Bool)] = []
    for (offset, match) in matches.enumerated() where match.line == line {
      out.append((match.range, offset == current))
    }
    return out
  }
}
