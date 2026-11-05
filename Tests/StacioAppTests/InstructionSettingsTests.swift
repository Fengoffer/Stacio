import XCTest
import Foundation
@testable import StacioApp

/// P4-13：指令与项目规则 Settings（加密正文、projectDiscovery、approved roots、导出与生效边界）。
final class InstructionSettingsTests: XCTestCase {

    private var masterKey: Data { Data((0..<32).map { UInt8($0) }) }

    // MARK: - globalText 加密

    func testGlobalTextEncryptedWithPreferenceContentKey() throws {
        let text = "系统指令正文"
        let sealed = try InstructionSettingsAction.sealGlobalText(text, masterKeyData: masterKey)
        XCTAssertNotEqual(sealed, Data(text.utf8), "正文加密存储")
        XCTAssertEqual(try InstructionSettingsAction.openGlobalText(sealed, masterKeyData: masterKey), text)
        // 默认空字符串可往返
        let empty = try InstructionSettingsAction.sealGlobalText("", masterKeyData: masterKey)
        XCTAssertEqual(try InstructionSettingsAction.openGlobalText(empty, masterKeyData: masterKey), "")
    }

    func testGlobalTextSizeLimit256KiB() {
        XCTAssertTrue(InstructionSettingsAction.validateGlobalText(String(repeating: "x", count: 256 * 1024)))
        XCTAssertFalse(
            InstructionSettingsAction.validateGlobalText(String(repeating: "x", count: 256 * 1024 + 1)),
            "256 KiB 超限拒绝保存"
        )
        XCTAssertEqual(InstructionSettingsAction.maxGlobalTextBytes(), 256 * 1024)
    }

    func testResetDeletesBodyAndRotatesKey() {
        XCTAssertTrue(InstructionSettingsAction.resetDeletesBodyAndRotatesKey(), "重置删除正文并轮换 key")
    }

    // MARK: - projectDiscovery

    func testProjectDiscoveryDefaultAskBeforeAdding() {
        XCTAssertEqual(InstructionSettingsAction.defaultProjectDiscovery(), .askBeforeAdding)
        XCTAssertEqual(InstructionSettingsSnapshot().projectDiscovery, .askBeforeAdding, "快照默认 askBeforeAdding")
        XCTAssertEqual(Set(ProjectDiscoveryMode.allCases), Set([.off, .askBeforeAdding, .approvedRoots]))
    }

    // MARK: - approved roots

    func testRemoteCannotDisguiseAsLocalRoot() {
        // 本地 security-scoped 引用合法
        let local = ApprovedRootReference(
            rootPath: "/Users/mac/projects/stacio", securityScoped: true,
            targetBindingDigest: "digest-1", declaresRemote: false
        )
        XCTAssertTrue(InstructionSettingsAction.remoteCannotDisguiseAsLocalRoot(local))
        // 声明远程的引用拒绝（远程目录不能冒充 Mac 本地根）
        let remote = ApprovedRootReference(
            rootPath: "ssh://host/etc", securityScoped: true,
            targetBindingDigest: "digest-2", declaresRemote: true
        )
        XCTAssertFalse(InstructionSettingsAction.remoteCannotDisguiseAsLocalRoot(remote))
    }

    func testApprovedRootHasSecurityScopedAndBindingDigest() {
        let root = ApprovedRootReference(
            rootPath: "/Users/mac/projects/x", securityScoped: true,
            targetBindingDigest: "encrypted-binding", declaresRemote: false
        )
        XCTAssertTrue(root.securityScoped, "security-scoped 本地目录引用")
        XCTAssertNotNil(root.targetBindingDigest, "明确 TargetBinding/project identity 加密列表")
        XCTAssertFalse(root.targetBindingDigest!.contains("/Users"), "digest 不含路径正文")
    }

    // MARK: - 发现与信任

    func testDiscoveredFileOnlyHints() {
        XCTAssertTrue(InstructionSettingsAction.discoveredFileOnlyHints(), "发现文件只提示、不因文件名自动信任或执行")
    }

    // MARK: - 只读合同与导出

    func testPriorityAndEffectPreviewReadOnlyContract() {
        XCTAssertTrue(InstructionSettingsAction.priorityAndEffectPreviewAreReadOnly(), "优先级与生效预览是只读合同")
    }

    func testExportDefaultsMetadataHashOnly() {
        XCTAssertTrue(InstructionSettingsAction.exportDefaultsToMetadataAndHashOnly(), "导出默认只含来源 metadata/hash 不含正文")
        XCTAssertTrue(InstructionSettingsAction.bodyRequiresExplicitOptIn(), "正文只能单独勾选并经脱敏预览后导出")
    }

    // MARK: - 生效边界

    func testAffectsOnlyNewAttempts() {
        XCTAssertTrue(InstructionSettingsAction.affectsOnlyNewAttempts(), "设置只影响新 Attempt 不修改已冻结快照")
    }
}
