import Foundation
import XCTest
@testable import StacioApp

final class AgentConfigurationWriteTests: XCTestCase {
    func testPreparedDraftRejectsConcurrentChangeAndReportsActualBackup() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("demo config.conf")
        func run(_ prepare: Bool, _ fields: [String: String]) throws -> [String: String] {
            let args = fields.merging(["path": target.path]) { _, new in new }
            let json = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
            let cmd = try XCTUnwrap(prepare ? AgentConfigurationWrite.prepare(arguments: json) : AgentConfigurationWrite.command(arguments: json))
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]; p.standardOutput = pipe
            try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            return AgentConfigurationWrite.receipt(arguments: json, output: output)
        }
        func draft(_ value: String) throws -> [String: String] {
            let result = try run(true, [:]); XCTAssertEqual(result["status"], "prepared")
            let file = URL(fileURLWithPath: try XCTUnwrap(result["source"]))
            addTeardownBlock { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            XCTAssertFalse(AgentConfigurationWrite.requiresStaging("printf example > " + file.path))
            try value.write(to: file, atomically: true, encoding: .utf8)
            return result
        }
        XCTAssertEqual(try run(false, draft("initial"))["status"], "created")
        XCTAssertFalse(fm.fileExists(atPath: target.path + ".bak"))
        let stale = try draft("old draft")
        try "administrator edit".write(to: target, atomically: true, encoding: .utf8)
        XCTAssertEqual(try run(false, stale)["status"], "conflict")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "administrator edit")
        XCTAssertEqual(try run(false, draft("updated"))["backup_path"], target.path + ".bak")
        let receipt = try run(false, draft("updated again"))
        XCTAssertEqual(receipt["status"], "written")
        let second = try XCTUnwrap(receipt["backup_path"])
        XCTAssertNotEqual(second, target.path + ".bak")
        XCTAssertEqual(try String(contentsOfFile: second, encoding: .utf8), "updated")
    }
}
