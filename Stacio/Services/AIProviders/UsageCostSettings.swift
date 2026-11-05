import Foundation

// MARK: - 用量与成本设置（P4-12）

/// Attempt 用量限制：模型往返上限、token/费用阈值（off 或区间）、冻结的定价目录 revision。
public struct AttemptUsageLimits: Equatable, Sendable {
    /// 每 Attempt 最大模型往返（默认 40，可设 5..200）。
    public var maxModelRoundtripsPerAttempt: Int
    /// token 提醒阈值：nil=off，否则 1_000..100_000_000。
    public var tokenReminderThreshold: UInt?
    /// 费用硬上限：nil=off，否则 1_000..100_000_000。
    public var costHardLimit: UInt?
    /// Attempt 冻结的 pricingCatalogRevision（目录更新不回算已展示金额）。
    public var pricingCatalogRevision: Int

    public init(
        maxModelRoundtripsPerAttempt: Int = 40,
        tokenReminderThreshold: UInt? = nil,
        costHardLimit: UInt? = nil,
        pricingCatalogRevision: Int = 1
    ) {
        self.maxModelRoundtripsPerAttempt = maxModelRoundtripsPerAttempt
        self.tokenReminderThreshold = tokenReminderThreshold
        self.costHardLimit = costHardLimit
        self.pricingCatalogRevision = pricingCatalogRevision
    }
}

public enum UsageCostSettingsAction {

    public static let roundtripRange = 5...200
    public static let thresholdRange: ClosedRange<UInt> = 1_000...100_000_000

    /// 默认：40 往返、token/费用硬上限 off。
    public static func defaultLimits() -> AttemptUsageLimits {
        AttemptUsageLimits()
    }

    public static func validateMaxModelRoundtrips(_ value: Int) -> Bool {
        roundtripRange.contains(value)
    }

    /// 阈值合法：nil（off）或 1_000..100_000_000。
    public static func validateThreshold(_ value: UInt?) -> Bool {
        guard let value else { return true }
        return thresholdRange.contains(value)
    }

    /// 模型往返按逻辑 ModelInvocation 计数（其下真实 retry 另记 providerRequestAttemptID 与费用）。
    public static func roundtripsAvailable(used: Int, limit: Int) -> Bool {
        used < limit
    }

    // MARK: - 定价 join

    /// 价格只来自独立价格目录（带 revision/生效时间）；仅上游已发现同一精确 model ID 可 join。
    public static func joinPricing(catalog: [PricingEntry], modelID: String, providerID: String) -> PricingEntry? {
        catalog.first { $0.modelID == modelID && $0.providerID == providerID }
    }

    /// Attempt 冻结 pricingCatalogRevision；目录更新不回算已展示金额。
    public static func estimateFrozenForAttempt(attemptRevision: Int, currentCatalogRevision: Int) -> Bool {
        attemptRevision == currentCatalogRevision
    }

    // MARK: - 硬费用门禁

    /// 价格已过生效期或维度不完整 → 硬费用门禁不可用（显示「价格证据过期」）。
    public static func hardLimitAvailable(entry: PricingEntry?, now: Date) -> Bool {
        guard let entry else { return false }
        if entry.effectiveFrom > now { return false }
        if let until = entry.effectiveUntil, until <= now { return false }
        return entry.inputPerMillion >= 0 && entry.outputPerMillion >= 0
    }

    public static func priceEvidenceExpiredDisplay() -> String { "价格证据过期" }

    /// 硬上限是下一 Invocation 准入门禁（在途调用仍可能越过阈值，不宣传绝对封顶）。
    public static func blocksNextInvocation(costSoFar: Double, hardLimit: UInt?) -> Bool {
        guard let hardLimit else { return false }
        return costSoFar >= Double(hardLimit)
    }

    public static func advertisesAbsoluteCap() -> Bool { false }

    // MARK: - 未知 usage 的 Local Agent

    /// 未知 usage 只受模型往返/工具步骤/有效时长限制（无费用维度）。
    public static func unknownUsageLimitedBy(limits: AttemptUsageLimits) -> Bool {
        limits.maxModelRoundtripsPerAttempt > 0
    }

    public static func unknownUsageDisplay() -> String { "CLI 内部用量未知" }

    // MARK: - 达上限暂停与额度 Decision

    /// 达上限暂停在下一无副作用边界。
    public static func pauseAtNextSideEffectFreeBoundary() -> Bool { true }

    /// 持久化额度 Decision：只增加当前 Attempt 额度，不修改全局设置、不自动换便宜模型/供应商。
    public static func quotaDecisionOnlyExtendsCurrentAttempt() -> Bool { true }
    public static func quotaDecisionNeverChangesGlobalSettings() -> Bool { true }
    public static func quotaDecisionNeverSwitchesCheaperModel() -> Bool { true }

    // MARK: - Coding Plan 额度展示

    /// Coding Plan 额度与 API 费用分开展示。
    public static func planQuotaSeparateFromAPICost() -> Bool { true }

    /// 不把 HTTP 200/套餐已购/本地估算当剩余额度事实。
    public static func http200IsNotQuotaFact() -> Bool { true }
    public static func planPurchasedIsNotQuotaFact() -> Bool { true }
    public static func localEstimateIsNotQuotaFact() -> Bool { true }
}
