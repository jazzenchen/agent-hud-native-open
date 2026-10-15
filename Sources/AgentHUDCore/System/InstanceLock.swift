import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// The lock that lets only one Agent HUD run at a time.
///
/// The copy that runs points every client hook at itself and serves the sockets those hooks reach, so a second copy
/// would take them from under the first. Every application built on these libraries claims the same file, whatever
/// its data directory or bundle identifier, and holds it for as long as it keeps the lock: the system lets go of it
/// when the process ends, also when it crashes, so a copy that is gone never keeps another from starting. Hook
/// commands, probes and snapshots take no lock.
public final class InstanceLock: Sendable {
    public enum Claim: Sendable {
        /// This process holds the lock for as long as it keeps the value.
        case acquired(InstanceLock)
        /// Another process holds it: the application it runs, its bundle when it runs in one, if the lock names it.
        case held(by: URL?)
        /// No lock could be taken here; the application runs without one rather than not at all.
        case unavailable
    }

    /// `~/Library/Caches/app.agenthud/instance.lock` on macOS, under `%LOCALAPPDATA%` on Windows: outside every
    /// application's own data directory, so they all meet there.
    public static var sharedURL: URL {
        #if os(Windows)
        let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local", isDirectory: true)
        return local.appendingPathComponent("app.agenthud", isDirectory: true).appendingPathComponent("instance.lock")
        #else
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return caches.appendingPathComponent("app.agenthud", isDirectory: true).appendingPathComponent("instance.lock")
        #endif
    }

    #if os(Windows)
    private let file: LockedFile

    private init(file: LockedFile) { self.file = file }

    deinit {}

    /// Takes the lock at `url` and writes `executable` into it, so that a launch it turns away can say which copy runs.
    public static func claim(at url: URL = sharedURL, executable: URL? = Bundle.main.executableURL) -> Claim {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            NSLog("[AgentHUD] No instance lock at %@: %@", url.path, error.localizedDescription)
            return .unavailable
        }
        guard let file = LockedFile(url.path) else {
            NSLog("[AgentHUD] No instance lock at %@", url.path)
            return .unavailable
        }
        guard file.isLocked else { return .held(by: holder(at: url)) }
        if !file.write(Data((executable?.path ?? "").utf8)) {
            NSLog("[AgentHUD] Could not name this copy in the instance lock at %@", url.path)
        }
        return .acquired(InstanceLock(file: file))
    }

    /// The application whose executable the holder wrote. Nil while the holder has not written it yet.
    static func holder(at url: URL) -> URL? {
        guard let data = try? Data(contentsOf: url), data.count <= 4096 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("\\\\") || (path.count > 2 && path[path.index(after: path.startIndex)] == ":") else { return nil }
        return URL(fileURLWithPath: path)
    }
    #else
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { close(descriptor) }

    /// Takes the lock at `url` and writes `executable` into it, so that a launch it turns away can say which copy runs.
    public static func claim(at url: URL = sharedURL, executable: URL? = Bundle.main.executableURL) -> Claim {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            NSLog("[AgentHUD] No instance lock at %@: %@", url.path, error.localizedDescription)
            return .unavailable
        }
        // Closed on exec: a client's engine this app starts must not inherit the lock and hold it after the app is gone.
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            NSLog("[AgentHUD] No instance lock at %@: %@", url.path, String(cString: strerror(errno)))
            return .unavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            if failure == EWOULDBLOCK { return .held(by: holder(at: url)) }
            NSLog("[AgentHUD] No instance lock at %@: %@", url.path, String(cString: strerror(failure)))
            return .unavailable
        }
        let path = Array((executable?.path ?? "").utf8)
        let written = ftruncate(descriptor, 0) == 0
            && path.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) } == path.count
        if !written { NSLog("[AgentHUD] Could not name this copy in the instance lock: %@", String(cString: strerror(errno))) }
        return .acquired(InstanceLock(descriptor: descriptor))
    }

    /// The application whose executable the holder wrote: `…/Name.app` for one that runs in a bundle. Nil while the
    /// holder has not written it yet.
    static func holder(at url: URL) -> URL? {
        guard let data = try? Data(contentsOf: url), data.count <= 4096 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return nil }
        let executable = URL(fileURLWithPath: path)
        let folder = executable.deletingLastPathComponent()
        let bundle = folder.deletingLastPathComponent().deletingLastPathComponent()
        let inBundle = folder.lastPathComponent == "MacOS" && folder.deletingLastPathComponent().lastPathComponent == "Contents"
            && bundle.pathExtension == "app"
        return inBundle ? bundle : executable
    }
    #endif
}
