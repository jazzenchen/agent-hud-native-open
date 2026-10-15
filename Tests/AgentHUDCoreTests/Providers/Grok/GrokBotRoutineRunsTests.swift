import Foundation
import XCTest
@testable import AgentHUDCore

final class GrokBotRoutineRunsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testReplyListsEachRunUnderTheBotThatOwnsItsRoutine() async {
        let reply = Self.reply([
            ("bot-one", #"{"id":"daily","name":"Daily digest","runs":[{"id":"run-a","startedAt":1799999000000},{"id":"run-b"}]}"#),
            ("bot-two", #"{"id":"weekly","name":"  ","runs":[{"id":"run-c","startedAt":1799998000000}]}"#),
            ("bot-two", "not json"),
        ])
        let runs = GrokBotRoutineRuns.parse(reply, now: now)
        XCTAssertEqual(runs["run-a"], .init(agent: "bot-one", name: "Daily digest", startedAt: Date(timeIntervalSince1970: 1_799_999_000)))
        XCTAssertEqual(runs["run-b"], .init(agent: "bot-one", name: "Daily digest", startedAt: now), "a run without a start is dated when it was read")
        XCTAssertEqual(runs["run-c"], .init(agent: "bot-two", name: "weekly", startedAt: Date(timeIntervalSince1970: 1_799_998_000)),
                       "a routine without a name is called by its id")
        XCTAssertEqual(runs.count, 3)
    }

    func testRunListedUnderTwoBotsNamesNeither() async {
        let reply = Self.reply([("bot-one", #"{"id":"a","runs":[{"id":"run-a"},{"id":"run-b"}]}"#),
                                ("bot-two", #"{"id":"b","runs":[{"id":"run-a"}]}"#)])
        XCTAssertEqual(Set(GrokBotRoutineRuns.parse(reply, now: now).keys), ["run-b"])
    }

    func testServiceIsAskedOnlyAboutAnUnexplainedSubagentConversationOfARosteredAccount() async throws {
        let fixture = try GrokBotCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let calls = Calls(), now = now
        let runs = GrokBotRoutineRuns(directory: fixture.directory, clock: { now })
        let read: @Sendable ([String]) async throws -> ProviderJSON = { agents in
            calls.note(agents)
            return Self.reply([("fixture-agent", #"{"id":"daily","name":"Daily digest","runs":[{"id":"run-a","startedAt":1799999000000}]}"#)])
        }
        let bot = "cursor-account:billing:fixture-agent", run = "cursor-account:billing:sand-subagent-run-a"

        await runs.refresh(billed: [bot, run], read: read)
        XCTAssertTrue(calls.all.isEmpty, "no roster, no bots to ask about")

        _ = try fixture.writeRoster()
        await runs.refresh(billed: [bot], read: read)
        XCTAssertTrue(calls.all.isEmpty, "a bot's own conversation needs no parent")

        await runs.refresh(billed: [bot, run], read: read)
        XCTAssertEqual(calls.all, [["fixture-agent"]])
        let links = await runs.links
        XCTAssertEqual(links["run-a"]?.agent, "fixture-agent")

        await runs.refresh(billed: [bot, run], read: read)
        XCTAssertEqual(calls.all.count, 1, "a known run is not asked about again")
    }

    func testUnlistedConversationIsAskedAboutTwiceAndAFailedReadDoesNotCount() async throws {
        let fixture = try GrokBotCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try fixture.writeRoster()
        let calls = Calls(), clock = Clock(now)
        let runs = GrokBotRoutineRuns(directory: fixture.directory, clock: { clock.now })
        let billed = ["cursor-account:billing:sand-subagent-not-a-run"]
        let empty: @Sendable ([String]) async throws -> ProviderJSON = { calls.note($0); return .object([:]) }

        await runs.refresh(billed: billed) { _ in throw ProviderFailure.format }
        await runs.refresh(billed: billed, read: empty)
        XCTAssertEqual(calls.all.count, 1, "the failed read left the first attempt open")
        await runs.refresh(billed: billed, read: empty)
        XCTAssertEqual(calls.all.count, 1, "the second attempt waits")
        clock.now = now.addingTimeInterval(GrokBotRoutineRuns.retryAfter)
        await runs.refresh(billed: billed, read: empty)
        XCTAssertEqual(calls.all.count, 2)
        clock.now = now.addingTimeInterval(GrokBotRoutineRuns.retryAfter * 10)
        await runs.refresh(billed: billed, read: empty)
        XCTAssertEqual(calls.all.count, 2, "a conversation that is no routine's run costs no further request")

        await runs.refresh(billed: billed + ["cursor-account:billing:sand-subagent-newer"], read: empty)
        XCTAssertEqual(calls.all.count, 3, "a new conversation is asked about")
    }

    func testRunsSurviveARelaunchAndLeaveWithTheLedgerRetention() async throws {
        let fixture = try GrokBotCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try fixture.writeRoster()
        let file = fixture.directory.appendingPathComponent("routine-runs.json"), clock = Clock(now)
        let old = Int64(now.addingTimeInterval(-UsageLedger.retention + 60).timeIntervalSince1970 * 1000)
        let reply = Self.reply([("fixture-agent", #"{"id":"daily","name":"Daily digest","runs":[{"id":"run-old","startedAt":\#(old)}]}"#)])
        let first = GrokBotRoutineRuns(directory: fixture.directory, fileURL: file, clock: { clock.now })
        await first.refresh(billed: ["cursor-account:billing:sand-subagent-run-old"]) { _ in reply }

        let second = GrokBotRoutineRuns(directory: fixture.directory, fileURL: file, clock: { clock.now })
        let kept = await second.links
        XCTAssertEqual(kept["run-old"]?.name, "Daily digest", "a deleted routine's run stays known")

        clock.now = now.addingTimeInterval(120)
        await second.refresh(billed: ["cursor-account:billing:sand-subagent-run-new"]) { _ in .object([:]) }
        let pruned = await second.links
        XCTAssertNil(pruned["run-old"])
        let third = GrokBotRoutineRuns(directory: fixture.directory, fileURL: file, clock: { clock.now })
        let saved = await third.links
        XCTAssertTrue(saved.isEmpty)
    }

    static func reply(_ automations: [(agent: String, record: String)]) -> ProviderJSON {
        let agents = Dictionary(grouping: automations, by: { $0.agent }).sorted { $0.key < $1.key }.map { agent, records in
            ProviderJSON.object(["agentId": .string(agent), "automations": .array(records.map {
                ProviderJSON.object(["automationId": .string("automation"), "recordJson": .string($0.record)])
            })])
        }
        return .object(["agents": .array(agents)])
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String]] = []
    func note(_ agents: [String]) { lock.lock(); values.append(agents); lock.unlock() }
    var all: [[String]] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ now: Date) { value = now }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
