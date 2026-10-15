#if !os(Windows)
// This suite follows macOS filesystem, process or hook-command semantics.
import Foundation
import XCTest
@testable import AgentHUDCore

final class SessionProjectTests: XCTestCase {
    func testLinkedWorktreesAndTheirSubdirectoriesBelongToTheMainRepository() throws {
        let fixture = try Repository()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for path in [fixture.main, fixture.worktree, fixture.main.appendingPathComponent("Sources"),
                     fixture.worktree.appendingPathComponent("Sources/Feature")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            let session = session(path.path)
            XCTAssertEqual(SessionProject(session), .directory(fixture.main.path))
            XCTAssertEqual(session.workingDirectory, path.path, "project grouping keeps the execution directory")
        }
    }

    func testRelativeGitPointerAndDirectoryAliasUseTheSameRepository() throws {
        let fixture = try Repository()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let marker = fixture.worktree.appendingPathComponent(".git")
        let absolute = try String(contentsOf: marker, encoding: .utf8).dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let metadataName = URL(fileURLWithPath: absolute).lastPathComponent
        try "gitdir: ../main/.git/worktrees/\(metadataName)\n".write(to: marker, atomically: true, encoding: .utf8)
        let gitCommon = try Repository.git(["-C", fixture.worktree.path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        XCTAssertEqual(URL(fileURLWithPath: gitCommon).standardizedFileURL.resolvingSymlinksInPath().path,
                       fixture.main.appendingPathComponent(".git").path, "the relative fixture is also valid to Git")
        let alias = fixture.directory.appendingPathComponent("linked-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.worktree)
        XCTAssertEqual(SessionProject(session(fixture.worktree.path)), .directory(fixture.main.path))
        XCTAssertEqual(SessionProject(session(alias.path)), .directory(fixture.main.path))
    }

    func testNestedRepositoriesAndUnrelatedDirectoriesStaySeparate() throws {
        let fixture = try Repository()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let nested = fixture.worktree.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Repository.git(["init", "-q", nested.path])
        XCTAssertEqual(SessionProject(session(nested.appendingPathComponent("Sources").path)), .directory(nested.path),
                       "the nearest repository wins over the parent worktree")
        let outside = fixture.directory.appendingPathComponent("unrelated/main")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        XCTAssertEqual(SessionProject(session(outside.path)), .directory(outside.path))
        XCTAssertNotEqual(SessionProject(session(outside.path)), SessionProject(session(fixture.main.path)))
        XCTAssertEqual(SessionProject(session(nil)), .unassigned)
        XCTAssertEqual(SessionProject(session("")), .unassigned)
    }

    func testRootPathsTerminateAndKeepTheRecordedDirectory() {
        for path in ["/", "//", "/./", "/../"] {
            XCTAssertEqual(SessionProject(session(path)), .directory(path), "root spellings keep their original fallback path")
        }
    }

    func testMissingNonGitDirectoryKeepsItsOriginalPathAfterWalkingToRoot() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("HUD Unassigned \(UUID())")
            .appendingPathComponent("missing/../nested").path
        XCTAssertEqual(SessionProject(session(path)), .directory(path), "an unresolved execution path is not replaced by an ancestor")
    }

    private func session(_ path: String?) -> LiveSession {
        LiveSession(id: "session", agentId: "codex", task: "task", terminal: nil, startedAt: Date(),
                    endedAt: nil, pctOfWindow: nil, tokensIn: 0, tokensOut: 0, workingDirectory: path)
    }

    private struct Repository {
        let directory: URL
        let main: URL
        let worktree: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("HUD Project \(UUID().uuidString)")
                .resolvingSymlinksInPath()
            main = directory.appendingPathComponent("main", isDirectory: true)
            worktree = directory.appendingPathComponent("tree with space", isDirectory: true)
            try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
            try Self.git(["init", "-q", main.path])
            try Self.git(["-C", main.path, "-c", "user.name=HUD Tests", "-c", "user.email=tests@example.invalid",
                          "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", "Initial"])
            try Self.git(["-C", main.path, "worktree", "add", "--detach", "-q", worktree.path])
        }

        @discardableResult static func git(_ arguments: [String]) throws -> String {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else { throw NSError(domain: "SessionProjectTests.Git", code: Int(process.terminationStatus),
                                                                      userInfo: [NSLocalizedDescriptionKey: text]) }
            return text
        }
    }
}
#endif
