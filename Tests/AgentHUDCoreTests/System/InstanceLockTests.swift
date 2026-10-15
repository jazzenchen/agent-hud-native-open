#if !os(Windows)
// This suite follows macOS filesystem, process or hook-command semantics.
import Foundation
import XCTest
@testable import AgentHUDCore

/// One Agent HUD at a time: the lock every copy claims before it starts.
final class InstanceLockTests: XCTestCase, @unchecked Sendable {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testASecondClaimIsRefusedAndNamesTheCopyThatRuns() throws {
        let url = try directory().appendingPathComponent("app.agenthud/instance.lock")
        let running = URL(fileURLWithPath: "/Applications/Agent HUD.app/Contents/MacOS/Agent HUD")
        guard case .acquired(let first) = InstanceLock.claim(at: url, executable: running) else {
            return XCTFail("the first copy runs")
        }
        // flock refuses a second open file even in the same process, as it refuses another process.
        withExtendedLifetime(first) {
            guard case .held(let holder) = InstanceLock.claim(at: url, executable: URL(fileURLWithPath: "/tmp/agent-hud")) else {
                return XCTFail("a second copy must not run beside the first")
            }
            XCTAssertEqual(holder?.path, "/Applications/Agent HUD.app", "the refused launch names the application that runs")
        }
        XCTAssertEqual(InstanceLock.holder(at: url)?.path, "/Applications/Agent HUD.app", "a refused claim writes nothing")
    }

    func testTheLockGoesWithTheCopyThatHeldIt() throws {
        let url = try directory().appendingPathComponent("instance.lock")
        var first: InstanceLock.Claim? = InstanceLock.claim(at: url, executable: URL(fileURLWithPath: "/usr/local/bin/agent-hud"))
        guard case .acquired = first else { return XCTFail("the first copy runs") }
        guard case .held(let holder) = InstanceLock.claim(at: url) else { return XCTFail("the lock is held") }
        XCTAssertEqual(holder?.path, "/usr/local/bin/agent-hud", "an executable outside a bundle is named as it is")
        first = nil
        guard case .acquired = InstanceLock.claim(at: url, executable: URL(fileURLWithPath: "/Applications/Agent HUD Open.app/Contents/MacOS/Agent HUD Open")) else {
            return XCTFail("a copy that quit leaves the lock free")
        }
        XCTAssertEqual(InstanceLock.holder(at: url)?.path, "/Applications/Agent HUD Open.app", "the new holder replaces the old name")
    }

    func testALockThatCannotBeMadeLetsTheCopyRun() {
        guard case .unavailable = InstanceLock.claim(at: URL(fileURLWithPath: "/dev/null/app.agenthud/instance.lock")) else {
            return XCTFail("a missing lock is no reason not to run")
        }
    }
}
#endif
