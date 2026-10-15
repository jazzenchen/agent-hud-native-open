#if !os(Windows)
// This suite follows macOS filesystem, process or hook-command semantics.
import Foundation
import XCTest
@testable import AgentHUDCore

final class ClaudeDesktopSessionsTests: XCTestCase, @unchecked Sendable {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    private func metadata(root: URL, cli: String, local: String = "local_" + UUID().uuidString,
                          archived: Bool = false, extra: [String: Any] = [:]) throws -> URL {
        let account = root.appendingPathComponent("organization/account")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        var object: [String: Any] = ["sessionId": local, "cliSessionId": cli, "isArchived": archived]
        object.merge(extra, uniquingKeysWith: { _, value in value })
        let file = account.appendingPathComponent(local + ".json")
        try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
        return file
    }

    func testCodeAndCoworkUseDistinctTypedDestinationsAndExactNativeIDs() async throws {
        let code = try root(), cowork = try root()
        let codeID = "local_" + UUID().uuidString, coworkID = "local_" + UUID().uuidString
        try metadata(root: code, cli: "cli-code", local: codeID, extra: ["title": ["unused": true], "systemPrompt": ["unused": true]])
        try metadata(root: cowork, cli: "cli-cowork", local: coworkID)
        let index = ClaudeDesktopSessions(codeRoot: code, coworkRoot: cowork)
        XCTAssertEqual(index.roots, [code, cowork])
        let targets = await index.targets(sessionIDs: ["cli-code", "cli-cowork", String(codeID.dropFirst(6)), "missing"])
        XCTAssertEqual(targets, ["cli-code": .claudeDesktopSession(id: codeID), "cli-cowork": .claudeCoworkSession(id: coworkID)])
        let wanted = await index.targets(sessionIDs: ["cli-code"])
        XCTAssertEqual(wanted, ["cli-code": .claudeDesktopSession(id: codeID)], "unrequested identifiers cannot become targets")
    }

    func testArchivedAndAmbiguousMappingsAreUnavailableAndCacheUpdatesOnMetadataChange() async throws {
        let code = try root(), cowork = try root(), codeID = "local_" + UUID().uuidString
        let file = try metadata(root: code, cli: "same-cli", local: codeID)
        let index = ClaudeDesktopSessions(codeRoot: code, coworkRoot: cowork)
        var targets = await index.targets(sessionIDs: ["same-cli"])
        XCTAssertEqual(targets, ["same-cli": .claudeDesktopSession(id: codeID)])
        let other = try metadata(root: cowork, cli: "same-cli")
        targets = await index.targets(sessionIDs: ["same-cli"])
        XCTAssertEqual(targets, [:], "two different live destinations remain ambiguous")
        try FileManager.default.removeItem(at: other)
        try metadata(root: code, cli: "same-cli", local: codeID, archived: true)
        targets = await index.targets(sessionIDs: ["same-cli"])
        XCTAssertEqual(targets, [:])
        try metadata(root: code, cli: "new-cli", local: codeID)
        targets = await index.targets(sessionIDs: ["same-cli", "new-cli"])
        XCTAssertEqual(targets, ["new-cli": .claudeDesktopSession(id: codeID)])
        try FileManager.default.removeItem(at: file)
        targets = await index.targets(sessionIDs: ["new-cli"])
        XCTAssertEqual(targets, [:], "a removed metadata file cannot retain a cached destination")
    }

    func testOnlyBoundedMetadataAtTheKnownDepthIsRead() async throws {
        let code = try root(), validID = "local_" + UUID().uuidString
        let file = try metadata(root: code, cli: "valid-cli", local: validID)
        let account = file.deletingLastPathComponent()
        let nested = account.appendingPathComponent(validID + "/organization/account")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(#"{"sessionId":"local_bad","cliSessionId":"nested-cli"}"#.utf8).write(to: nested.appendingPathComponent("local_bad.json"))
        try metadata(root: code, cli: "wrong-local", local: "local_invalid")
        let mismatch = try metadata(root: code, cli: "wrong-name")
        try FileManager.default.moveItem(at: mismatch, to: account.appendingPathComponent("local_mismatch.json"))
        let overLimit = try metadata(root: code, cli: "oversized")
        try Data(repeating: 32, count: 1024 * 1024 + 1).write(to: overLimit)
        let outside = try root(), linkedID = "local_" + UUID().uuidString
        let linkedFile = try metadata(root: outside, cli: "linked-cli", local: linkedID)
        try FileManager.default.createSymbolicLink(atPath: account.appendingPathComponent(linkedID + ".json").path, withDestinationPath: linkedFile.path)
        let index = ClaudeDesktopSessions(codeRoot: code, coworkRoot: nil)
        let targets = await index.targets(sessionIDs: ["valid-cli", "nested-cli", "wrong-local", "wrong-name", "oversized", "linked-cli"])
        XCTAssertEqual(targets, ["valid-cli": .claudeDesktopSession(id: validID)])
    }
}
#endif
