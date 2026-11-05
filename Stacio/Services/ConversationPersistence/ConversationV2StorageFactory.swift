import Foundation

// MARK: - V2 存储装配工厂（P核心闭环·步骤 1）

/// 解析 V2 独立会话库路径并装配 `ConversationRepositoryV2` + `ConversationEncryption`，
/// 同时为新建会话构造合法的初始 `ConversationSessionState`（本地目标绑定 + Native API Runtime 选择）。
///
/// - 数据库路径经 `StacioPaths.applicationSupportDirectory` 解析，不硬编码绝对路径；
/// - 主密钥经 `KeychainConversationMasterKeyProvider` 从 Keychain 读取/生成；
/// - 不预置供应商 URL、模型名或 API Key——Runtime 凭证由 `LegacyProviderConfigurationAdapter` 在装配阶段单独解析；
/// - 首次访问自动创建 V2 存储目录与空数据库。
public enum ConversationV2StorageFactory {

    private static let admissionSchedulerLock = NSLock()
    private static var admissionSchedulers: [String: ProductionAgentExecutionScheduler] = [:]

    public struct StorageBundle {
        public let repository: ConversationRepositoryV2
        public let sealing: ConversationEncryptionSealingAdapter
    }

    /// V2 独立库文件名（规格 §15.1：不得放进 Stacio 共用数据库）。
    public static let databaseFileName = "agent-conversations-v2.sqlite3"

    /// 解析 V2 独立库绝对路径（`<AppSupport>/Stacio/agent-conversations-v2.sqlite3`）。
    /// 失败时抛出明确错误，不静默回退到临时目录或 Home。
    public static func databasePath(paths: StacioPaths) throws -> String {
        let directory = paths.applicationSupportDirectory
        return directory.appendingPathComponent(databaseFileName).path
    }

    /// 装配 `ConversationRepositoryV2`：主密钥 → 加密 facade → Rust 独立库 handle。
    /// - Parameters:
    ///   - conversationID: 会话 ID（加密派生用）。
    ///   - paths: 路径解析器（`StacioPaths()` 默认；因 init 为 throws，调用方负责构造）。
    ///   - masterKeyProvider: 主密钥 provider（默认 Keychain）。
    public static func makeRepository(
        conversationID: String,
        paths: StacioPaths,
        masterKeyProvider: ConversationMasterKeyProviding = KeychainConversationMasterKeyProvider.shared
    ) throws -> ConversationRepositoryV2 {
        let path = try databasePath(paths: paths)
        let encryption = try ConversationEncryption(masterKeyProvider: masterKeyProvider)
        return try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: path,
            encryption: encryption
        )
    }

    /// 生产装配使用同一个主密钥读取结果创建 Repository 与提交前密封验证器。
    public static func makeStorageBundle(
        conversationID: String,
        paths: StacioPaths,
        masterKeyProvider: ConversationMasterKeyProviding = KeychainConversationMasterKeyProvider.shared
    ) throws -> StorageBundle {
        let path = try databasePath(paths: paths)
        let encryption = try ConversationEncryption(masterKeyProvider: masterKeyProvider)
        let repository = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: path,
            encryption: encryption
        )
        return StorageBundle(
            repository: repository,
            sealing: ConversationEncryptionSealingAdapter(
                encryption: encryption,
                conversationID: conversationID
            )
        )
    }

    /// Return the one process-wide durable scheduler for this V2 database.
    /// Keeping it in a registry prevents a second window from starting a new
    /// scheduler generation and orphaning leases owned by the first window.
    public static func makeAdmissionScheduler(
        repository: ConversationRepositoryV2,
        paths: StacioPaths,
        capacity: Int
    ) throws -> ProductionAgentExecutionScheduler {
        let path = try databasePath(paths: paths)
        admissionSchedulerLock.lock()
        defer { admissionSchedulerLock.unlock() }
        if let existing = admissionSchedulers[path] {
            return existing
        }
        let scheduler = ProductionAgentExecutionScheduler(
            store: repository,
            capacity: capacity
        )
        admissionSchedulers[path] = scheduler
        return scheduler
    }

    /// 构造新建会话的合法初始状态（本地目标绑定 + Native API Runtime 选择）。
    /// 不预置供应商/模型——`runtimeSelection` 仅声明 nativeAPI kind，具体 provider/model 由装配阶段注入或后续配置。
    /// 首个 `turnSubmitted` 事件由 Actor 单写提交时携带。
    public static func makeInitialSessionState(
        sessionID: String,
        queueAutoAdvanceEnabled: Bool = true,
        defaultWorkMode: WorkMode = .agent,
        defaultReasoningEffort: String? = nil,
        memoryScope: String? = nil,
        initialTargetContext: AITerminalContext? = nil,
        now: Date = Date()
    ) -> ConversationSessionState {
        let target = initialTargetContext.map(targetBinding(for:)) ?? localTargetBinding(now: now)
        let runtimeSelection = AgentRuntimeSelection(
            kind: .nativeAPI,
            reasoningEffort: defaultReasoningEffort,
            workMode: defaultWorkMode
        )
        let session = ConversationSession(
            id: sessionID,
            title: "新会话",
            createdAt: now,
            updatedAt: now,
            targetBinding: target,
            runtimeSelection: runtimeSelection,
            queueAutoAdvancePaused: !queueAutoAdvanceEnabled,
            memoryScope: memoryScope
        )
        return ConversationSessionState(session: session, lastAppliedSequence: 0)
    }

    private static func targetBinding(for context: AITerminalContext) -> TargetBinding {
        let material = [
            context.historyScopeID,
            context.title,
            context.currentDirectory ?? ""
        ].joined(separator: "|")
        return TargetBinding(
            id: "target-\(material.djb2Hex())",
            revision: 1,
            digest: material.djb2Hex(),
            connectionID: context.runtimeID,
            connectionKind: context.runtimeID == "local" ? "local" : "terminal",
            remoteIdentity: context.title,
            hostKeyFingerprint: nil,
            host: context.title,
            user: "",
            port: 0,
            targetWorkingDirectory: context.currentDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    /// 本地目标绑定：会话默认绑定到当前主机本地终端（非远程）。
    /// `connectionKind = "local"`、`remoteIdentity` 用稳定本机身份，不使用显示名称。
    /// 远程目标由用户显式切换会话目标时增加 revision（规格 §11.5）。
    private static func localTargetBinding(now: Date) -> TargetBinding {
        let host = currentHost()
        let user = currentUser()
        let bindingID = "local-\(host)-\(user)"
        return TargetBinding(
            id: bindingID,
            revision: 1,
            digest: bindingDigest(host: host, user: user),
            connectionID: "local",
            connectionKind: "local",
            remoteIdentity: "\(user)@\(host)",
            hostKeyFingerprint: nil,
            host: host,
            user: user,
            port: 0,
            targetWorkingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    private static func currentHost() -> String {
        Host.current().localizedName ?? "localhost"
    }

    private static func currentUser() -> String {
        NSUserName()
    }

    /// 稳定 digest（非安全用途；仅用于 TargetBinding 变更检测与审计）。
    private static func bindingDigest(host: String, user: String) -> String {
        let raw = "\(user)@\(host)|local"
        // 简单稳定摘要：不引入 CryptoKit 仅为此用途；变更检测只需确定性
        return raw.djb2Hex()
    }
}

private extension String {
    /// djb2 非加密哈希 → 十六进制（确定性，无依赖）。
    func djb2Hex() -> String {
        var hash: UInt64 = 5381
        for byte in utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}
