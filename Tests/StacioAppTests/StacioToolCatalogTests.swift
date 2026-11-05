import XCTest
import Foundation
@testable import StacioApp

/// P4-11：StacioToolCatalog 与工具能力（descriptor 固定字段、planningSafeReadOnly 资格、
/// 冻结快照、未声明工具拒绝、无法映射不转 shell、managed endpoint 阻断、导入无隐藏授权）。
final class StacioToolCatalogTests: XCTestCase {

    private func makeReadOnlyTool() -> StacioToolDescriptor {
        StacioToolDescriptor(
            toolID: "diagnostics.readFile", schemaRevision: 1,
            applicableTargetBindingKinds: ["terminal"],
            writeRisk: false, escalationRisk: false, networkRisk: false,
            planningSafeReadOnly: true, requiredLease: nil,
            maxInputBytes: 4096, maxOutputBytes: 65536, auditPolicy: "audit"
        )
    }

    private func makeWriteTool() -> StacioToolDescriptor {
        StacioToolDescriptor(
            toolID: "fs.write", schemaRevision: 1,
            applicableTargetBindingKinds: ["terminal", "local"],
            writeRisk: true, escalationRisk: false, networkRisk: false,
            planningSafeReadOnly: false, requiredLease: "writeLease",
            maxInputBytes: 65536, maxOutputBytes: 4096, auditPolicy: "audit"
        )
    }

    private func makeCatalog(tools: [StacioToolDescriptor]) throws -> StacioToolCatalog {
        try StacioToolCatalogLoader.load(revision: 3, tools: tools, userCheckedPlanningSafeReadOnlyIDs: [])
    }

    // MARK: - descriptor 固定字段

    func testDescriptorRequiredFields() throws {
        let tool = makeReadOnlyTool()
        XCTAssertEqual(tool.toolID, "diagnostics.readFile")
        XCTAssertEqual(tool.schemaRevision, 1)
        XCTAssertFalse(tool.applicableTargetBindingKinds.isEmpty, "适用 TargetBinding 类型必含")
        XCTAssertTrue(tool.maxInputBytes > 0 && tool.maxOutputBytes > 0, "输入/输出上限必含")
        XCTAssertFalse(tool.auditPolicy.isEmpty, "审计策略必含")
        XCTAssertNil(tool.requiredLease, "只读诊断工具无 lease")

        // 缺字段 → 构建失败
        let broken = StacioToolDescriptor(
            toolID: "", schemaRevision: 0, applicableTargetBindingKinds: [],
            writeRisk: false, escalationRisk: false, networkRisk: false,
            planningSafeReadOnly: false, requiredLease: nil,
            maxInputBytes: 0, maxOutputBytes: 0, auditPolicy: ""
        )
        XCTAssertThrowsError(try makeCatalog(tools: [broken])) { error in
            XCTAssertEqual(error as? StacioToolCatalogError, .missingRequiredFields(""))
        }
    }

    func testDuplicateToolIDFails() throws {
        let catalog = try makeCatalog(tools: [makeReadOnlyTool()])
        _ = catalog
        XCTAssertThrowsError(try makeCatalog(tools: [makeReadOnlyTool(), makeReadOnlyTool()])) { error in
            XCTAssertEqual(error as? StacioToolCatalogError, .duplicateToolID("diagnostics.readFile"))
        }
    }

    // MARK: - planningSafeReadOnly 资格

    func testPlanningSafeReadOnlyOnlyFromSignedCatalog() throws {
        // 用户自行勾选 → 拒绝
        XCTAssertThrowsError(
            try StacioToolCatalogLoader.load(
                revision: 1, tools: [makeReadOnlyTool()],
                userCheckedPlanningSafeReadOnlyIDs: ["diagnostics.readFile"]
            )
        ) { error in
            XCTAssertEqual(
                error as? StacioToolCatalogError,
                .planningSafeReadOnlyCannotBeUserChecked("diagnostics.readFile")
            )
        }
        // 声明 planningSafeReadOnly 但带写风险 → 拒绝（必须只读/幂等/无持久副作用）
        let risky = StacioToolDescriptor(
            toolID: "risky.read", schemaRevision: 1, applicableTargetBindingKinds: ["terminal"],
            writeRisk: true, escalationRisk: false, networkRisk: false,
            planningSafeReadOnly: true, requiredLease: nil,
            maxInputBytes: 1024, maxOutputBytes: 1024, auditPolicy: "audit"
        )
        XCTAssertThrowsError(try makeCatalog(tools: [risky])) { error in
            XCTAssertEqual(error as? StacioToolCatalogError, .planningSafeReadOnlyWithoutGuarantees("risky.read"))
        }
        // 只读诊断工具合法声明
        _ = try makeCatalog(tools: [makeReadOnlyTool()])
    }

