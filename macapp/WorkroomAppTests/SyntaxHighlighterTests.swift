import XCTest

@testable import Workroom

/// Lane-A spike coverage + the highlighter's core contract: real tree-sitter parse → highlights
/// query → resolved spans, for a no-scanner grammar (JSON) and an **external-scanner** grammar
/// (Bash, whose `scanner.c` proves the grammar packaging links + runs). Also covers the
/// `SyntaxLanguage.detect` registry. Pure logic — no repo, no temp files needed (the content is
/// inline source strings).
final class SyntaxHighlighterTests: XCTestCase {

  // MARK: - Real parse + query (proves SPM grammar + query-bundle wiring)

  func testJSONProducesHighlightSpans() {
    let json = """
      {
        "name": "workroom",
        "count": 42,
        "ok": true
      }
      """
    let spans = SyntaxHighlighter.shared.spans(for: json, grammar: .json)
    XCTAssertFalse(spans.isEmpty, "JSON should produce highlight spans from its highlights.scm")
    // A string key should be captured (string/property capture names vary by grammar; assert the
    // span exists over the `"name"` key bytes rather than the exact capture name).
    XCTAssertTrue(
      spans.contains { $0.capture.contains("string") || $0.capture.contains("property") },
      "expected a string/property capture; got \(Set(spans.map(\.capture)))")
  }

  /// Bash carries an external scanner (`src/scanner.c`). A non-empty parse proves the scanner
  /// compiled, linked, and runs — the lane-A packaging de-risk.
  func testBashExternalScannerParses() {
    let script = """
      #!/usr/bin/env bash
      set -euo pipefail
      greeting="hello"
      echo "$greeting world"
      """
    let spans = SyntaxHighlighter.shared.spans(for: script, grammar: .bash)
    XCTAssertFalse(
      spans.isEmpty, "Bash (external-scanner grammar) should parse and produce highlight spans")
  }

  /// Spans are ascending and non-overlapping (the resolver's contract — the byte→AttributedString
  /// mapping depends on it).
  func testSpansAreAscendingAndNonOverlapping() {
    let spans = SyntaxHighlighter.shared.spans(
      for: "{ \"a\": 1, \"b\": [true, null] }", grammar: .json)
    XCTAssertFalse(spans.isEmpty)
    for (prev, next) in zip(spans, spans.dropFirst()) {
      XCTAssertLessThanOrEqual(
        prev.byteRange.upperBound, next.byteRange.lowerBound, "spans overlap")
    }
  }

  func testEmptyContentProducesNoSpans() {
    XCTAssertTrue(SyntaxHighlighter.shared.spans(for: "", grammar: .json).isEmpty)
  }

  /// The grammar+query "CI check": every bundled grammar must load its parser, link its external
  /// scanner, find its `highlights.scm`, and produce spans for a representative snippet. A miss here
  /// (mis-named query bundle, missing scanner symbol, absent highlights.scm) means that language
  /// silently renders plain — caught loudly instead.
  func testEveryGrammarLoadsAndHighlights() {
    let snippets: [GrammarID: String] = [
      .swift: "let answer = 42\n",
      .go: "package main\nfunc main() {}\n",
      .ruby: "def foo\n  1\nend\n",
      .javascript: "const x = 1\n",
      .typescript: "const x: number = 1\n",
      .tsx: "const e = <div className=\"a\">hi</div>\n",
      .python: "def foo():\n    return 1\n",
      .json: "{ \"a\": 1 }\n",
      .yaml: "name: workroom\nport: 42\n",
      .toml: "name = \"workroom\"\nport = 42\n",
      .markdown: "# Title\n\nSome **text**.\n",
      .bash: "set -e\necho hi\n",
      .html: "<div class=\"a\">hi</div>\n",
      .css: "a { color: red; }\n",
      .sql: "SELECT id FROM users;\n",
    ]
    // Every case must have a snippet (guards against forgetting one when a grammar is added).
    XCTAssertEqual(Set(snippets.keys), Set(GrammarID.allCases))
    for grammar in GrammarID.allCases {
      let spans = SyntaxHighlighter.shared.spans(for: snippets[grammar]!, grammar: grammar)
      XCTAssertFalse(
        spans.isEmpty,
        "grammar \(grammar.rawValue) produced no spans — query bundle \(grammar.queryBundleName) "
          + "or parser/scanner likely not wired")
    }
  }

  // MARK: - Captures cache key

