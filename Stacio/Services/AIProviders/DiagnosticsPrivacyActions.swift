import Foundation

// MARK: - 诊断、隐私与上下文预览动作（P4-9d）

// MARK: diagnostics.previewBundle / exportBundle

public struct DiagnosticBundleEntry: Equatable, Sendable {
    public let filePath: String
    /// 内容类别：正文/终端/主机/配置/日志。
    public let contentCategory: String
    public let hash: String

    public init(filePath: String, contentCategory: String, hash: String) {
        self.filePath = filePath
        self.contentCategory = contentCategory
        self.hash = hash
    }
}

public enum DiagnosticsBundleAction {
    public static let forbiddenContentMarkers = ["credential", "capability", "oauth", "full env"]

    /// 先生成脱敏文件清单与内容类别（不读正文）。
    public static func previewBundle(files: [String], categoryByFile: [String: String], hashByFile: [String: String]) -> [DiagnosticBundleEntry] {
        files.map { file in
            DiagnosticBundleEntry(
                filePath: file,
                contentCategory: categoryByFile[file] ?? "unknown",
                hash: hashByFile[file] ?? ""
            )
        }
    }

    /// 用户可排除正文/终端/主机/配置类别。
    public static func excluding(entries: [DiagnosticBundleEntry], excludedCategories: Set<String>) -> [DiagnosticBundleEntry] {
        entries.filter { !excludedCategories.contains($0.contentCategory) }
    }

    /// 预览与导出同一 manifest/hash（稳定组合）。
    public static func manifestHash(entries: [DiagnosticBundleEntry]) -> String {
        let joined = entries.sorted { $0.filePath < $1.filePath }
            .map { "\($0.filePath):\($0.contentCategory):\($0.hash)" }
            .joined(separator: "\n")
        return "manifest:" + String(joined.utf8.count)
    }

    /// 任何脱敏失败阻止写出。
    public static func redactionFailed(entries: [DiagnosticBundleEntry], hashesKnown: Set<String>) -> Bool {
        entries.contains { !hashesKnown.contains($0.hash) }
    }

    /// 永不含 credential/capability/完整环境：清单中带禁止标记的类别拒绝。
    public static func containsForbiddenContent(category: String) -> Bool {
        forbiddenContentMarkers.contains { category.lowercased().contains($0) }
    }
}

// MARK: privacy.changeTelemetryConsent

public struct TelemetryConsentPreview: Equatable, Sendable {
    public let targetService: String
    public let fieldSchema: [String]
    public let samplingRetention: String
    public let currentRevision: Int

    public init(targetService: String, fieldSchema: [String], samplingRetention: String, currentRevision: Int) {
        self.targetService = targetService
        self.fieldSchema = fieldSchema
        self.samplingRetention = samplingRetention
        self.currentRevision = currentRevision
    }
}

public enum TelemetryConsentAction {

    /// 开启前展示目标服务/字段 schema/采样保留/当前 revision。
    public static func consentPreview(
        targetService: String, fieldSchema: [String], samplingRetention: String, currentRevision: Int
    ) -> TelemetryConsentPreview {
        TelemetryConsentPreview(
            targetService: targetService, fieldSchema: fieldSchema,
            samplingRetention: samplingRetention, currentRevision: currentRevision
        )
    }

    /// 关闭顺序：先 durable 关闭新 enqueue，再清空待发送队列。
    public static func closeOrder() -> [String] {
        ["durableDisableEnqueue", "clearPendingQueue"]
    }

    /// 任何内容/credential/主机/路径/命令/稳定用户身份不进入遥测。
    public static func neverInTelemetry(field: String) -> Bool {
        let lower = field.lowercased()
        return lower.contains("content") || lower.contains("credential") || lower.contains("host")
            || lower.contains("path") || lower.contains("command") || lower.contains("useridentity")
            || lower.contains("prompt")
    }
}

// MARK: context.previewOutboundPayload

public struct OutboundPayloadPreview: Equatable, Sendable {
    public let sources: [String]
    public let byteDigest: String
    public let targetOrigin: String
    public let omittedItems: [String]

    public init(sources: [String], byteDigest: String, targetOrigin: String, omittedItems: [String]) {
        self.sources = sources
        self.byteDigest = byteDigest
        self.targetOrigin = targetOrigin
        self.omittedItems = omittedItems
    }
}

public enum OutboundPayloadAction {

    /// 展示下一 Invocation 将发送的来源/字节摘要/目标 origin/被省略项；不发送请求。
    public static func preview(
        sources: [String], byteCount: Int, targetOrigin: String, omittedItems: [String]
    ) -> OutboundPayloadPreview {
        OutboundPayloadPreview(
            sources: sources,
            byteDigest: "bytes:\(byteCount)",
            targetOrigin: targetOrigin,
            omittedItems: omittedItems
        )
    }

    /// secret/安全输入/隐藏思维链永不进入预览。
    public static func neverInPreview(item: String) -> Bool {
        let lower = item.lowercased()
        return lower.contains("secret") || lower.contains("secureinput")
            || lower.contains("hiddenchain") || lower.contains("api key")
    }
}
