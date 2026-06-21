import XCTest

@testable import Workroom

/// Decoding the subset of the GitHub releases API the dialog relies on, against a representative
/// fixture (snake_case keys, ISO-8601 dates, an unnamed/null-body release, a draft, a prerelease).
final class GitHubReleaseDecodeTests: XCTestCase {
  private let json = """
    [
      {
        "tag_name": "v2.0.0",
        "name": "Workroom 2.0.0",
        "body": "## Highlights\\n- New thing",
        "draft": false,
        "prerelease": false,
        "published_at": "2024-06-17T12:34:56Z",
        "html_url": "https://github.com/joelmoss/workroom/releases/tag/v2.0.0"
      },
      {
        "tag_name": "v2.0.0-beta.1",
        "name": null,
        "body": null,
        "draft": false,
        "prerelease": true,
        "published_at": "2024-06-01T00:00:00Z",
        "html_url": "https://github.com/joelmoss/workroom/releases/tag/v2.0.0-beta.1"
      },
      {
        "tag_name": "v2.1.0-draft",
        "name": "WIP",
        "body": "unfinished",
        "draft": true,
        "prerelease": false,
        "published_at": null,
        "html_url": "https://github.com/joelmoss/workroom/releases/tag/v2.1.0-draft"
      }
    ]
    """

  func testDecodesAllFields() throws {
    let releases = try GitHubReleasesClient.decoder.decode(
      [GitHubRelease].self, from: Data(json.utf8))
    XCTAssertEqual(releases.count, 3)

    let stable = releases[0]
    XCTAssertEqual(stable.tagName, "v2.0.0")
    XCTAssertEqual(stable.name, "Workroom 2.0.0")
    XCTAssertEqual(stable.body, "## Highlights\n- New thing")
    XCTAssertFalse(stable.draft)
    XCTAssertFalse(stable.prerelease)
    XCTAssertEqual(stable.htmlURL?.lastPathComponent, "v2.0.0")
    XCTAssertNotNil(stable.publishedAt)

    let beta = releases[1]
    XCTAssertNil(beta.name)
    XCTAssertNil(beta.body)
    XCTAssertTrue(beta.prerelease)

    let draft = releases[2]
    XCTAssertTrue(draft.draft)
    XCTAssertNil(draft.publishedAt)
  }
}
