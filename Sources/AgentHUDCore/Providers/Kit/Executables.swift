import Foundation

/// How a client's executable is found: at the places its installers use first, since an application started from
/// Finder gets a minimal `PATH`, then in the directories of `PATH`.
enum Executables {
    /// `name` in each directory of `path`, in order; Windows also tries the suffixes its launchers use.
    static func onPath(_ name: String, path: String) -> [URL] {
        #if os(Windows)
        let names = [name, name + ".exe", name + ".cmd", name + ".bat"]
        return path.split(separator: ";").flatMap { directory in
            names.map { URL(fileURLWithPath: String(directory)).appendingPathComponent($0) }
        }
        #else
        return path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
        #endif
    }

    /// The first of `candidates` that can run.
    static func first(_ candidates: [URL], fileManager: FileManager = .default) -> URL? {
        candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
