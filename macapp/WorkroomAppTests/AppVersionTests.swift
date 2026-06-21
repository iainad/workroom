import XCTest

@testable import Workroom

/// `SemanticVersion` is the comparison behind the "What's New" release filter. It must order plain
/// releases numerically AND order prereleases correctly (this repo ships betas), or a beta→stable
/// upgrade would show no dialog. Unparseable input must surface as nil, never crash.
final class AppVersionTests: XCTestCase {
  private func v(_ s: String) -> SemanticVersion {
    guard let parsed = SemanticVersion(s) else {
      XCTFail("expected \(s) to parse")
      return SemanticVersion("0.0.0")!
    }
    return parsed
  }

  func testNumericCoreOrdering() {
    XCTAssertLessThan(v("1.9.0"), v("1.10.0"))  // not lexical
    XCTAssertLessThan(v("1.2.3"), v("1.2.4"))
    XCTAssertLessThan(v("1.2.9"), v("2.0.0"))
    XCTAssertGreaterThan(v("2.0.0"), v("1.99.99"))
  }

  func testMissingComponentsNormaliseToZero() {
    XCTAssertEqual(v("1.2"), v("1.2.0"))
    XCTAssertEqual(v("1"), v("1.0.0"))
    XCTAssertLessThan(v("1.2"), v("1.2.1"))
  }

  func testLeadingVAndWhitespaceTolerated() {
    XCTAssertEqual(v("v1.2.3"), v("1.2.3"))
    XCTAssertEqual(v("  V2.0.0 "), v("2.0.0"))
  }

  func testPrereleaseSortsBelowRelease() {
    XCTAssertLessThan(v("2.0.0-beta.1"), v("2.0.0"))
    XCTAssertLessThan(v("1.0.0-rc.1"), v("1.0.0"))
    XCTAssertGreaterThan(v("2.0.0"), v("2.0.0-beta.9"))
  }

  func testPrereleaseIdentifierOrdering() {
    XCTAssertLessThan(v("2.0.0-beta.1"), v("2.0.0-beta.2"))
    XCTAssertLessThan(v("1.0.0-alpha"), v("1.0.0-beta"))
    // Numeric identifiers rank below alphanumeric ones (SemVer §11.4).
    XCTAssertLessThan(v("1.0.0-1"), v("1.0.0-alpha"))
    // Fewer identifiers sort before a longer superset when all shared fields tie.
    XCTAssertLessThan(v("1.0.0-alpha"), v("1.0.0-alpha.1"))
  }

  func testBuildMetadataIgnoredForOrdering() {
    XCTAssertEqual(v("1.0.0+build5"), v("1.0.0"))
    XCTAssertEqual(v("1.0.0-rc.1+a"), v("1.0.0-rc.1"))
  }

  func testUnparseableReturnsNil() {
    XCTAssertNil(SemanticVersion(""))
    XCTAssertNil(SemanticVersion("not-a-version"))
    XCTAssertNil(SemanticVersion("1.x.0"))
    XCTAssertNil(SemanticVersion("appcast"))
    XCTAssertNil(SemanticVersion("2.0.0-"))  // trailing dash, empty prerelease
  }

  func testEqualityIsSemantic() {
    XCTAssertEqual(v("1.2.0"), v("1.2"))
    XCTAssertNotEqual(v("1.2.0"), v("1.2.1"))
    XCTAssertNotEqual(v("2.0.0-beta.1"), v("2.0.0"))
  }
}
