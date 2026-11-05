import XCTest
import Foundation
@testable import StacioApp

/// P4-12：用量与成本设置与定价 join。
final class UsageCostSettingsTests: XCTestCase {

    private static let iso8601 = ISO8601DateFormatter()

    private func makePricing(modelID: String, from: String, until: String? = nil) -> PricingEntry {
        PricingEntry(
            pricingEntryID: "pricing.\(modelID)", providerID: "openai.com", modelID: modelID,
            effectiveFrom: Self.iso8601.date(from: from)!,
            effectiveUntil: until.map { Self.iso8601.date(from: $0)! },
            inputPerMillion: 2.5, outputPerMillion: 10.0
        )
    }

    // MARK: - 默认与区间

    func testDefaults() {
        let limits = UsageCostSettingsAction.defaultLimits()
        XCTAssertEqual(limits.maxModelRoundtripsPerAttempt, 40, "默认 40 往返")
        XCTAssertNil(limits.tokenReminderThreshold, "token 提醒默认 off")
        XCTAssertNil(limits.costHardLimit, "费用硬上限默认 off")
        XCTAssertEqual(limits.pricingCatalogRevision, 1)
    }

    func testValidationRanges() {
        XCTAssertTrue(UsageCostSettingsAction.validateMaxModelRoundtrips(40))
        XCTAssertTrue(UsageCostSettingsAction.validateMaxModelRoundtrips(5))
        XCTAssertTrue(UsageCostSettingsAction.validateMaxModelRoundtrips(200))
        XCTAssertFalse(UsageCostSettingsAction.validateMaxModelRoundtrips(4))
        XCTAssertFalse(UsageCostSettingsAction.validateMaxModelRoundtrips(201))

        XCTAssertTrue(UsageCostSettingsAction.validateThreshold(nil), "off 合法")
        XCTAssertTrue(UsageCostSettingsAction.validateThreshold(1_000))
        XCTAssertTrue(UsageCostSettingsAction.validateThreshold(100_000_000))
        XCTAssertFalse(UsageCostSettingsAction.validateThreshold(999), "低于 1000 拒绝")
        XCTAssertFalse(UsageCostSettingsAction.validateThreshold(100_000_001))
    }

    func testRoundtripsCountedPerLogicalInvocation() {
        XCTAssertTrue(UsageCostSettingsAction.roundtripsAvailable(used: 39, limit: 40))
        XCTAssertFalse(UsageCostSettingsAction.roundtripsAvailable(used: 40, limit: 40))
        // 真实 retry 另记 providerRequestAttemptID 与费用（计数仍按逻辑 Invocation）
        _ = 0
    }

    // MARK: - 定价 join

    func testJoinPricingOnlyExactModelIDFromPricingCatalog() {
        let catalog = [
            makePricing(modelID: "gpt-4o", from: "2026-01-01T00:00:00Z"),
            makePricing(modelID: "claude-sonnet-4", from: "2026-01-01T00:00:00Z")
        ]
        XCTAssertEqual(
            UsageCostSettingsAction.joinPricing(catalog: catalog, modelID: "gpt-4o", providerID: "openai.com")?.modelID,
            "gpt-4o"
        )
        XCTAssertNil(
            UsageCostSettingsAction.joinPricing(catalog: catalog, modelID: "not-in-catalog", providerID: "openai.com"),
            "仅上游已发现同一精确 model ID"
        )
    }

    func testAttemptFrozePricingRevisionNoRecalculation() {
        XCTAssertTrue(UsageCostSettingsAction.estimateFrozenForAttempt(attemptRevision: 3, currentCatalogRevision: 3))
        // 目录更新（revision 4）不回算已展示金额：attempt 冻结在 3
        XCTAssertFalse(UsageCostSettingsAction.estimateFrozenForAttempt(attemptRevision: 3, currentCatalogRevision: 4))
    }

    // MARK: - 硬费用门禁

    func testHardLimitUnavailableWhenPriceEvidenceExpired() {
        let now = Self.iso8601.date(from: "2026-03-01T00:00:00Z")!
        // 无价格条目 → 不可用
        XCTAssertFalse(UsageCostSettingsAction.hardLimitAvailable(entry: nil, now: now))
        // 生效期未来 → 不可用
        let future = makePricing(modelID: "gpt-4o", from: "2026-06-01T00:00:00Z")
        XCTAssertFalse(UsageCostSettingsAction.hardLimitAvailable(entry: future, now: now))
        // 已过生效期（until 到期）→ 不可用
        let expired = makePricing(modelID: "gpt-4o", from: "2026-01-01T00:00:00Z", until: "2026-02-01T00:00:00Z")
        XCTAssertFalse(UsageCostSettingsAction.hardLimitAvailable(entry: expired, now: now))
        // 有效 → 可用
        let valid = makePricing(modelID: "gpt-4o", from: "2026-01-01T00:00:00Z", until: "2026-12-01T00:00:00Z")
        XCTAssertTrue(UsageCostSettingsAction.hardLimitAvailable(entry: valid, now: now))
        XCTAssertEqual(UsageCostSettingsAction.priceEvidenceExpiredDisplay(), "价格证据过期")
    }

    func testHardLimitIsNextInvocationGateNotAbsoluteCap() {
        XCTAssertTrue(UsageCostSettingsAction.blocksNextInvocation(costSoFar: 1500, hardLimit: 1000))
        XCTAssertFalse(UsageCostSettingsAction.blocksNextInvocation(costSoFar: 500, hardLimit: 1000))
        XCTAssertFalse(UsageCostSettingsAction.blocksNextInvocation(costSoFar: 99999, hardLimit: nil), "off 不阻断")
        XCTAssertFalse(UsageCostSettingsAction.advertisesAbsoluteCap(), "不宣传绝对封顶（在途调用仍可能越过）")
    }

    // MARK: - 未知 usage 的 Local Agent

    func testUnknownUsageLimitedByRoundtripsOnly() {
        XCTAssertTrue(UsageCostSettingsAction.unknownUsageLimitedBy(limits: AttemptUsageLimits()))
        XCTAssertEqual(UsageCostSettingsAction.unknownUsageDisplay(), "CLI 内部用量未知")
    }

    // MARK: - 达上限暂停与额度 Decision

    func testPauseAtSideEffectFreeBoundaryAndQuotaDecisionScope() {
        XCTAssertTrue(UsageCostSettingsAction.pauseAtNextSideEffectFreeBoundary())
        XCTAssertTrue(UsageCostSettingsAction.quotaDecisionOnlyExtendsCurrentAttempt(), "额度 Decision 只增加当前 Attempt 额度")
        XCTAssertTrue(UsageCostSettingsAction.quotaDecisionNeverChangesGlobalSettings(), "不修改全局设置")
        XCTAssertTrue(UsageCostSettingsAction.quotaDecisionNeverSwitchesCheaperModel(), "不自动换便宜模型/供应商")
    }

    // MARK: - Coding Plan 额度展示

    func testPlanQuotaSeparateAndNotAssumedFromHTTP200() {
        XCTAssertTrue(UsageCostSettingsAction.planQuotaSeparateFromAPICost(), "Coding Plan 额度与 API 费用分开展示")
        XCTAssertTrue(UsageCostSettingsAction.http200IsNotQuotaFact())
        XCTAssertTrue(UsageCostSettingsAction.planPurchasedIsNotQuotaFact())
        XCTAssertTrue(UsageCostSettingsAction.localEstimateIsNotQuotaFact())
    }
}
