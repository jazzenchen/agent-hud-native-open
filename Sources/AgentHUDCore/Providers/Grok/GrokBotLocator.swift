import Foundation

/// Grok Bot is a desktop client with a data directory separate from Grok CLI and Cursor.
public enum GrokBotLocator {
    public static func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   applicationURLs: [URL]? = nil) -> Bool {
        let data = ClientHome.applicationData("Grok Bot", home: home)
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: data.path, isDirectory: &directory), directory.boolValue { return true }
        let apps = applicationURLs ?? VendorCatalog.applications("Grok Bot") + [
            URL(fileURLWithPath: "/Applications/Grok Bot.app", isDirectory: true),
            home.appendingPathComponent("Applications/Grok Bot.app", isDirectory: true),
        ]
        return apps.contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}
