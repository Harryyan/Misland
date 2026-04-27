import Foundation

/// Composition root. The future SwiftUI app instantiates this exactly once at
/// launch and shares it across menu bar, notch, and settings views.
///
/// ```
///                 ┌───────────────────────────────────┐
///                 │  MioMiniRuntime                   │
///                 │   ├─ HMACKey            (loadOrCreate) │
///                 │   ├─ SessionStore                 │
///                 │   ├─ HookSocketServer             │
///                 │   ├─ PermissionTimeoutCoordinator │
///                 │   └─ HookInstallerService         │
///                 └───────────────────────────────────┘
/// ```
///
/// The runtime owns lifecycle. UI subscribes to `store.observe(...)` for state
/// updates and calls `respond(...)` to act on user clicks.
public final class MioMiniRuntime {
    public let key: HMACKey
    public let store: SessionStore
    public let server: HookSocketServer
    public let timeoutCoordinator: PermissionTimeoutCoordinator
    public let installer: HookInstallerService
    public let geminiWatcher: GeminiActivityWatcher

    public private(set) var isRunning: Bool = false

    public init(
        permissionTimeout: TimeInterval = 30,
        socketPath: String? = nil,
        settingsPath: String? = nil,
        geminiWatchPaths: [String]? = nil
    ) throws {
        self.key = try HMACKey.loadOrCreate()
        self.store = SessionStore()
        self.server = HookSocketServer(
            key: key,
            sessionStore: store,
            socketPath: socketPath
        )
        let server = self.server
        self.timeoutCoordinator = PermissionTimeoutCoordinator(
            timeout: permissionTimeout,
            store: store,
            respond: { [weak server] nonce, decision, reason in
                _ = try? server?.respond(toNonce: nonce, decision: decision, reason: reason)
            }
        )
        self.installer = HookInstallerService(settingsPath: settingsPath)
        let store = self.store
        self.geminiWatcher = GeminiActivityWatcher(
            watchPaths: geminiWatchPaths,
            ingest: { payload, nonce in
                store.ingest(payload: payload, envelopeNonce: nonce)
            }
        )
    }

    public func start() throws {
        guard !isRunning else { return }
        try server.start()
        timeoutCoordinator.start()
        geminiWatcher.start()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        timeoutCoordinator.stop()
        geminiWatcher.stop()
        server.stop()
        isRunning = false
    }

    /// User clicked Allow / Deny in the UI.
    @discardableResult
    public func decide(nonce: String, decision: PermissionDecision, reason: String? = nil) throws -> Bool {
        try server.respond(toNonce: nonce, decision: decision, reason: reason)
    }

    /// Returns the disk path the bridge binary should be installed at when we
    /// run from a `Mio Mini.app` bundle. Used by `HookInstallerService.install(...)`.
    public static func bridgePathForAppBundle(at bundleURL: URL) -> String {
        bundleURL.appendingPathComponent("Contents/MacOS/miomini-hook").path
    }
}
