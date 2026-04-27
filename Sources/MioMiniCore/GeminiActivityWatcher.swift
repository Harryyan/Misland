import Foundation
import CoreServices

/// Read-only watcher for Gemini CLI activity (PRD §3 decision: Gemini is
/// read-only in v1 — we don't intercept permissions, just reflect activity).
///
/// Strategy
/// --------
/// FSEventStream watches Gemini's data directories. Any file event in those
/// paths counts as "Gemini is doing something":
/// - First event after idle  → ingest `status: processing`
/// - `idleAfter` seconds with no further events → ingest `status: waiting_for_input`
/// - We only emit on *transitions* to avoid hammering SessionStore.
///
/// Path discovery
/// --------------
/// Different Gemini CLI builds put data in different places. We scan a
/// candidate list (CWD-aware) and watch any that exist:
/// - `~/.gemini`
/// - `~/.config/gemini`
/// - `~/.config/google/gemini`
/// Override via env var `MIOMINI_GEMINI_DIR=/explicit/path`.
public final class GeminiActivityWatcher: @unchecked Sendable {
    public typealias Ingest = (_ payload: [String: Any], _ nonce: String) -> Void

    public let watchPaths: [String]
    public let activityWindow: TimeInterval
    public let idleAfter: TimeInterval
    public let fsEventLatency: CFTimeInterval

    private let queue: DispatchQueue
    private let ingest: Ingest

    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var idleTimer: DispatchSourceTimer?
    private var lastEmittedStatus: String?
    private(set) public var isStarted: Bool = false

    public init(
        watchPaths: [String]? = nil,
        activityWindow: TimeInterval = 5,
        idleAfter: TimeInterval = 10,
        fsEventLatency: CFTimeInterval = 1.0,
        queue: DispatchQueue = DispatchQueue(label: "chat.mio.miomini.gemini"),
        ingest: @escaping Ingest
    ) {
        self.watchPaths = watchPaths ?? GeminiActivityWatcher.defaultPaths()
        self.activityWindow = activityWindow
        self.idleAfter = idleAfter
        self.fsEventLatency = fsEventLatency
        self.queue = queue
        self.ingest = ingest
    }

    deinit { stop() }

    public static func defaultPaths() -> [String] {
        if let override = ProcessInfo.processInfo.environment["MIOMINI_GEMINI_DIR"], !override.isEmpty {
            return [override]
        }
        let home = NSHomeDirectory()
        return [
            "\(home)/.gemini",
            "\(home)/.config/gemini",
            "\(home)/.config/google/gemini",
        ]
    }

    /// The subset of `watchPaths` that exist on disk right now.
    public var existingPaths: [String] {
        watchPaths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    public func start() {
        let paths = existingPaths
        guard !paths.isEmpty else {
            // No Gemini directories present — nothing to watch. Fail silently
            // (harmless: user simply doesn't run Gemini, or their layout is
            // different and they need to set MIOMINI_GEMINI_DIR).
            return
        }

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            GeminiActivityWatcher.fsEventCallback,
            &ctx,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            fsEventLatency,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)

        lock.lock()
        self.stream = stream
        self.isStarted = true
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let s = stream
        stream = nil
        let t = idleTimer
        idleTimer = nil
        lastEmittedStatus = nil
        isStarted = false
        lock.unlock()
        if let s {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        t?.cancel()
    }

    /// Test/diagnostic hook: synthesize an activity event without waiting on
    /// the kernel to deliver one.
    public func _injectActivityForTest() {
        handleActivity()
    }

    // MARK: - Internals

    private static let fsEventCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<GeminiActivityWatcher>.fromOpaque(info).takeUnretainedValue()
        watcher.handleActivity()
    }

    private func handleActivity() {
        var emitProcessing = false
        lock.lock()
        if lastEmittedStatus != "processing" {
            emitProcessing = true
            lastEmittedStatus = "processing"
        }
        // Reset idle countdown.
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + idleAfter, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.emitIdle()
        }
        idleTimer = timer
        lock.unlock()
        timer.resume()

        if emitProcessing {
            emit(status: "processing")
        }
    }

    private func emitIdle() {
        var shouldEmit = false
        lock.lock()
        if lastEmittedStatus != "waiting_for_input" {
            shouldEmit = true
            lastEmittedStatus = "waiting_for_input"
        }
        idleTimer = nil
        lock.unlock()
        if shouldEmit {
            emit(status: "waiting_for_input")
        }
    }

    private func emit(status: String) {
        let payload: [String: Any] = [
            "status": status,
            "source": "gemini_cli",
            "tool": "gemini",
            "session_id": "gemini-active",
        ]
        ingest(payload, SocketEnvelope.randomNonce())
    }
}
