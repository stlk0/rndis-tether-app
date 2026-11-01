import Foundation

/// What the admin socket can change; the raw value is its name in `set <name> yes|no`.
enum AdminSetting: String {
    case paused
    case preferPhone = "prefer-phone"
}

/// The service's two UNIX sockets. Call from the app's socket queue: an admin request can
/// wait up to 2 s behind another client.
enum SocketClient {
    /// A silent service holds each status read this many seconds.
    static let statusTimeout = 2
    private static let maxStatusBytes = 4096
    private static let maxReplyBytes = 512

    /// A socket connected to the service at `path`, or -1 with errno set. `timeout` is in seconds.
    /// Anything but root on the other end is refused with ECONNREFUSED: group daemon can write
    /// to /var/run.
    private static func connectToService(at path: String, timeout: Int) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        func fail(_ error: Int32) -> Int32 {
            close(fd)
            errno = error
            return -1
        }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { dst in
            let src = Array(path.utf8.prefix(dst.count - 1))
            dst.copyBytes(from: src)
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { return fail(errno) }
        var uid = uid_t.max
        var gid = gid_t.max
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { return fail(ECONNREFUSED) }
        return fd
    }

    enum StatusReply {
        case text(String)
        case noService
        /// Connected, but nothing came in time: the service is busy, say tearing down a
        /// connection on its main queue.
        case silent
    }

    /// The status text, cut at `maxStatusBytes`. Otherwise only a reply the service ended
    /// counts: a timeout or an error, even after part of it, is `.silent`.
    static func readStatus(timeout: Int = statusTimeout) -> StatusReply {
        let fd = connectToService(at: Paths.statusSocket, timeout: timeout)
        guard fd >= 0 else { return .noService }
        defer { close(fd) }
        var data = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count < maxStatusBytes {
            let n = read(fd, &buffer, min(buffer.count, maxStatusBytes - data.count))
            if n < 0 && errno == EINTR { continue }
            if n < 0 { return .silent }
            if n == 0 { break }
            data += buffer[0..<n]
        }
        return data.isEmpty ? .silent : .text(String(decoding: data, as: UTF8.self))
    }

    /// This user may open the admin socket (group admin); the service checks the caller too.
    static var canUseAdminSocket: Bool { access(Paths.adminSocket, R_OK | W_OK) == 0 }

    private static let noAnswer = "The rndis-tether service does not answer."

    /// Sends `set <name> yes|no`; nil on `ok`, otherwise text for an alert.
    static func set(_ setting: AdminSetting, to on: Bool, timeout: Int = 5) -> String? {
        let fd = connectToService(at: Paths.adminSocket, timeout: timeout)
        guard fd >= 0 else {
            return errno == EACCES ? "Only administrators of this Mac can change this setting." : noAnswer
        }
        defer { close(fd) }
        let request = Array("set \(setting.rawValue) \(on ? "yes" : "no")\n".utf8)
        guard write(fd, request, request.count) == request.count else { return noAnswer }
        // One line; without its newline the reply is cut off, so it is no answer.
        var reply = [UInt8]()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n < 0 && errno == EINTR { continue }
            guard n == 1, reply.count < maxReplyBytes else { return noAnswer }
            if byte == UInt8(ascii: "\n") { break }
            reply.append(byte)
        }
        let text = String(decoding: reply, as: UTF8.self)
        let errorPrefix = "error: "
        if text == "ok" { return nil }
        if text.hasPrefix(errorPrefix) { return String(text.dropFirst(errorPrefix.count)) }
        return text.isEmpty ? noAnswer : text
    }
}
