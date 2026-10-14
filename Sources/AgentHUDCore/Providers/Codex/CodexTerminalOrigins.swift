#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// A daemon thread's `codex_tui` MCP endpoint belongs to its terminal frontend, even when the daemon's own environment
/// came from another terminal. Match the endpoint to a live native Codex listener; never infer a session from its cwd.
public enum CodexTerminalOrigins {
    public static func read(threadIDs: Set<String>, dataDirectory: URL = CodexLocator.dataDirectory) async
        -> [String: SessionNavigationTarget] {
        #if os(Windows)
        // Matching an endpoint to a terminal reads iTerm2's environment out of the kernel; on Windows the endpoint is
        // left unnamed and the session stays where it is.
        return [:]
        #else
        guard !threadIDs.isEmpty else { return [:] }
        let endpoints = await CodexDaemonOriginTransport.tuiHTTPOrigins(threadIDs: threadIDs, dataDirectory: dataDirectory)
        let ports = endpoints.compactMapValues(port)
        guard !ports.isEmpty else { return [:] }
        let targets = await Task.detached(priority: .utility) { listenerTargets(ports: Set(ports.values)) }.value
        return ports.compactMapValues { targets[$0] }
        #endif
    }

    /// The native TUI binds IPv4 loopback and publishes only an HTTP origin. Other endpoints cannot identify a local PID.
    static func port(_ url: URL) -> UInt16? {
        guard url.scheme == "http", url.host == "127.0.0.1", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              let port = url.port, (1...65535).contains(port) else { return nil }
        return UInt16(port)
    }

    #if !os(Windows)
    struct ProcessIdentity: Equatable, Sendable {
        let pid: pid_t
        let uid: uid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let executable: String
    }

    static func target(process: ProcessIdentity, rechecked: ProcessIdentity?, arguments: [String],
                       environment: [String: String], uid: uid_t) -> SessionNavigationTarget? {
        guard process == rechecked, process.uid == uid, process.startSeconds > 0,
              URL(fileURLWithPath: process.executable).lastPathComponent == "codex",
              CodexSessionOrigins.invocation(arguments) == .cli,
              environment["TERM_PROGRAM"] == "iTerm.app", (environment["TMUX"] ?? "").isEmpty,
              let id = environment["ITERM_SESSION_ID"], !id.isEmpty else { return nil }
        return .iTermSession(id: id)
    }

    /// Skip executable and argv, then decode only the three terminal variables. Other environment values remain bytes.
    static func terminalEnvironment(_ data: Data) -> [String: String]? {
        guard data.count > MemoryLayout<Int32>.size else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 4096 else { return nil }
        var index = MemoryLayout<Int32>.size
        guard let executableEnd = data[index...].firstIndex(of: 0) else { return nil }
        index = executableEnd
        while index < data.count, data[index] == 0 { index += 1 }
        for _ in 0..<argc {
            guard index < data.count, let end = data[index...].firstIndex(of: 0) else { return nil }
            index = end + 1
        }
        let allowed = ["TERM_PROGRAM", "ITERM_SESSION_ID", "TMUX"].map { Array($0.utf8) }
        var result: [String: String] = [:]
        while index < data.count, let end = data[index...].firstIndex(of: 0), end > index {
            if let equal = data[index..<end].firstIndex(of: UInt8(ascii: "=")),
               let key = allowed.first(where: { data[index..<equal].elementsEqual($0) }) {
                result[String(decoding: key, as: UTF8.self)] = String(decoding: data[(equal + 1)..<end], as: UTF8.self)
            }
            index = end + 1
        }
        return result
    }

    private static func listenerTargets(ports: Set<UInt16>) -> [UInt16: SessionNavigationTarget] {
        let uid = getuid()
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard bytes > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.stride + 32)
        let filled = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [:] }
        var result: [UInt16: SessionNavigationTarget] = [:], ambiguous: Set<UInt16> = []
        for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.stride) where pid > 0 {
            guard let identity = processIdentity(pid), identity.uid == uid,
                  URL(fileURLWithPath: identity.executable).lastPathComponent == "codex" else { continue }
            let owned = listeningPorts(pid).intersection(ports)
            guard !owned.isEmpty, let data = argumentsData(pid),
                  let arguments = CodexSessionOrigins.processArguments(data), let environment = terminalEnvironment(data),
                  let target = target(process: identity, rechecked: processIdentity(pid), arguments: arguments,
                                      environment: environment, uid: uid) else { continue }
            for port in owned {
                if result[port] != nil { ambiguous.insert(port) }
                result[port] = target
            }
        }
        ambiguous.forEach { result.removeValue(forKey: $0) }
        return result
    }

    static func processIdentity(_ pid: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_start_tvsec > 0 else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return ProcessIdentity(pid: pid, uid: info.pbi_uid, startSeconds: info.pbi_start_tvsec,
                               startMicroseconds: info.pbi_start_tvusec, executable: executable)
    }

    private static func listeningPorts(_ pid: pid_t) -> Set<UInt16> {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0, bytes <= 1024 * 1024 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 16)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        var ports: Set<UInt16> = []
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_family == AF_INET, socket.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN,
                  tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr == inet_addr("127.0.0.1") else { continue }
            ports.insert(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
        }
        return ports
    }

    static func argumentsData(_ pid: pid_t) -> Data? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4, size <= 1024 * 1024 else { return nil }
        var data = Data(count: size)
        guard data.withUnsafeMutableBytes({ sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }) == 0 else { return nil }
        data.count = size
        return data
    }
    #endif
}