  func testCacheKeyVariesByContentAndGrammarAndIsStable() {
    let a = SyntaxHighlighter.cacheKey(grammar: .json, content: "{\"a\":1}")
    let b = SyntaxHighlighter.cacheKey(grammar: .json, content: "{\"b\":2}")
    let c = SyntaxHighlighter.cacheKey(grammar: .bash, content: "{\"a\":1}")
    XCTAssertNotEqual(a, b, "different content ⇒ different key")
    XCTAssertNotEqual(
      a, c, "different grammar ⇒ different key (captures must not leak across langs)")
    XCTAssertEqual(a, SyntaxHighlighter.cacheKey(grammar: .json, content: "{\"a\":1}"), "stable")
  }

  func testRepeatedHighlightIsDeterministic() {
    // Same input twice (second served from the captures cache) must return identical spans.
    let json = "{ \"name\": \"workroom\", \"n\": 1 }"
    let first = SyntaxHighlighter.shared.spans(for: json, grammar: .json)
    let second = SyntaxHighlighter.shared.spans(for: json, grammar: .json)
    XCTAssertEqual(first, second)
  }

  // MARK: - Registry (SyntaxLanguage.detect)

  func testDetectByExtension() {
    XCTAssertEqual(
      SyntaxLanguage.detect(newPath: "config/app.json", oldPath: nil, byteCount: 10), .json)
    XCTAssertEqual(
      SyntaxLanguage.detect(newPath: "scripts/run.sh", oldPath: nil, byteCount: 10), .bash)
  }

  func testDetectByFilename() {
    XCTAssertEqual(
      SyntaxLanguage.detect(newPath: "home/.bashrc", oldPath: nil, byteCount: 10), .bash)
  }

  func testDetectUnknownIsNil() {
    XCTAssertNil(SyntaxLanguage.detect(newPath: "main.rs", oldPath: nil, byteCount: 10))
  }

  func testSkipListWinsOverExtension() {
    // package-lock.json would match the json extension, but the skip-list must win → plain.
    XCTAssertNil(SyntaxLanguage.detect(newPath: "package-lock.json", oldPath: nil, byteCount: 10))
  }

  func testSkipMinifiedDoubleExtension() {
    XCTAssertNil(SyntaxLanguage.detect(newPath: "dist/app.min.js", oldPath: nil, byteCount: 10))
  }

  func testByteCapRejectsLargeFiles() {
    XCTAssertNil(
      SyntaxLanguage.detect(
        newPath: "big.json", oldPath: nil, byteCount: SyntaxLanguage.byteCap + 1),
      "files over the byte cap must render plain")
    XCTAssertEqual(
      SyntaxLanguage.detect(newPath: "big.json", oldPath: nil, byteCount: SyntaxLanguage.byteCap),
      .json, "files at exactly the cap are still parsed")
  }

  func testDetectFallsBackToOldPath() {
    // A rename across extensions: new side unknown, old side is JSON → highlight off the old path.
    XCTAssertEqual(
      SyntaxLanguage.detect(newPath: "data.unknownext", oldPath: "data.json", byteCount: 10), .json)
  }

  // MARK: - Shebang detection (extension-less scripts)

  func testShebangDirectInterpreter() {
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/bin/bash"), .bash)
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/bin/sh"), .bash)
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/zsh"), .bash)
  }

  func testShebangViaEnvAndVersionSuffix() {
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/env bash"), .bash)
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/env python3"), .python)
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/python3.11"), .python)
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/env ruby"), .ruby)
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/env node"), .javascript)
  }

  func testShebangEnvSkipsFlags() {
    // `env -S python3 -u` → the interpreter is python3, not the `-S` flag.
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/env -S python3 -u"), .python)
  }

  func testShebangEnvWithNoInterpreterIsNil() {
    // `env` with nothing (or only flags) after it names no interpreter → no language.
    XCTAssertNil(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/env"))
    XCTAssertNil(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/env -S"))
  }

  func testShebangToleratesTrailingCR() {
    // A CRLF first line leaves a trailing `\r` on the interpreter token — must still match.
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/bin/bash\r"), .bash)
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/env python3\r"), .python)
  }

  func testShebangNonShebangOrUnknownIsNil() {
    XCTAssertNil(SyntaxLanguage.grammar(forShebang: "not a shebang"))
    XCTAssertNil(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/env perl"))
    XCTAssertNil(SyntaxLanguage.grammar(forShebang: "#!"))
  }

  func testGrammarForPathPrefersExtensionThenShebang() {
    // A `.sh` extension wins without needing the shebang.
    XCTAssertEqual(SyntaxLanguage.grammar(forPath: "run.sh", firstLine: nil), .bash)
    // No extension, but a bash shebang → bash.
    XCTAssertEqual(
      SyntaxLanguage.grammar(forPath: "scripts/deploy", firstLine: "#!/usr/bin/env bash"), .bash)
    // No extension, no shebang → plain.
    XCTAssertNil(SyntaxLanguage.grammar(forPath: "scripts/deploy", firstLine: "echo hi"))
  }
}
