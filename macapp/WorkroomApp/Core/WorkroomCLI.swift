import Foundation

/// Errors surfaced from running the bundled `workroom` binary.
enum WorkroomCLIError: LocalizedError {
    case binaryMissing
    case timedOut
    case decodeFailed(raw: String)
    /// A structured error from the CLI's --json contract.
    case cli(kind: String, message: String)
    /// Non-zero exit without a decodable JSON error envelope.
    case nonzero(code: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return "The bundled 'workroom' helper was not found in the app bundle."
        case .timedOut:
            return "The workroom command timed out."
        case .decodeFailed(let raw):
            return "Could not parse the workroom response: \(raw.prefix(200))"
        case .cli(_, let message):
            return message
        case .nonzero(let code, let stderr):
            return stderr.isEmpty ? "workroom exited with code \(code)." : stderr
        }
    }

    /// The stable machine `error.kind` when available (for UI branching).
    var kind: String? {
        if case .cli(let kind, _) = self { return kind }
        return nil
    }
}

private struct CLIResult {
    let stdout: Data
    let stderr: String
    let exitCode: Int32
}

/// Lock-guarded state shared across the drain/timeout/termination callbacks. A
/// reference type so the @Sendable closures capture an immutable `let` and mutate
/// through it, rather than capturing mutable vars (a data race under Swift 6).
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var _stdout = Data()
    private var _stderr = Data()
    private var _finished = false

    func setStdout(_ d: Data) { lock.lock(); _stdout = d; lock.unlock() }
    func setStderr(_ d: Data) { lock.lock(); _stderr = d; lock.unlock() }
    func markFinished() { lock.lock(); _finished = true; lock.unlock() }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return _finished }
    var stdout: Data { lock.lock(); defer { lock.unlock() }; return _stdout }
    var stderr: Data { lock.lock(); defer { lock.unlock() }; return _stderr }
}

/// Drives the bundled `workroom` binary over its `--json` contract. All work runs
/// off the main thread. Mutations are rare and one-shot; the binary itself forks to
/// git/jj, so the subprocess spawn is negligible.
final class WorkroomCLI {
    static let shared = WorkroomCLI()
    private init() {}

    // MARK: Public API

    func list(warnings: String = "fast", project: String? = nil) async throws -> ListResponse {
        var args = ["list", "--json", "--warnings=\(warnings)"]
        if let project { args += ["--project", project] }
        let result = try await run(args, timeout: warnings == "full" ? 15 : 5)
        return try decode(ListResponse.self, from: result)
    }

    func addProject(_ path: String) async throws {
        let result = try await run(["add-project", path, "--json"], timeout: 15)
        try throwIfError(result)
    }

    @discardableResult
    func create(project: String) async throws -> CreateResponse {
        let result = try await run(["create", "--json", "--no-editor", "--project", project], timeout: 600)
        return try decode(CreateResponse.self, from: result)
    }

    func delete(name: String, project: String) async throws {
        let result = try await run(["delete", name, "--json", "--project", project, "--confirm", name], timeout: 600)
        try throwIfError(result)
    }

    // MARK: Binary location

    private func binaryURL() throws -> URL {
        // Embedded in Contents/Resources (NOT Contents/MacOS — "workroom" would collide
        // with the "Workroom" app executable on the case-insensitive filesystem).
        if let url = Bundle.main.url(forResource: "workroom", withExtension: nil) {
            return url
        }
        // Dev fallback: a `workroom` next to the running executable.
        let exeDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let candidate = exeDir.appendingPathComponent("workroom")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw WorkroomCLIError.binaryMissing
    }

    // MARK: Decoding

    private func decode<T: Decodable>(_ type: T.Type, from result: CLIResult) throws -> T {
        try throwIfError(result)
        do {
            return try JSONDecoder().decode(type, from: result.stdout)
        } catch {
            throw WorkroomCLIError.decodeFailed(raw: String(data: result.stdout, encoding: .utf8) ?? "")
        }
    }

    /// Inspects the result and throws if it represents a failure. The CLI writes one
    /// JSON envelope to stdout for both success and error; a non-zero exit means error.
    private func throwIfError(_ result: CLIResult) throws {
        if result.exitCode == 0 { return }
        if let env = try? JSONDecoder().decode(Envelope.self, from: result.stdout),
           let body = env.error {
            throw WorkroomCLIError.cli(kind: body.kind, message: body.message)
        }
        throw WorkroomCLIError.nonzero(code: result.exitCode, stderr: result.stderr)
    }

    // MARK: Process execution

    /// Runs the helper with `args`, draining stdout and stderr concurrently (so a full
    /// pipe buffer can't deadlock) and enforcing a timeout. On timeout the process is
    /// terminated then killed.
    private func run(_ args: [String], timeout: TimeInterval) async throws -> CLIResult {
        let url = try binaryURL()
        return try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = url
            proc.arguments = args

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = ShellEnvironment.path()
            env["GIT_TERMINAL_PROMPT"] = "0"
            env["GIT_OPTIONAL_LOCKS"] = "0"
            proc.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            let state = RunState()
            let drain = DispatchGroup()
            drain.enter()
            DispatchQueue.global().async {
                state.setStdout(outPipe.fileHandleForReading.readDataToEndOfFile())
                drain.leave()
            }
            drain.enter()
            DispatchQueue.global().async {
                state.setStderr(errPipe.fileHandleForReading.readDataToEndOfFile())
                drain.leave()
            }

            let timeoutItem = DispatchWorkItem {
                guard !state.isFinished, proc.isRunning else { return }
                proc.terminate()
                // NOTE: full process-group kill (also reaping git/jj grandchildren)
                // would require launching via posix_spawn with setpgid; terminate() +
                // GIT_TERMINAL_PROMPT=0 is sufficient for the MVP.
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            proc.terminationHandler = { finishedProc in
                state.markFinished()
                timeoutItem.cancel()
                drain.wait()
                continuation.resume(returning: CLIResult(
                    stdout: state.stdout,
                    stderr: String(data: state.stderr, encoding: .utf8) ?? "",
                    exitCode: finishedProc.terminationStatus
                ))
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
