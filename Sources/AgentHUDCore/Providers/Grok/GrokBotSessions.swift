import AgentHUDSupport
import Foundation

/// The desktop client's account-scoped roster. Runtime turn state is deliberately absent from its persisted rows.
enum GrokBotSessions: LocalSessionLayout {
    #if os(Windows)
    static let installPaths = ["AppData/Roaming/Grok Bot"]
    #else
    static let installPaths = ["Library/Application Support/Grok Bot"]
    #endif

    static func roots(home: URL, environment: [String: String]) -> [URL] {
        [ClientHome.applicationData("Grok Bot", home: home).appendingPathComponent("sand-client-persistence", isDirectory: true)]
    }

    static func accepts(_ url: URL) -> Bool {
        guard let key = try? GrokBotCache.key(at: url) else { return false }
        return key.hasPrefix(GrokBotCache.accountPrefix) && key.hasSuffix(".roster.last-roster")
    }

    static func related(_ url: URL) -> [URL] {
        let directory = url.deletingLastPathComponent()
        // The directory changes when replicas are added or evicted; the marker changes on sign-in or sign-out.
        var result = [directory, GrokBotCache.url(for: GrokBotCache.accountKey, in: directory)]
        if let account = GrokBotCache.currentAccount(in: directory),
           let value = try? GrokBotCache.value(at: url, key: GrokBotCache.rosterKey(account: account), schema: 4) {
            result += (value["rows"].arrayValue ?? []).compactMap { row in
                guard let id = row["id"].stringValue, GrokBotCache.isAgentID(id) else { return nil }
                return GrokBotCache.url(for: GrokBotCache.transcriptKey(account: account, agent: id), in: directory)
            }
        }
        return result
    }

