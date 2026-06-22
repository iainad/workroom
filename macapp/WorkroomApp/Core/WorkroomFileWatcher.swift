import Foundation

/// Watches a single directory tree for filesystem changes via FSEvents and invokes `onChange` on the
/// main actor with the changed paths. Used to keep the *selected* workroom's VCS status + Changes
/// detail live while you edit in its terminal — event-driven, no polling (issue #24 follow-up).
///
/// The stream's `latency` is the debounce: FSEvents coalesces a burst of writes (a save, a `git`
/// command, a build) into one callback per window, so a noisy directory doesn't fork a probe per
/// file. One watch at a time — `start(path:)` replaces any prior watch; `stop()` tears it down.
/// `onChange` receives the coalesced changed paths (CFTypes), so the caller can ignore VCS-internal
/// churn (e.g. a jj snapshot writing under `.jj/`, which would otherwise self-trigger).
final class WorkroomFileWatcher {
  private var stream: FSEventStreamRef?
  private var watchedPath: String?
  private let queue = DispatchQueue(label: "com.developwithstyle.workroom.fswatch")
  private let latency: TimeInterval
  private let onChange: @MainActor ([String]) -> Void

  init(latency: TimeInterval = 1.0, onChange: @escaping @MainActor ([String]) -> Void) {
    self.latency = latency
    self.onChange = onChange
  }

  deinit { stop() }

  /// Begin watching `path` (recursively). No-op if already watching the same path; otherwise replaces
  /// the prior watch.
  func start(path: String) {
    if watchedPath == path, stream != nil { return }
    stop()
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil, release: nil, copyDescription: nil)
    // UseCFTypes → `eventPaths` arrives as a CFArray of CFString (clean `[String]` bridge).
    // NoDefer → the first event after an idle period fires at the *start* of the latency window, so
    // the panel reacts promptly rather than waiting a full `latency` after you start typing.
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
    let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<WorkroomFileWatcher>.fromOpaque(info).takeUnretainedValue()
      let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
      _ = count
      Task { @MainActor in watcher.onChange(paths) }
    }
    guard
      let stream = FSEventStreamCreate(
        kCFAllocatorDefault, callback, &context, [path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
    else { return }
    self.stream = stream
    self.watchedPath = path
    FSEventStreamSetDispatchQueue(stream, queue)
    FSEventStreamStart(stream)
  }

  func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
    self.watchedPath = nil
  }
}
