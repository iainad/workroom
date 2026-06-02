import Foundation

// Mirrors the `workroom --json` public API (schema_version 1). Decoders are lenient:
// unknown fields are ignored so a newer bundled/standalone CLI won't break the app.

struct Warning: Codable, Hashable {
    let kind: String
    let message: String
    let path: String?
    let vcs: String?
}

struct Workroom: Codable, Identifiable, Hashable {
    let name: String
    let path: String
    let vcsName: String
    let warnings: [Warning]

    var id: String { name }
    var hasBlockingWarning: Bool { warnings.contains { $0.kind == "DirectoryMissing" } }

    enum CodingKeys: String, CodingKey {
        case name, path, warnings
        case vcsName = "vcs_name"
    }
}

struct Project: Codable, Identifiable, Hashable {
    let path: String
    let vcs: String
    let workrooms: [Workroom]

    var id: String { path }
    var displayName: String { (path as NSString).lastPathComponent }
}

// MARK: - Envelopes

/// Common envelope header present on every response; used to detect error responses
/// before decoding a command-specific payload.
struct Envelope: Codable {
    let ok: Bool
    let schemaVersion: Int?
    let error: CLIErrorBody?

    enum CodingKeys: String, CodingKey {
        case ok, error
        case schemaVersion = "schema_version"
    }
}

struct CLIErrorBody: Codable {
    let kind: String
    let message: String
}

struct ListResponse: Codable {
    let projects: [Project]
    let workroomsDir: String?
    let configPath: String?

    enum CodingKeys: String, CodingKey {
        case projects
        case workroomsDir = "workrooms_dir"
        case configPath = "config_path"
    }
}

struct CreateResponse: Codable {
    let name: String
    let path: String
    let vcs: String
    let project: String
}