    /// The signed-in account's bots and rooms by their native ids, in roster order; none while the roster cannot be read.
    static func agentIDs(in directory: URL) -> [String] {
        guard let account = GrokBotCache.currentAccount(in: directory) else { return [] }
        let key = GrokBotCache.rosterKey(account: account)
        guard let value = try? GrokBotCache.value(at: GrokBotCache.url(for: key, in: directory), key: key, schema: 4) else { return [] }
        var seen = Set<String>()
        return (value["rows"].arrayValue ?? []).compactMap { row in
            guard let id = row["id"].stringValue, GrokBotCache.isAgentID(id), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    static func read(_ url: URL) throws -> ProviderSessions {
        let directory = url.deletingLastPathComponent()
        guard let account = GrokBotCache.currentAccount(in: directory),
              try GrokBotCache.key(at: url) == GrokBotCache.rosterKey(account: account) else { return .init() }
        let value = try GrokBotCache.value(at: url, key: GrokBotCache.rosterKey(account: account), schema: 4)
        guard let rows = value["rows"].arrayValue else { throw ProviderFailure.format }
        var seen = Set<String>()
        let sessions = rows.compactMap { row -> ProviderSession? in
            guard let id = row["id"].stringValue, GrokBotCache.isAgentID(id), seen.insert(id).inserted else { return nil }
            let transcript = GrokBotCache.url(for: GrokBotCache.transcriptKey(account: account, agent: id), in: directory)
            let title = SessionTitle.named(row["title"].stringValue) ?? SessionTitle.named(row["name"].stringValue) ?? "Grok Bot"
            var session = ProviderSession(id: GrokBotCache.sessionID(account: account, agent: id), title: title,
                path: FileManager.default.fileExists(atPath: transcript.path) ? transcript.path : nil, client: "Grok Bot")
            session.startedAt = ProviderDate.milliseconds(row["createdAt"])
            session.lastActivity = ProviderDate.milliseconds(row["lastActivityAt"]) ?? ProviderDate.milliseconds(row["updatedAt"]) ?? session.startedAt
            session.navigationTarget = .grokBotAgent(id: id)
            return session
        }
        // A switched account never inherits a roster being read from the previous account's partition.
        guard GrokBotCache.currentAccount(in: directory) == account else { return .init() }
        return .init(sessions: sessions)
    }
}

/// Grok Bot 0.68.1's plaintext persistence framing; no auth or safeStorage files are involved.
enum GrokBotCache {
    static let accountKey = "sand.client.slice.client-meta.account-slot"
    static let accountPrefix = "sand.client.slice.account."
    static let retention: TimeInterval = 7 * 86400
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    static func rosterKey(account: String) -> String { accountPrefix + component(account) + ".roster.last-roster" }
    static func quotaKey(account: String) -> String { accountPrefix + component(account) + ".weekly-usage.cache" }
    static func transcriptKey(account: String, agent: String) -> String { accountPrefix + component(account) + ".transcript.replicas." + component(agent) }
    static func sessionID(account: String, agent: String) -> String { "grok-bot:\(RecordCoding.hash([account])):\(agent)" }

    static func isAgentID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func currentAccount(in directory: URL) -> String? {
        guard let value = try? value(at: url(for: accountKey, in: directory), key: accountKey, schema: 1),
              let account = value.stringValue, !account.isEmpty else { return nil }
        return account
    }

    static func url(for key: String, in directory: URL) -> URL {
        let name = base32(Data(key.utf8)) + ".blob"
        return directory.appendingPathComponent(name.utf8.count <= 240 ? name : base32(Data(Digest.sha256(Data(key.utf8)))) + ".kblob")
    }

    static func key(at url: URL) throws -> String {
        let key: String
        switch url.pathExtension {
        case "blob":
            guard let data = decodeBase32(String(url.lastPathComponent.dropLast(5))),
                  let decoded = String(data: data, encoding: .utf8) else { throw ProviderFailure.format }
            key = decoded
        case "kblob":
            let data = try data(at: url)
            guard let newline = data.firstIndex(of: 10),
                  let decoded = try ProviderJSON.read(Data(data[..<newline])).stringValue else { throw ProviderFailure.format }
            key = decoded
        default: throw ProviderFailure.format
        }
        guard key.hasPrefix("sand."), self.url(for: key, in: url.deletingLastPathComponent()).lastPathComponent == url.lastPathComponent else {
            throw ProviderFailure.format
        }
        return key
    }

    static func value(at url: URL, key expected: String, schema: Int) throws -> ProviderJSON {
        guard try key(at: url) == expected else { throw ProviderFailure.format }
        let data = try data(at: url)
        let payload: Data
        if url.pathExtension == "kblob" {
            guard let newline = data.firstIndex(of: 10) else { throw ProviderFailure.format }
            payload = Data(data[data.index(after: newline)...])
        } else { payload = data }
        let envelope = try ProviderJSON.read(payload)
        guard envelope["schemaVersion"].countValue == schema, envelope.objectValue?["value"] != nil else { throw ProviderFailure.format }
        return envelope["value"]
    }

    static func transcriptAgent(key: String, account: String) -> String? {
        let prefix = accountPrefix + component(account) + ".transcript.replicas."
        guard key.hasPrefix(prefix), let agent = String(key.dropFirst(prefix.count)).removingPercentEncoding,
              isAgentID(agent), transcriptKey(account: account, agent: agent) == key else { return nil }
        return agent
    }

    private static func data(at url: URL) throws -> Data {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= ProviderFiles.jsonLimit else { throw ProviderFailure.limit }
        return try Data(contentsOf: url)
    }

    // encodeURIComponent, then encode literal periods, exactly as the desktop slice registry does.
    private static func component(_ text: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_!~*'()".utf8)
        let hex = Array("0123456789ABCDEF".utf8)
        var result = [UInt8]()
        for byte in text.utf8 {
            if allowed.contains(byte) { result.append(byte) }
            else { result += [37, hex[Int(byte >> 4)], hex[Int(byte & 15)]] }
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func base32(_ data: Data) -> String {
        var bits = 0, buffer: UInt32 = 0, result = [UInt8]()
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte); bits += 8
            while bits >= 5 { bits -= 5; result.append(alphabet[Int((buffer >> bits) & 31)]) }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { result.append(alphabet[Int((buffer << (5 - bits)) & 31)]) }
        return String(decoding: result, as: UTF8.self)
    }

    private static func decodeBase32(_ text: String) -> Data? {
        var bits = 0, buffer: UInt32 = 0, result = Data()
        for byte in text.utf8 {
            guard let value = alphabet.firstIndex(of: byte) else { return nil }
            buffer = (buffer << 5) | UInt32(value); bits += 5
            if bits >= 8 { bits -= 8; result.append(UInt8((buffer >> bits) & 255)); buffer &= (1 << bits) - 1 }
        }
        guard buffer == 0, base32(result) == text else { return nil }
        return result
    }
}
