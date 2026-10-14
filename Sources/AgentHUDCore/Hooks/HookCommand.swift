import Foundation

/// The command a client runs to reach Agent HUD.
///
/// Only one Agent HUD runs at a time (`InstanceLock`), and it points every handler of Agent HUD's at itself: whichever
/// copy wrote a handler before, the one that runs takes it over, so moving the application or switching to another
/// build of it moves the hooks at the next start.
public enum HookCommand {
    /// `'<executable path>' <arguments>`, quoted for the shell the client runs it through: POSIX single quotes, and
    /// Windows double quotes, which cmd does not read escapes into.
    public static func make(executable: URL, arguments: String) -> String {
        #if os(Windows)
        "\"" + executable.path + "\" " + arguments
        #else
        "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "' " + arguments
        #endif
    }

    /// Whether `command` runs Agent HUD with `arguments`, whichever copy wrote it.
    public static func runs(_ command: String?, arguments: String) -> Bool {
        command?.hasSuffix(" " + arguments) == true
    }

    /// A place an app runs from only until it is moved: the randomized copy App Translocation makes of an app opened
    /// where it was downloaded, or a mounted volume such as the disk image it came on. A handler pointing there stops
    /// working once the app is moved or the image is ejected.
    public static func isTransient(_ path: String) -> Bool {
        #if os(Windows)
        false
        #else
        path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
        #endif
    }

    /// Throws when the app runs from a transient place, which then writes nothing: its handler would stop working once
    /// the app is moved.
    public static func checkInstall(executable: URL) throws {
        guard isTransient(executable.path) else { return }
        throw UsageProviderError(L10n.text("应用正从磁盘映像或临时位置运行，移到应用程序文件夹后才会写入回调",
                                           "The app is running from a disk image or a temporary copy; move it to Applications to add hooks"))
    }
}
