#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import XCTest
@testable import AgentHUDCore

@MainActor
final class ScreenPlacementTests: XCTestCase {
    func testLogoSizeAndEdgeDistanceBoundsAreIndependentOfSpacing() throws {
        for (size, distance, expectedSize, expectedDistance) in [
            (30.0, 0.0, 30.0, 0.0), (36, 20, 36, 20), (100, 100, 36, 20), (-1, -1, 12, 0)
        ] {
            let data = try JSONEncoder().encode(["logoSize": size, "logoEdgeDistance": distance, "gapScale": 0.35])
            let placement = try JSONDecoder().decode(ScreenPlacement.self, from: data)
            XCTAssertEqual(placement.logoSize, expectedSize)
            XCTAssertEqual(placement.logoEdgeDistance, expectedDistance)
            XCTAssertEqual(placement.gapScale, 0.35)
        }
    }

    func testSavedPlacementWithoutEdgeDistanceUsesTheDefault() throws {
        let placement = try JSONDecoder().decode(ScreenPlacement.self, from: Data(#"{"logoSize":24,"gapScale":0.2}"#.utf8))
        XCTAssertEqual(placement.logoSize, 24)
        XCTAssertEqual(placement.logoEdgeDistance, 2)
        XCTAssertEqual(placement.gapScale, 0.2)
    }

    @MainActor
    func testEachDisplaysLogoSizeAndEdgeDistanceSurviveSettingsReload() throws {
        let suite = "AgentHUDTests.ScreenPlacement.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let placements = [
            "one": ScreenPlacement(edge: .top, logoSize: 30, logoEdgeDistance: 0, gapScale: 0.3),
            "two": ScreenPlacement(edge: .right, logoSize: 36, logoEdgeDistance: 20, gapScale: 0.6),
        ]
        store.update { $0.screens = placements }
        XCTAssertEqual(SettingsStore(defaults: defaults).settings.screens, placements)
    }

    func testSimpleModeSettingsDecodeWithinTheirBoundsAndDefaultWhenAbsent() throws {
        let saved = try JSONDecoder().decode(ScreenPlacement.self, from: Data(
            #"{"mode":"simple","edge":"left","simpleSize":100,"ringWidth":0.2,"showsRings":false}"#.utf8))
        XCTAssertEqual(saved.mode, .simple)
        XCTAssertEqual(saved.edge, .left)
        XCTAssertEqual(saved.simpleSize, 40)
        XCTAssertEqual(saved.ringWidth, 1)
        XCTAssertFalse(saved.showsRings)
        XCTAssertTrue(saved.showsNumbers)
        XCTAssertFalse(saved.simpleBots)
        let lively = try JSONDecoder().decode(ScreenPlacement.self, from: Data(#"{"mode":"simple","simpleBots":true}"#.utf8))
        XCTAssertTrue(lively.simpleBots)

        let older = try JSONDecoder().decode(ScreenPlacement.self, from: Data(#"{"mode":"logos","logoSize":24}"#.utf8))
        XCTAssertEqual(older.simpleSize, 22)
        XCTAssertEqual(older.ringWidth, 1.5)
        XCTAssertTrue(older.showsRings)
        XCTAssertTrue(older.showsNumbers)
        XCTAssertEqual(try JSONDecoder().decode(ScreenPlacement.self, from: JSONEncoder().encode(saved)), saved)
    }

    func testOnlyTheNotchIsNotDocked() {
        XCTAssertEqual(HUDMode.allCases.filter(\.isDocked), [.logos, .simple])
    }
}
#endif
