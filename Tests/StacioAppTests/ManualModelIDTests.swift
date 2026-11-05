import XCTest
import Foundation
@testable import StacioApp

/// P4-9b：手动模型 ID（provider.manageManualModelIDs）。
final class ManualModelIDTests: XCTestCase {

    private func makeState(manual: [String] = []) -> ProviderModelCatalogState {
        ProviderModelCatalogState(
            discoveredModelIDs: ["gpt-4o"], manualModelIDs: manual,
            enabledModelIDs: [], defaultModelID: nil
        )
    }

    private func assertFailure<T>(
        _ result: Result<T, ManualModelIDError>, _ error: ManualModelIDError,
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failure(let actual) = result else {
            return XCTFail(message + "（预期失败，实际成功）", file: file, line: line)
        }
        XCTAssertEqual(actual, error, message, file: file, line: line)
    }

    private func assertSuccess<T>(
        _ result: Result<T, ManualModelIDError>,
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .success = result else {
            return XCTFail(message + "（预期成功）", file: file, line: line)
        }
    }

    // MARK: - 仅无枚举契约源可用

    func testOnlyAvailableForNoEnumerationContractCustomSources() {
        XCTAssertTrue(ManualModelIDAction.available(hasEnumerationContract: false), "自定义兼容源无枚举契约 → 可用")
        XCTAssertFalse(ManualModelIDAction.available(hasEnumerationContract: true), "预置 Provider/Coding Plan 不可用")
        XCTAssertFalse(ManualModelIDAction.available(hasEnumerationContract: nil), "未声明契约也不可用")
    }

    // MARK: - 原子校验

    func testAtomicValidationLengthControlCharsDuplicate() {
        // 长度
        assertFailure(ManualModelIDAction.validate(modelID: "", existing: []), .invalidLength, "空 ID 拒绝")
        assertFailure(
            ManualModelIDAction.validate(modelID: String(repeating: "x", count: 201), existing: []),
            .invalidLength, "超长拒绝"
        )
        // 控制字符
        assertFailure(
            ManualModelIDAction.validate(modelID: "bad\u{0007}model", existing: []),
            .controlCharacters, "控制字符拒绝"
        )
        // 重复
        assertFailure(
            ManualModelIDAction.validate(modelID: "dup", existing: ["dup"]),
            .duplicate, "重复拒绝"
        )
        // 合法
        assertSuccess(
            ManualModelIDAction.validate(modelID: "custom-llm-v3", existing: ["other"]),
            "合法模型 ID"
        )
    }

    // MARK: - 添加/编辑/删除

    func testAddMarksUserDeclared() throws {
        let result = ManualModelIDAction.add(
            modelID: "custom-llm", to: makeState(), hasEnumerationContract: false
        )
        let state = try result.get()
        XCTAssertEqual(state.manualModelIDs, ["custom-llm"])
        XCTAssertEqual(ManualModelIDAction.source, "userDeclared", "标记 userDeclared 来源")

        // 有枚举契约 → 拒绝
        assertFailure(
            ManualModelIDAction.add(modelID: "x", to: makeState(), hasEnumerationContract: true),
            .notAllowed, "有枚举契约拒绝"
        )
        // 重复 → 拒绝
        assertFailure(
            ManualModelIDAction.add(modelID: "x", to: makeState(manual: ["x"]), hasEnumerationContract: false),
            .duplicate, "重复拒绝"
        )
    }

    func testEditReplacesExactly() throws {
        let base = makeState(manual: ["old-llm"])
        let edited = try ManualModelIDAction.edit(
            oldID: "old-llm", newID: "new-llm", state: base, hasEnumerationContract: false
        ).get()
        XCTAssertEqual(edited.manualModelIDs, ["new-llm"])
        // 编辑到已存在项 → 重复拒绝
        assertFailure(
            ManualModelIDAction.edit(
                oldID: "old-llm", newID: "x", state: makeState(manual: ["old-llm", "x"]),
                hasEnumerationContract: false
            ),
            .duplicate, "编辑到已存在项拒绝"
        )
        // 未知 oldID → 拒绝
        assertFailure(
            ManualModelIDAction.edit(
                oldID: "ghost", newID: "y", state: base, hasEnumerationContract: false
            ),
            .unknownModelID("ghost"), "未知 oldID 拒绝"
        )
    }

    func testRemoveShowsImpactFirst() throws {
        var state = makeState(manual: ["custom-llm"])
        state.enabledModelIDs = ["custom-llm"]
        state.defaultModelID = "custom-llm"
        let impact = ManualModelIDAction.removalImpact(modelID: "custom-llm", state: state)
        XCTAssertTrue(impact.hasImpact, "删除默认或已启用项先展示影响")
        XCTAssertTrue(impact.isDefault)
        XCTAssertTrue(impact.isEnabled)

        let removed = try ManualModelIDAction.remove(
            modelID: "custom-llm", state: state, hasEnumerationContract: false
        ).get()
        XCTAssertTrue(removed.manualModelIDs.isEmpty)
        XCTAssertTrue(removed.enabledModelIDs.isEmpty, "删除同时清除 enabled")
        XCTAssertNil(removed.defaultModelID, "删除同时清除 default")
    }

    // MARK: - 测试前不可启用/设为默认

    func testCannotEnableOrDefaultBeforeConnectionTest() {
        let state = makeState(manual: ["custom-llm"])
        XCTAssertFalse(
            ProviderModelCatalogService.canEnable(manualModelID: "custom-llm", state: state, connectionTested: false),
            "连接测试前不可启用"
        )
        XCTAssertFalse(ProviderModelCatalogService.canBecomeDefault(modelID: "custom-llm", state: state))
    }

    // MARK: - 切换到可枚举协议后失效

    func testInvalidatedWhenEnumerationProtocolAppears() {
        XCTAssertTrue(ManualModelIDAction.invalidatedWhenEnumerationAppears(hasEnumerationContract: true))
        XCTAssertFalse(ManualModelIDAction.invalidatedWhenEnumerationAppears(hasEnumerationContract: false))
        // 失效后 add 拒绝
        assertFailure(
            ManualModelIDAction.add(modelID: "x", to: makeState(), hasEnumerationContract: true),
            .notAllowed, "失效后 add 拒绝"
        )
    }

    // MARK: - 不回填

    func testNeverBackfillsDerivedData() {
        XCTAssertTrue(ManualModelIDAction.neverBackfills(), "不回填 discoveredModels/价格/能力/支持等级")
        // manual 项不出现在 discovered（visible 只含 discovered + 已启用 manual）
        let state = makeState(manual: ["custom-llm"])
        XCTAssertFalse(state.discoveredModelIDs.contains("custom-llm"))
        XCTAssertEqual(ManualModelIDAction.source, "userDeclared")
    }
}
