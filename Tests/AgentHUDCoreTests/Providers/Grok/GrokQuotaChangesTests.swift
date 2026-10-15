#if !os(Windows)
// This suite follows a symlink the way FSEvents reports it.
import XCTest
@testable import AgentHUDCore

final class GrokQuotaChangesTests: XCTestCase, @unchecked Sendable {
    func testDeletingCurrentLongKeyQuotaRefreshesAndPreservesLastReading() async throws {
        let f = try fixture()
        let account = "synthetic-account-" + String(repeating: "a", count: 100)
        try f.writeAccount(account)
        let quota = try writeQuota(f, account: account)
        XCTAssertEqual(quota.pathExtension, "kblob")
        let provider = RetainedUsageProvider(provider: makeProvider(f))
        await provider.refreshAccountUsage(historyHours: 24)
        let first = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertTrue(first.vendorStatus("Grok").isNormal)
        XCTAssertEqual(first.snapshots.first?.remainingPct, 62.6)

        try FileManager.default.removeItem(at: quota)
        await provider.fileChanges([quota.path])
        let deleted = try await provider.fetchUsage(agents: first.discoveredAgents, historyHours: 24)
        XCTAssertFalse(deleted.vendorStatus("Grok").isNormal)
        XCTAssertEqual(deleted.snapshots, first.snapshots, "the failure must keep the last observed reading")
    }

    func testTranscriptAndOtherAccountQuotaEventsDoNotRefreshTheCurrentQuota() async throws {
        let f = try fixture(), other = try fixture()
        _ = try writeQuota(f, account: f.account)
        let reads = Reads()
        let provider = makeProvider(f, reads: reads)
        await provider.refreshAccountUsage(historyHours: 24)
        let transcript = try f.writeTranscript([], agent: String(repeating: "t", count: 150))
        XCTAssertEqual(transcript.pathExtension, "kblob")
        // A deleted transcript cannot be opened to classify its event.
        try FileManager.default.removeItem(at: transcript)
        let inactiveQuota = try writeQuota(f, account: "another-account")
        let otherDirectoryQuota = try writeQuota(other, account: f.account)
        await provider.fileChanges([transcript.path, inactiveQuota.path, otherDirectoryQuota.path])
        await provider.fileChanges([])
        await provider.fileChanges(nil)
        let count = await reads.count
        XCTAssertEqual(count, 1)
    }

    func testAccountMarkerSignOutAndDeletionRefreshWithoutAnAccountPoll() async throws {
        let f = try fixture()
        _ = try writeQuota(f, account: f.account)
        let reads = Reads(), provider = makeProvider(f, reads: reads)
        await provider.refreshAccountUsage(historyHours: 24)
        try f.writeAccount(nil)
        let marker = GrokBotCache.url(for: GrokBotCache.accountKey, in: f.directory)
        await provider.fileChanges([marker.path])
        let signedOut = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(signedOut.accounts?["Grok"], [])
        XCTAssertTrue(signedOut.snapshots.isEmpty)

        try FileManager.default.removeItem(at: marker)
        await provider.fileChanges([marker.path])
        let deleted = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertFalse(deleted.vendorStatus("Grok").isNormal)
        let count = await reads.count
        XCTAssertEqual(count, 3)
    }

    func testQuotaEventsUseTheResolvedCacheDirectoryPath() async throws {
        let f = try fixture(), container = try fixture()
        let link = container.directory.appendingPathComponent("cache-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.directory)
        let quota = try writeQuota(f, account: f.account)
        let provider = AdditionalUsageProvider(source: .grok, readQuota: {
            try GrokBotQuota.fetch(in: link, now: f.now) ?? ProviderQuota()
        }, readSessions: { _ in .init() }, history: QuotaHistoryStore(), clock: { f.now }, botQuotaDirectory: link)
        let actualDirectory = try XCTUnwrap(realpath(f.directory.path, nil))
        defer { free(actualDirectory) }
        let watchedPath = String(cString: actualDirectory) + "/" + quota.lastPathComponent
        for eventPath in [watchedPath, quota.path] {
            _ = try writeQuota(f, account: f.account)
            await provider.refreshAccountUsage(historyHours: 24)
            let before = try await provider.fetchUsage(agents: [], historyHours: 24)
            XCTAssertTrue(before.vendorStatus("Grok").isNormal)
            try FileManager.default.removeItem(at: quota)
            await provider.fileChanges([eventPath])
            let after = try await provider.fetchUsage(agents: [], historyHours: 24)
            XCTAssertFalse(after.vendorStatus("Grok").isNormal)
        }
    }

    private func fixture() throws -> GrokBotCacheFixture {
        let f = try GrokBotCacheFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: f.directory) }
        return f
    }

    private func makeProvider(_ f: GrokBotCacheFixture, reads: Reads? = nil) -> AdditionalUsageProvider {
        AdditionalUsageProvider(source: .grok, readQuota: {
            await reads?.record()
            return try GrokBotQuota.fetch(in: f.directory, now: f.now) ?? ProviderQuota()
        }, readSessions: { _ in .init() }, history: QuotaHistoryStore(), clock: { f.now }, botQuotaDirectory: f.directory)
    }

    private func writeQuota(_ f: GrokBotCacheFixture, account: String) throws -> URL {
        try f.write(["kind": "present", "selectedTeamId": NSNull(), "expiresAtMs": f.milliseconds(3600),
            "reading": ["readAtMs": f.milliseconds(-60), "usage": ["percentUsed": 37.4, "nextResetMs": NSNull(),
                "isSandTrial": false, "hasNonZeroIncludedLimit": true, "isTeamSeat": false]]],
            key: GrokBotCache.quotaKey(account: account), schema: 2)
    }

    private actor Reads {
        private(set) var count = 0
        func record() { count += 1 }
    }
}
#endif
