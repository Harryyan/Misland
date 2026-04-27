import Foundation
import Darwin

/// Thin synchronous POSIX wrappers around AF_UNIX SOCK_STREAM.
///
/// Why raw POSIX rather than Network.framework? Two reasons:
/// 1. The bridge is a short-lived CLI that needs a synchronous request/response.
///    Network.framework's NWConnection is async-callback-driven and adds dispatch
///    latency where we need none.
/// 2. Every byte of the security boundary lives in this file. Auditing is easier
///    when it is a few hundred lines of straight POSIX rather than a state machine
///    spread across NWConnection callbacks.
public enum UnixSocket {

    // MARK: - Public API

    /// Connect to a server at `path`. Returns the open socket file descriptor.
    /// Caller is responsible for `close()`.
    public static func connectClient(
        path: String,
        sendTimeout: TimeInterval = 5,
        recvTimeout: TimeInterval = 300
    ) throws -> Int32 {
        let fd = try makeSocket()
        do {
            try applyTimeouts(fd: fd, send: sendTimeout, recv: recvTimeout)
            try connect(fd: fd, path: path)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    /// Bind a listening server at `path`, mode 0600. Returns the listening fd.
    /// Removes a stale socket file at `path` if present.
    public static func bindServer(path: String, backlog: Int32 = 8) throws -> Int32 {
        // Remove a stale socket file (typical after a crash).
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            try? fm.removeItem(atPath: path)
        }
        let fd = try makeSocket()
        do {
            // umask 0177 → newly created files are 0600.
            let oldMask = umask(0o177)
            defer { umask(oldMask) }
            try bind(fd: fd, path: path)
            // Re-assert mode 0600 explicitly. On some macOS configurations bind()
            // appears to ignore the umask for the socket inode; this is belt + braces.
            chmod(path, 0o600)
            guard listen(fd, backlog) == 0 else {
                throw UnixSocketError.listenFailed(errno: errno)
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    /// Accept one incoming connection. Blocks until a client connects or `listenFD` is closed.
    /// Returns the connected socket fd (caller closes), or nil if the listener was shut down.
    public static func accept(listenFD: Int32) -> Int32? {
        var addr = sockaddr_un()
        var len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let fd = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.accept(listenFD, sa, &len)
            }
        }
        return fd >= 0 ? fd : nil
    }

    /// Returns the effective UID of the connected peer.
    /// Used for defense-in-depth: refuse connections from other local users
    /// even if support-dir mode 0700 was somehow loosened.
    public static func peerUID(fd: Int32) -> uid_t? {
        var euid: uid_t = 0
        var egid: gid_t = 0
        return getpeereid(fd, &euid, &egid) == 0 ? euid : nil
    }

    /// Write all bytes, retrying on EINTR. Throws on partial-write failure.
    public static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var remaining = buf.count
            var ptr = buf.baseAddress!
            while remaining > 0 {
                let n = Darwin.write(fd, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw UnixSocketError.writeFailed(errno: errno)
                }
                if n == 0 { throw UnixSocketError.eof }
                remaining -= n
                ptr = ptr.advanced(by: n)
            }
        }
    }

    /// Read until newline (0x0a). The terminator is consumed but not returned.
    /// Hard caps at `maxBytes`; this protects the server from a malicious client
    /// streaming gigabytes hoping to OOM us.
    public static func readLine(fd: Int32, maxBytes: Int = 1 * 1024 * 1024) throws -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &byte, 1)
            if n < 0 {
                if errno == EINTR { continue }
                throw UnixSocketError.readFailed(errno: errno)
            }
            if n == 0 { throw UnixSocketError.eof }
            if byte == 0x0a { return data }
            data.append(byte)
            if data.count > maxBytes { throw UnixSocketError.lineTooLong(maxBytes: maxBytes) }
        }
    }

    // MARK: - Internals

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.socketFailed(errno: errno) }
        return fd
    }

    private static func applyTimeouts(fd: Int32, send: TimeInterval, recv: TimeInterval) throws {
        var snd = timeval(tv_sec: Int(send), tv_usec: 0)
        if setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &snd, socklen_t(MemoryLayout<timeval>.size)) != 0 {
            throw UnixSocketError.setsockoptFailed(errno: errno)
        }
        var rcv = timeval(tv_sec: Int(recv), tv_usec: 0)
        if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcv, socklen_t(MemoryLayout<timeval>.size)) != 0 {
            throw UnixSocketError.setsockoptFailed(errno: errno)
        }
    }

    private static func connect(fd: Int32, path: String) throws {
        var addr = try makeSockaddrUn(path: path)
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            throw UnixSocketError.connectFailed(errno: errno)
        }
    }

    private static func bind(fd: Int32, path: String) throws {
        var addr = try makeSockaddrUn(path: path)
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            throw UnixSocketError.bindFailed(errno: errno)
        }
    }

    private static func makeSockaddrUn(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            throw UnixSocketError.pathTooLong(length: pathBytes.count, max: capacity - 1)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for i in 0..<pathBytes.count { dst[i] = CChar(bitPattern: pathBytes[i]) }
                dst[pathBytes.count] = 0
            }
        }
        return addr
    }
}

public enum UnixSocketError: Error, Equatable {
    case socketFailed(errno: Int32)
    case connectFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case setsockoptFailed(errno: Int32)
    case pathTooLong(length: Int, max: Int)
    case eof
    case lineTooLong(maxBytes: Int)
}
