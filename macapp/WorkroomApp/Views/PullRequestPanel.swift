import SwiftUI

/// The "Pull Request" inspector section (issue #24, Phase 2): the pull request for the selected
/// workroom's branch — its state (open/draft/merged/closed), number, title (a link), and review
/// decision. Read-only in this iteration; create/merge/rebase actions come later. Reads
/// `store.selectedTargetID` + `store.workroomStatuses[sid].pr`, which a slow `gh pr list` probe
/// fills on selection (like CI). Covers the same edge states as the Changes panel: nothing
/// selected, a project (non-target), still-probing, and no PR for the branch.
struct PullRequestPanel: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.openURL) private var openURL

  var body: some View {
    Group {
      if store.githubCLIStatus != .available {
        // gh can't be used → the PR (and CI) probes can't run; explain why instead of a blank/"no PR".
        ghWarning(store.githubCLIStatus)
      } else if let sid = store.selectedTargetID, sid.isStatusable {
        content(for: sid)
      } else {
        inspectorMessage("Select a workroom to see its pull request.")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Warning shown when `gh` isn't installed or isn't signed in — the GitHub-backed PR/CI data
  /// can't be fetched, so say why and how to fix it rather than silently showing nothing.
  private func ghWarning(_ status: GitHubCLIStatus) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
          .accessibilityHidden(true)
        Text(status == .notInstalled ? "GitHub CLI not found" : "GitHub CLI not signed in")
          .fontWeight(.medium)
        Spacer(minLength: 0)
      }
      .font(.callout)
      Text(
        status == .notInstalled
          ? "Install the gh command-line tool to see pull requests and CI status."
          : "Run \u{201C}gh auth login\u{201D} in a terminal to see pull requests and CI status."
      )
      .font(.footnote).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if status == .notInstalled, let url = URL(string: "https://cli.github.com") {
        Link("Install gh\u{2026}", destination: url).font(.footnote).help("Open cli.github.com")
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func content(for sid: SidebarID) -> some View {
    let status = store.workroomStatuses[sid]
    if status?.prCheckedAt == nil {
      inspectorMessage("Checking\u{2026}")
    } else if let status {
      // GitHub status for the branch: the PR (or "no PR"), and — only when there's an actual PR —
      // its CI checks: a summary line plus one row per individual check (issue #75). A branch with
      // no PR shows just "No pull request" (no CI rows).
      VStack(alignment: .leading, spacing: 8) {
        if let pr = status.pr {
          prRows(pr)
          // Summary glyph, tappable → the PR's "/checks" tab. Derived from the loaded per-check list
          // so it can't contradict the rows below; falls back to the branch CI aggregate
          // (`WorkroomStatus.ci`) only before checks have loaded (see `checksSummaryGlyph`).
          if let summary = checksSummaryGlyph(status) {
            ciRow(summary, checksURL: URL(string: pr.url + "/checks"))
          }
          checkRows(status)
        } else {
          noPullRequestRow
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private func prRows(_ pr: PullRequestInfo) -> some View {
    let badge = PRPresentation.badge(pr)
    // Status + an open-in-browser affordance, linking to the PR. The number lives in the section
    // header badge now, so it's dropped here.
    Button {
      if let url = URL(string: pr.url) { openURL(url) }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: badge.symbol).foregroundStyle(badge.semantic.color)
        Text(badge.label).fontWeight(.medium).foregroundStyle(badge.semantic.color)
        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .font(.callout)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Open pull request #\(String(pr.number)) in browser")
    .accessibilityLabel("\(badge.label), pull request #\(String(pr.number)), open in browser")
    Text(pr.title)
      .font(.callout)
      .foregroundStyle(.primary)
      .lineLimit(2).truncationMode(.tail)
    // Aggregate decision header (issue #52): always shown when GitHub reports one, so a
    // branch-protected PR that's REVIEW_REQUIRED with no named reviewers still shows a signal.
    if let review = PRPresentation.reviewLabel(pr.reviewDecision) {
      Text(review).font(.footnote).foregroundStyle(.secondary)
    }
    // One row per reviewer: state glyph + name + state label (e.g. "Copilot in progress",
    // "iainad approved"). Glyph + label carry the meaning without relying on color. A reviewer who
    // has *submitted* a review carries its permalink, so that row becomes a tappable open-in-browser
    // link (same chevron affordance as the PR/CI rows) that jumps straight to their comment.
    ForEach(PRPresentation.reviewers(pr)) { reviewer in
      if let url = reviewer.url.flatMap(URL.init(string:)) {
        Button {
          openURL(url)
        } label: {
          reviewerRow(reviewer, linked: true)
        }
        .buttonStyle(.plain)
        .help("Open \(reviewer.displayName)\u{2019}s review on GitHub")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reviewer.accessibility), open review on GitHub")
      } else {
        reviewerRow(reviewer, linked: false)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(reviewer.accessibility)
      }
    }
  }

  /// A single reviewer row. `linked` adds the open-in-browser chevron (and a hit-testable shape)
  /// used when the reviewer has a review permalink to deep-link to.
  private func reviewerRow(_ reviewer: PRPresentation.ReviewerBadge, linked: Bool) -> some View {
    statusLinkRow(
      symbol: reviewer.symbol, color: reviewer.semantic.color, name: reviewer.displayName,
      stateLabel: reviewer.stateLabel, linked: linked)
  }

  /// A status row: a colored glyph + a primary name + a secondary state label, with an optional
  /// open-in-browser chevron (and hit-testable shape) when `linked`. Used by the per-reviewer rows
  /// (issue #52); CI-check rows use the leaner `checkRow` (glyph + name only).
  private func statusLinkRow(
    symbol: String, color: Color, name: String, stateLabel: String, linked: Bool
  ) -> some View {
    HStack(spacing: 6) {
      Image(systemName: symbol).foregroundStyle(color)
      Text(name).font(.footnote).lineLimit(1).truncationMode(.tail)
      Text(stateLabel).font(.footnote).foregroundStyle(.secondary)
      if linked {
        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
  }

  /// The summary CI glyph for the panel: derived from the loaded per-check list (so it never
  /// contradicts the rows), falling back to the branch CI aggregate (`WorkroomStatus.ci`) only before checks load.
  /// `checksCheckedAt` is the loaded marker — once set, the (possibly empty) `checks` is authoritative.
  private func checksSummaryGlyph(_ s: WorkroomStatus) -> VCSStatusPresentation.CIGlyph? {
    if s.checksCheckedAt != nil {
      return PRPresentation.checksSummary(s.checks ?? [])
    }
    return VCSStatusPresentation.ci(s)
  }

  @ViewBuilder
  private func checkRows(_ status: WorkroomStatus) -> some View {
    ForEach(PRPresentation.checks(status.checks ?? [])) { check in
      if let url = check.link.flatMap(URL.init(string:)) {
        Button {
          openURL(url)
        } label: {
          checkRow(check)
        }
        .buttonStyle(.plain)
        .help("Open \(check.name) check on GitHub")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(check.accessibility), open check on GitHub")
      } else {
        checkRow(check)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(check.accessibility)
      }
    }
  }

  /// A single CI-check row: just the status glyph + the check name. The glyph alone carries the
  /// state (the per-state label is redundant), and no open-in-browser chevron — the whole row is the
  /// tap target. VoiceOver still gets the state via the row's `accessibilityLabel`.
  private func checkRow(_ check: PRPresentation.CheckBadge) -> some View {
    HStack(spacing: 6) {
      Image(systemName: check.symbol).foregroundStyle(check.semantic.color)
      Text(check.name).font(.footnote).lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
  }

  private var noPullRequestRow: some View {
    HStack(spacing: 6) {
      Image(systemName: "arrow.triangle.branch").font(.callout).foregroundStyle(.tertiary)
      Text("No pull request").font(.callout).foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("No pull request")
  }

  @ViewBuilder
  private func ciRow(_ ci: VCSStatusPresentation.CIGlyph, checksURL: URL?) -> some View {
    if let checksURL {
      // Tappable like the PR status row above — opens the Checks tab in the browser, with the same
      // open-in-browser chevron affordance.
      Button {
        openURL(checksURL)
      } label: {
        HStack(spacing: 5) {
          Image(systemName: ci.symbol).foregroundStyle(ci.semantic.color)
          Text(ci.accessibility).foregroundStyle(.secondary)
          Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
          Spacer(minLength: 0)
        }
        .font(.callout)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open CI checks in browser")
      .accessibilityLabel("\(ci.accessibility), open checks in browser")
    } else {
      HStack(spacing: 5) {
        Image(systemName: ci.symbol).foregroundStyle(ci.semantic.color)
        Text(ci.accessibility).foregroundStyle(.secondary)
      }
      .font(.callout)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(ci.accessibility)
    }
  }

}

extension PRPresentation.Semantic {
  /// Semantic → SwiftUI color for the PR state badge. Mirrors GitHub: open green, merged purple,
  /// closed red, draft a quiet gray.
  var color: Color {
    switch self {
    case .open: return .green
    case .draft: return .secondary
    case .merged: return .purple
    case .closed: return .red
    }
  }
}

extension PRPresentation.ReviewSemantic {
  /// Semantic → SwiftUI color for a per-reviewer row glyph. Mirrors GitHub: approved green,
  /// changes-requested red, pending amber; commented/dismissed stay quiet (the glyph carries it).
  var color: Color {
    switch self {
    case .approved: return .green
    case .changesRequested: return .red
    case .requested: return .orange
    case .commented: return .secondary
    case .dismissed: return .secondary
    }
  }
}

extension PRPresentation.CheckSemantic {
  /// Semantic → SwiftUI color for a per-check row glyph. Mirrors GitHub: passing green, failing red,
  /// pending amber; skipped/cancelled stay quiet (the glyph carries it). Plain colors (like the
  /// reviewer rows), so the two row kinds read consistently.
  var color: Color {
    switch self {
    case .passing: return .green
    case .failing: return .red
    case .pending: return .orange
    case .skipped: return .secondary
    case .cancelled: return .secondary
    }
  }
}