    // MARK: - 启用语义

    func testEnabledMeansProposalNotPreapproval() {
        XCTAssertTrue(ToolEnablementPolicy.enabledMeansProposalOnly())
        // 写入工具即使启用仍逐次 Policy/Decision
        XCTAssertTrue(ToolEnablementPolicy.stillRequiresDecisionPerUse(tool: makeWriteTool()))
        XCTAssertFalse(ToolEnablementPolicy.stillRequiresDecisionPerUse(tool: makeReadOnlyTool()))
        // 新安装可启用已验证只读诊断工具
        XCTAssertTrue(ToolEnablementPolicy.newInstallCanEnableReadOnlyDiagnostic(tool: makeReadOnlyTool()))
        XCTAssertFalse(ToolEnablementPolicy.newInstallCanEnableReadOnlyDiagnostic(tool: makeWriteTool()))
    }

    func testEnablementAndRevisionFrozenIntoAttempt() {
        XCTAssertTrue(ToolEnablementPolicy.frozenIntoAttempt(), "工具启停与目录 revision 冻结进 Attempt")
        let snapshot = ToolCapabilitySnapshot(
            catalogRevision: 3, enabledToolIDs: ["diagnostics.readFile"],
            targetBindingDigest: "digest-1"
        )
        XCTAssertTrue(snapshot.includes("diagnostics.readFile"))
        XCTAssertFalse(snapshot.includes("fs.write"))
        XCTAssertEqual(snapshot.catalogRevision, 3)
        XCTAssertEqual(snapshot.targetBindingDigest, "digest-1")
    }

    // MARK: - Availability

    func testUndeclaredOrRevisionMismatchRejected() throws {
        let catalog = try makeCatalog(tools: [makeReadOnlyTool()])
        // 已声明且 revision 匹配 → available
        XCTAssertEqual(
            ToolAvailabilityResolver.resolve(
                runtimeToolID: "diagnostics.readFile", declaredRevision: 1, catalog: catalog
            ),
            .available(makeReadOnlyTool())
        )
        // 未声明 → 协议错误拒绝
        XCTAssertEqual(
            ToolAvailabilityResolver.resolve(runtimeToolID: "unknown.tool", declaredRevision: nil, catalog: catalog),
            .undeclaredTool("unknown.tool")
        )
        // revision 不匹配 → 拒绝
        XCTAssertEqual(
            ToolAvailabilityResolver.resolve(
                runtimeToolID: "diagnostics.readFile", declaredRevision: 2, catalog: catalog
            ),
            .revisionMismatch(toolID: "diagnostics.readFile", declared: 2, catalog: 1)
        )
    }

    func testProposalAdmissionUsesFrozenCatalogEnablementTargetAndInputLimit() throws {
        let catalog = try makeCatalog(tools: [makeReadOnlyTool()])
        let snapshot = ToolCapabilitySnapshot(
            catalogRevision: catalog.revision,
            enabledToolIDs: ["diagnostics.readFile"],
            targetBindingDigest: "target-digest"
        )
        XCTAssertEqual(
            ToolProposalAdmissionGate.evaluate(
                toolID: "diagnostics.readFile",
                schemaRevision: 1,
                inputByteCount: 128,
                targetBindingKind: "terminal",
                targetBindingDigest: "target-digest",
                snapshot: snapshot,
                catalog: catalog
            ),
            .available(makeReadOnlyTool())
        )
        XCTAssertEqual(
            ToolProposalAdmissionGate.evaluate(
                toolID: "diagnostics.readFile",
                schemaRevision: 2,
                inputByteCount: 128,
                targetBindingKind: "terminal",
                targetBindingDigest: "target-digest",
                snapshot: snapshot,
                catalog: catalog
            ),
            .schemaRevisionMismatch(toolID: "diagnostics.readFile", declared: 2, catalog: 1)
        )
        XCTAssertEqual(
            ToolProposalAdmissionGate.evaluate(
                toolID: "diagnostics.readFile",
                schemaRevision: 1,
                inputByteCount: 128,
                targetBindingKind: "terminal",
                targetBindingDigest: "other-target",
                snapshot: snapshot,
                catalog: catalog
            ),
            .targetBindingMismatch
        )
        XCTAssertEqual(
            ToolProposalAdmissionGate.evaluate(
                toolID: "diagnostics.readFile",
                schemaRevision: 1,
                inputByteCount: 4_097,
                targetBindingKind: "terminal",
                targetBindingDigest: "target-digest",
                snapshot: snapshot,
                catalog: catalog
            ),
            .inputTooLarge(toolID: "diagnostics.readFile", maximum: 4_096, actual: 4_097)
        )
    }

