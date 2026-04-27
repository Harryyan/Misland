import Foundation

/// Canonical filesystem paths for MioMini private state.
///
/// All paths live under `~/Library/Application Support/MioMini/`. The directory is
/// created (and re-asserted) with mode 0700 so other local users cannot list, read,
/// or place files inside it. This is the foundation of the local security model
/// (PRD §6 SEC-1).
public enum SecurityPaths {
    public static let directoryName = "MioMini"
    public static let socketFileName = "control.sock"
    public static let secretFileName = ".secret"

    /// Override hook for tests. Set to non-nil to redirect all paths into a sandbox.
    public static var overrideRoot: URL?

    public static var supportDirectory: URL {
        if let override = overrideRoot {
            return override
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static var socketPath: String {
        supportDirectory.appendingPathComponent(socketFileName).path
    }

    public static var secretKeyPath: String {
        supportDirectory.appendingPathComponent(secretFileName).path
    }

    /// Ensure the support directory exists with mode 0700. Idempotent.
    /// Throws if the path exists but is not a directory, or if mode cannot be set.
    @discardableResult
    public static func ensureSupportDirectory() throws -> URL {
        let url = supportDirectory
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw SecurityPathsError.notADirectory(url.path)
            }
        } else {
            try fm.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        // Always reassert mode 0700 — guards against a previous run leaving it open.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

public enum SecurityPathsError: Error, Equatable {
    case notADirectory(String)
}
