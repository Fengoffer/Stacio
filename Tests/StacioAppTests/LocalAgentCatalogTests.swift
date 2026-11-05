import XCTest
import Foundation
@testable import StacioApp

final class LocalAgentCatalogTests: XCTestCase {
    func testRawIdentityMappingAcceptsOnlyStableRawValue() {
        XCTAssertEqual(LocalAgentCatalogAction.rawIdentity(from: "codex"), .codex)
        XCTAssertEqual(LocalAgentCatalogAction.rawIdentity(from: "claudeCode"), .claudeCode)
        XCTAssertEqual(LocalAgentCatalogAction.rawIdentity(from: "githubCopilot"), .githubCopilot)
        XCTAssertEqual(LocalAgentCatalogAction.rawIdentity(from: "geminiCli"), .geminiCli)
        XCTAssertEqual(LocalAgentCatalogAction.rawIdentity(from: "opencode"), .opencode)
        XCTAssertEqual(LocalAgentCatalogAction.rawIdentity(from: "mimoCode"), .mimoCode)
        XCTAssertEqual(LocalAgentCatalogAction.rawIdentity(from: "qwenCode"), .qwenCode)
        XCTAssertEqual(LocalAgentCatalogAction.rawIdentity(from: "kimiCode"), .kimiCode)
        XCTAssertNil(LocalAgentCatalogAction.rawIdentity(from: "Codex"), "显示名不是身份")
        XCTAssertNil(LocalAgentCatalogAction.rawIdentity(from: "claude"), "可执行文件名不是身份")
        XCTAssertNil(LocalAgentCatalogAction.rawIdentity(from: ""))
    }

    func testBundledCatalogIsTheOnlyDescriptorSource() throws {
        let catalog = BundledRuntimeCatalog.shared
        XCTAssertNil(catalog.loadError)
        let entries = LocalAgentCatalogAction.entries(catalog: catalog)
        XCTAssertEqual(entries.count, 10)

        let required = ["codex", "claudeCode", "githubCopilot", "geminiCli", "opencode", "mimoCode", "qwenCode", "kimiCode"]
        for identity in required {
            let entry = try XCTUnwrap(entries.first { $0.rawIdentity == identity })
            XCTAssertEqual(entry.supportLevel, .experimental)
            XCTAssertTrue(entry.isExecutableCandidate)
            XCTAssertFalse(entry.executableCandidates.isEmpty)
            XCTAssertFalse(entry.versionArgv.isEmpty)
            XCTAssertTrue(entry.permitsPTYFallback)
            XCTAssertTrue(entry.supportedCapabilities.contains("terminalPassthrough"))
            XCTAssertTrue(
                entry.executionProfiles.contains {
                    $0.profileID == "terminal-passthrough"
                        && $0.kind == .terminalPassthrough
                }
            )
            if identity == "codex" {
                XCTAssertTrue(entry.structuredProtocolPriority.contains(.rpc))
                XCTAssertTrue(entry.executionProfiles.contains {
                    $0.profileID == "managed-rpc" && $0.kind == .managed
                })
            } else if identity == "claudeCode" {
                XCTAssertTrue(entry.structuredProtocolPriority.contains(.jsonl))
                XCTAssertTrue(entry.executionProfiles.contains {
                    $0.profileID == "managed-jsonl" && $0.kind == .managed
                })
            }
            XCTAssertEqual(entry.supportedWorkingDirectoryModes, AgentProcessWorkingDirectoryMode.allCases)
            XCTAssertEqual(entry.defaultEnvironmentAllowlist, ["HOME", "LANG", "LC_*", "TERM", "TMPDIR"])
            XCTAssertFalse(entry.websiteActionIDs.isEmpty)
            XCTAssertFalse(entry.documentationSources.isEmpty)
        }
        XCTAssertFalse(entries.contains { $0.supportLevel == .ga }, "没有真实 E2E 证据时 Local Agent 不得 GA")
    }

    func testUnverifiedLegacyCandidatesRemainVisibleButNotExecutable() throws {
        let entries = LocalAgentCatalogAction.entries()
        for identity in ["stacioAgent", "zcode"] {
            let entry = try XCTUnwrap(entries.first { $0.rawIdentity == identity })
            XCTAssertEqual(entry.supportLevel, .unsupported)
            XCTAssertFalse(entry.isExecutableCandidate)
            XCTAssertTrue(entry.executableCandidates.isEmpty)
        }
    }

    func testAccountPlansUseNamedCatalogCompatibility() {
        XCTAssertEqual(
            LocalAgentCatalogAction.compatibleAgentIdentities(planID: "chatgpt-codex"),
            ["codex"]
        )
        XCTAssertEqual(
            LocalAgentCatalogAction.compatibleAgentIdentities(planID: "claude-code"),
            ["claudeCode"]
        )
        XCTAssertEqual(
            LocalAgentCatalogAction.compatibleAgentIdentities(planID: "github-copilot"),
            ["githubCopilot"]
        )
        XCTAssertEqual(
            LocalAgentCatalogAction.compatibleAgentIdentities(planID: "gemini-cli"),
            ["geminiCli"]
        )
    }

    func testUnimplementedRestrictedPlansHaveNoExecutableCompatibility() {
        XCTAssertEqual(
            LocalAgentCatalogAction.compatibleAgentIdentities(planID: "aliyun-coding-plan"),
            []
        )
        XCTAssertEqual(
            LocalAgentCatalogAction.compatibleAgentIdentities(planID: "glm-coding-plan"),
            []
        )
    }

    func testAccountOAuthIsNeverEmbedded() {
        XCTAssertFalse(LocalAgentCatalogAction.embeddedOAuthForAccountSubscriptionCLI())
    }
}
