#if !os(Windows)
// This suite follows macOS filesystem, process or hook-command semantics.
import XCTest
@testable import AgentHUDCore

final class AntigravityServiceTests: XCTestCase, @unchecked Sendable {
    private func processes(_ count: Int) -> String {
        (1...count).map { "\($0) /Applications/Antigravity.app/Contents/Resources/language_server --csrf_token fixture-\($0)" }.joined(separator: "\n")
    }

    func testDiscoveryKeepsCandidateBoundariesPriorityAndQuotedFlagsAmongUnrelatedProcesses() async {
        let unrelated = (100...2_099).map {
            "\($0) /usr/local/bin/node /opt/workers/worker-\($0).js --argument=synthetic"
        }.joined(separator: "\n")
        let fixture = """
        9 /Applications/Antigravity IDE.app/language-server --csrf_token=ide-fixture
        3 agy\u{2003}serve --csrf_token '雪 fixture' --extension_server_port "65535" --extension_server_csrf_token='extension fixture'
        8 /usr/local/bin/agy-helper --csrf_token=other
        4 /opt/antigravity_cli/engine --extension_server_port 0
        7 /usr/local/bin/agy/bin/worker --csrf_token=other
        2 /opt/antigravity-cli/engine --extension_server_port=65536
        1 /Applications/Antigravity.app/language_server --csrf_token 'native fixture' --extension_server_port=42111
        6 /opt/other/language-server --app_data_dir='antigravity-ide' --csrf_token data-fixture
        5 /opt/other/language-server --app_data_dir='Antigravity' --csrf_token other
        10 /opt/antigravity/language_server
        11 /usr/local/bin/AGY serve
        12 /usr/local/bin/agy --x--csrf_token=ignored --extension_server_portExtra=41000
        """
        let candidates = AntigravityService.candidates(unrelated + "\n" + fixture)
        XCTAssertEqual(candidates.map(\.pid), [1, 2, 3, 4, 11, 12, 6, 9])
        XCTAssertEqual(candidates.map(\.priority), [0, 1, 1, 1, 1, 1, 2, 2])
        XCTAssertEqual(candidates.map(\.token), ["native fixture", "", "雪 fixture", "", "", "", "data-fixture", "ide-fixture"])
        XCTAssertEqual(candidates.map(\.extensionPort), [42111, nil, 65535, nil, nil, nil, nil, nil])
        XCTAssertEqual(candidates[2].extensionToken, "extension fixture")
    }

    func testNativeDiscoveryIncludesEveryCredentialBearingService() async throws {
        let processes = processes(7)
        let endpoints = try await AntigravityService.permissionEndpoints { executable, arguments in
            if executable == "/bin/ps" { return processes }
            let index = try XCTUnwrap(arguments.firstIndex(of: "-p"))
            let pid = try XCTUnwrap(Int(arguments[index + 1]))
            return "n127.0.0.1:\(50000 + pid)"
        }
        XCTAssertEqual(Set(endpoints.map(\.pid)), Set(1...7), "a later service must not silently disappear from the snapshot")
    }

    func testLaterInspectionFailureDoesNotReturnAnEarlierPartialDiscovery() async {
        enum Failure: Error { case inspection }
        let processes = processes(7)
        do {
            _ = try await AntigravityService.permissionEndpoints { executable, arguments in
                if executable == "/bin/ps" { return processes }
                if arguments.contains("7") { throw Failure.inspection }
                return "n127.0.0.1:50001"
            }
            XCTFail("an unread service is not an empty service")
        } catch { XCTAssertTrue(error is Failure) }
    }

    func testUnauthenticatedCLIListenersDoNotBlockSupportedNativeServices() async throws {
        let processes = processes(1) + "\n2 /usr/local/bin/agy --prompt-interactive fixture"
        let endpoints = try await AntigravityService.permissionEndpoints { executable, arguments in
            if executable == "/bin/ps" { return processes }
            XCTAssertFalse(arguments.contains("2"), "a CLI without discoverable credentials cannot authenticate this native API")
            return "n127.0.0.1:50001"
        }
        XCTAssertEqual(endpoints.map(\.pid), [1])
    }

    func testAnAuthenticatedServiceWithoutDiscoverableListenersIsUnknown() async {
        let processes = processes(1)
        do {
            _ = try await AntigravityService.permissionEndpoints { executable, _ in
                executable == "/bin/ps" ? processes : ""
            }
            XCTFail("a failed listener discovery must not settle an existing prompt")
        } catch { XCTAssertEqual(error.localizedDescription, ProviderFailure.format.localizedDescription) }
    }
}
#endif