    func testProposalAdmissionRejectsDisabledAndUnknownTools() throws {
        let catalog = try makeCatalog(tools: [makeReadOnlyTool()])
        let snapshot = ToolCapabilitySnapshot(
            catalogRevision: catalog.revision,
            enabledToolIDs: [],
            targetBindingDigest: "target-digest"
        )
        XCTAssertEqual(
            ToolProposalAdmissionGate.evaluate(
                toolID: "diagnostics.readFile",
                schemaRevision: 1,
                inputByteCount: 1,
                targetBindingKind: "terminal",
                targetBindingDigest: "target-digest",
                snapshot: snapshot,
                catalog: catalog
            ),
            .toolDisabled("diagnostics.readFile")
        )
        XCTAssertEqual(
            ToolProposalAdmissionGate.evaluate(
                toolID: "unknown.tool",
                schemaRevision: 1,
                inputByteCount: 1,
                targetBindingKind: "terminal",
                targetBindingDigest: "target-digest",
                snapshot: snapshot,
                catalog: catalog
            ),
            .undeclaredTool("unknown.tool")
        )
    }

    func testUnmappableToolNotTranslatedToShell() {
        XCTAssertEqual(ToolAvailabilityResolver.unmappableToolDisplay(), "不支持的工具")
        XCTAssertTrue(ToolAvailabilityResolver.neverTranslateUnmappableToShell(), "无法映射不转 shell 猜测")
    }

    func testManagedUndeclaredEndpointBlocked() {
        XCTAssertTrue(
            ToolAvailabilityResolver.blocksUndeclaredEndpoint(
                endpointID: "mcp://unregistered", registeredEndpoints: ["mcp://registered"]
            ),
            "managed 未登记 endpoint 被 containment 阻断"
        )
        XCTAssertFalse(
            ToolAvailabilityResolver.blocksUndeclaredEndpoint(
                endpointID: "mcp://registered", registeredEndpoints: ["mcp://registered"]
            )
        )
    }

    // MARK: - 设置页与导入

    func testSettingsCannotEditExecutableToImpersonate() {
        XCTAssertFalse(
            StacioToolCatalogLoader.settingsCanEditExecutable(tool: makeReadOnlyTool()),
            "设置页不能编辑 executable/argv/schema 冒充内置工具"
        )
        // executable 缺失但 argv 存在 → 拒绝（可被用户构造）
        let weird = StacioToolDescriptor(
            toolID: "weird.tool", schemaRevision: 1, applicableTargetBindingKinds: ["terminal"],
            writeRisk: false, escalationRisk: false, networkRisk: false,
            planningSafeReadOnly: false, requiredLease: nil,
            maxInputBytes: 100, maxOutputBytes: 100, auditPolicy: "audit",
            executable: nil, argv: ["/bin/sh"]
        )
        XCTAssertThrowsError(try makeCatalog(tools: [weird])) { error in
            XCTAssertEqual(error as? StacioToolCatalogError, .userEditableExecutable("weird.tool"))
        }
    }

    func testImportNoHiddenAuthorizationAndNoMCPServerButton() {
        XCTAssertFalse(StacioToolCatalogLoader.importCarriesHiddenToolAuthorization(), "导入配置不携带隐藏工具授权")
        XCTAssertFalse(StacioToolCatalogLoader.hasAddMCPServerButton(), "本期没有「添加 MCP Server」按钮")
    }
}
