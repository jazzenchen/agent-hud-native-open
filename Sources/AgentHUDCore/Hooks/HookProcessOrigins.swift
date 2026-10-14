import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Kernel-reported callback ancestry shared by local origin hooks; process environments are never decoded.
enum HookProcessOrigins {
    /// A kernel-reported ancestor, ordered from the callback's parent outwards. Bundle IDs are verified on disk.
    struct Ancestor: Equatable, Sendable {
        let executable: String
        let arguments: [String]
        var bundleIdentifier: String? = nil
    }

    static func ancestors() -> [Ancestor] {
        #if os(Windows)
        // Kernel-reported ancestry has no Windows equivalent here; the callback runs without one.
        return []
        #else
        var pid = getppid(), seen: Set<pid_t> = [], result: [Ancestor] = []
        while pid > 1, result.count < 16, seen.insert(pid).inserted {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { break }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0, let arguments = processArguments(pid) else { break }
            let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result.append(Ancestor(executable: executable, arguments: arguments, bundleIdentifier: bundleIdentifier(executable)))
            pid = pid_t(info.pbi_ppid)
        }
        return result
        #endif
    }

    #if !os(Windows)
    private static func bundleIdentifier(_ executable: String) -> String? {
        let file = URL(fileURLWithPath: executable), macOS = file.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", macOS.deletingLastPathComponent().lastPathComponent == "Contents" else { return nil }
        let app = macOS.deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app", let bundle = Bundle(url: app),
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == file.lastPathComponent else { return nil }
        return bundle.bundleIdentifier
    }

    private static func processArguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4, size <= 1024 * 1024 else { return nil }
        var data = Data(count: size)
        let status = data.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { return nil }
        data.count = size
        return processArguments(data)
    }

    /// KERN_PROCARGS2 puts the executable, argv, then environment in one buffer. Stop after argv; never decode environment.
    static func processArguments(_ data: Data) -> [String]? {
        guard data.count > MemoryLayout<Int32>.size else { return nil }
        let count = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= 4096 else { return nil }
        var index = MemoryLayout<Int32>.size
        guard let executableEnd = data[index...].firstIndex(of: 0) else { return nil }
        index = executableEnd
        while index < data.count, data[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            guard index < data.count, let end = data[index...].firstIndex(of: 0) else { return nil }
            arguments.append(String(decoding: data[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments
    }
    #endif
}
