#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import XCTest
@testable import AgentHUDCore

@MainActor
final class TokenModelFilterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let consumers = [
        AgentDescriptor(id: "codex-model:gpt-5", vendor: "Codex", model: "GPT-5", source: "", enabled: true),
        AgentDescriptor(id: "claude-model:claude-opus-4-5", vendor: "Claude", model: "Opus 4.5", source: "", enabled: true),
        AgentDescriptor(id: "local-model:custom", vendor: "Local Agent", model: "Custom", source: "", enabled: true),
    ]

    func testAllSingleMultipleAndEmptyChoicesAreExplicit() {
        var filter = TokenModelFilter()
        XCTAssertTrue(filter.isAll)
        XCTAssertTrue(filter.includes("a"))
        XCTAssertFalse(filter.isPicked("a"), "All is its own choice, rather than a list of explicit model picks")
        filter.toggle("a")
        XCTAssertEqual(filter.consumerIDs, ["a"])
        XCTAssertFalse(filter.includes("b"))
        filter.toggle("b")
        XCTAssertEqual(filter.consumerIDs, ["a", "b"])
        filter.toggle("a")
        XCTAssertEqual(filter.consumerIDs, ["b"])
        filter.toggle("b")
        XCTAssertEqual(filter.consumerIDs, [])
        XCTAssertFalse(filter.isAll, "Deselecting the last model does not silently show every model")
        XCTAssertFalse(filter.includes("a"))
        filter.selectAll()
        XCTAssertTrue(filter.isAll)
        XCTAssertTrue(filter.includes("a"))
    }

    func testColumnsTotalsHoverInputsAndCostsUseTheSameModelSelection() throws {
        let store = try makeStore()
        let allColumns = store.tokenColumns, allCost = store.statsListCost
        let allUsage = store.agentUsage, allCards = store.shownAgents
        var filter = TokenModelFilter()
        filter.toggle(consumers[0].id)
        let one = store.tokenColumns(consumerIDs: filter.consumerIDs)
        XCTAssertEqual(one.reduce(0) { $0 + $1.total }, 1100)
        let hovered = try XCTUnwrap(ChartData.tokenColumn(at: now.addingTimeInterval(-2 * 3600), in: one))
        XCTAssertEqual(hovered.tokens, [1100], "The hover stack contains only the selected model")
        XCTAssertEqual(store.statsListCost(consumerIDs: filter.consumerIDs),
                       ModelCatalog.cost(of: [consumers[0].id: TokenKinds(tokensIn: 1000, tokensOut: 100, cacheRead: 0)]))
        filter.toggle(consumers[1].id)
        let multiple = store.tokenColumns(consumerIDs: filter.consumerIDs)
        XCTAssertEqual(multiple.reduce(0) { $0 + $1.total }, 3300)
        XCTAssertTrue(multiple.allSatisfy { $0.tokens.count == 2 }, "Model order and every hover column share the selected consumer list")
        XCTAssertEqual(store.statsListCost(consumerIDs: filter.consumerIDs), ModelCatalog.cost(of: [
            consumers[0].id: TokenKinds(tokensIn: 1000, tokensOut: 100, cacheRead: 0),
            consumers[1].id: TokenKinds(tokensIn: 2000, tokensOut: 200, cacheRead: 0),
        ]))
        XCTAssertEqual(store.consumerPaletteIndex(consumers[1].id), 1, "Filtering does not renumber the palette")
        XCTAssertTrue(store.tokenColumns(consumerIDs: []).allSatisfy { $0.total == 0 && $0.tokens.isEmpty })
        XCTAssertNil(store.statsListCost(consumerIDs: []))
        XCTAssertEqual(store.tokenColumns, allColumns)
        XCTAssertEqual(store.statsListCost, allCost)
        XCTAssertEqual(store.agentUsage, allUsage)
        XCTAssertEqual(store.shownAgents, allCards, "The chart's model selection does not alter agent-card selection")
        XCTAssertNil(store.pickedAgents)
    }

    func testSelectionSurvivesRangesAndKindsWithNoUsageAndCanBeCleared() throws {
        let store = try makeStore()
        var filter = TokenModelFilter(consumerIDs: [consumers[2].id])
        XCTAssertEqual(store.tokenColumns(consumerIDs: filter.consumerIDs).reduce(0) { $0 + $1.total }, 333)
        store.setStatsRange(.hours5)
        XCTAssertEqual(store.tokenColumns(consumerIDs: filter.consumerIDs).reduce(0) { $0 + $1.total }, 0)
        store.tokenDimensions = .cacheRead
        XCTAssertEqual(store.tokenColumns(consumerIDs: filter.consumerIDs).reduce(0) { $0 + $1.total }, 0)
        XCTAssertEqual(filter.consumerIDs, [consumers[2].id])
        filter.selectAll()
        XCTAssertEqual(store.tokenColumns(consumerIDs: filter.consumerIDs).reduce(0) { $0 + $1.total }, 1100)
        XCTAssertEqual(store.statsRange, .hours5)
        XCTAssertEqual(store.tokenDimensions, .cacheRead, "Clearing models leaves the other chart controls alone")
    }

    func testHUDHistoryKeeps96QuartersAndAllKindsAcrossDashboardSelections() throws {
        let store = try makeStore()
        let columns = store.hudTokenColumns, interval = store.hudTokenInterval
        XCTAssertEqual(columns.count, 96)
        XCTAssertTrue(columns.allSatisfy { $0.interval.duration == 900 && $0.tokens.count == consumers.count })
        XCTAssertEqual(interval.duration, 86400)
        XCTAssertEqual(columns.first?.interval.start, interval.start)
        XCTAssertEqual(columns.last?.interval.end, interval.end)
        XCTAssertEqual(columns.reduce(0) { $0 + $1.total }, 4733)
        for range in StatsRange.allCases {
            store.setStatsRange(range)
            for size in range.bucketSizes {
                store.tokenBucketSize = size
                store.tokenDimensions = .output
                store.pickedAgents = []
                XCTAssertEqual(store.hudTokenColumns, columns)
                XCTAssertEqual(store.hudTokenInterval, interval)
            }
        }
    }

    private func makeStore() throws -> UsageStore {
        let suite = "TokenModelFilterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(provider: DemoUsageProvider(), settings: SettingsStore(defaults: defaults))
        store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: [], consumers: consumers, usage: [
            .init(start: now.addingTimeInterval(-2 * 3600), agentId: consumers[0].id, tokensIn: 1000, tokensOut: 100, cacheReadTokens: 400),
            .init(start: now.addingTimeInterval(-90 * 60), agentId: consumers[1].id, tokensIn: 2000, tokensOut: 200, cacheReadTokens: 700),
            .init(start: now.addingTimeInterval(-8 * 3600), agentId: consumers[2].id, tokensIn: 300, tokensOut: 33),
        ]))
        store.now = now
        return store
    }
}
#endif
