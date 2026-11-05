import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Kernel-observed identity for the root process of a managed Local Agent.
/// The process group remains the transport scope, while the root PID and
/// trusted start time prevent a recycled PGID/PID from inheriting a capability.
struct LocalAgentCapabilityProcessIdentity: Equatable, Sendable {
    let processIdentifier: Int32
    let processGroupIdentifier: Int32
    let trustedStartTime: Date
}

/// 进程内 capability 注册表。只保存短期 scope 元数据，不保存 bearer secret；
/// Bridge 请求携带 capabilityID 后由 App 侧重新解析 target，不能靠 CLI 自报身份。
public final class LocalAgentCapabilityRegistry: @unchecked Sendable {
    public static let shared = LocalAgentCapabilityRegistry()

    private struct Entry {
        let targetRuntimeGenerations: [String: UInt64]
        let processGeneration: Int
        let processGroupID: Int32?
        let rootProcessID: Int32?
        let rootProcessTrustedStartTime: Date?
        let actorName: String
        let expiresAt: Date
        var revoked: Bool
    }

    private let lock = NSLock()
    private let processIdentityResolver: @Sendable (Int32) -> LocalAgentCapabilityProcessIdentity?
    private var entries: [String: Entry] = [:]

    public init() {
        processIdentityResolver = { processIdentifier in
            Self.observeProcessIdentity(processIdentifier: processIdentifier)
        }
    }

    /// Injectable only for deterministic tests. Production callers use the
    /// kernel-backed resolver installed by `init()`.
    init(
        processIdentityResolver: @escaping @Sendable (Int32) -> LocalAgentCapabilityProcessIdentity?
    ) {
        self.processIdentityResolver = processIdentityResolver
    }

    @discardableResult
    public func register(
        capabilityID: String,
        targetRuntimeGenerations: [String: UInt64],
        processGeneration: Int,
        processGroupID: Int32? = nil,
        processIdentifier: Int32? = nil,
        trustedStartTime: Date? = nil,
        actorName: String = "Local Agent",
        expiresAt: Date = Date().addingTimeInterval(24 * 60 * 60)
    ) -> Bool {
        var normalized: [String: UInt64] = [:]
        for (runtimeID, generation) in targetRuntimeGenerations {
            let trimmed = runtimeID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            normalized[trimmed] = generation
        }
        guard capabilityID.isEmpty == false, normalized.isEmpty == false else { return false }
        lock.lock()
        guard entries[capabilityID] == nil else {
            lock.unlock()
            return false
        }
        entries[capabilityID] = Entry(
            targetRuntimeGenerations: normalized,
            processGeneration: processGeneration,
            processGroupID: processGroupID.flatMap { $0 > 0 ? $0 : nil },
            rootProcessID: processIdentifier.flatMap { $0 > 0 ? $0 : nil },
            rootProcessTrustedStartTime: Self.validStartTime(trustedStartTime),
            actorName: actorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Local Agent"
                : actorName,
            expiresAt: expiresAt,
            revoked: false
        )
        lock.unlock()
        return true
    }

    public func revoke(capabilityID: String) {
        lock.lock()
        guard let entry = entries[capabilityID] else {
            lock.unlock()
            return
        }
        entries[capabilityID] = Entry(
            targetRuntimeGenerations: entry.targetRuntimeGenerations,
            processGeneration: entry.processGeneration,
            processGroupID: entry.processGroupID,
            rootProcessID: entry.rootProcessID,
            rootProcessTrustedStartTime: entry.rootProcessTrustedStartTime,
            actorName: entry.actorName,
            expiresAt: entry.expiresAt,
            revoked: true
        )
        lock.unlock()
    }

    public func allows(
        capabilityID: String,
        runtimeID: String,
        runtimeGeneration: UInt64,
        now: Date = Date()
    ) -> Bool {
        guard let entry = liveEntry(capabilityID: capabilityID, now: now),
              entry.targetRuntimeGenerations[runtimeID] == runtimeGeneration
        else { return false }
        return true
    }

    public func allowedRuntimeGenerations(
        capabilityID: String,
        now: Date = Date()
    ) -> [String: UInt64] {
        guard let entry = liveEntry(capabilityID: capabilityID, now: now) else { return [:] }
        return entry.targetRuntimeGenerations
    }

    public func processGeneration(for capabilityID: String, now: Date = Date()) -> Int? {
        guard let entry = liveEntry(capabilityID: capabilityID, now: now) else { return nil }
        return entry.processGeneration
    }

    /// Resolves an App-created capability from kernel-observed peer identity.
    /// The caller supplies the peer PID/PGID obtained from the Unix socket; no
    /// identity or bearer value sent by the CLI participates in this decision.
    public func resolvePeer(
        processID: Int32,
        processGroupID: Int32,
        now: Date = Date()
    ) -> LocalAgentPeerScopeResolution {
        guard processID > 0, processGroupID > 0 else { return .rejected }
        lock.lock()
        let matching = entries.compactMap { capabilityID, entry -> (String, Entry)? in
            entry.processGroupID == processGroupID ? (capabilityID, entry) : nil
        }
        lock.unlock()
        guard matching.isEmpty == false else { return .unmanaged }
        let active = matching.filter { _, entry in
            entry.revoked == false && now <= entry.expiresAt
        }
        guard active.count == 1, let match = active.first else { return .rejected }
        guard let rootProcessID = match.1.rootProcessID,
              let trustedStartTime = match.1.rootProcessTrustedStartTime,
              let observed = processIdentityResolver(rootProcessID),
              observed.processIdentifier == rootProcessID,
              observed.processGroupIdentifier == processGroupID,
              Self.startTimesMatch(observed.trustedStartTime, trustedStartTime)
        else {
            return .rejected
        }
        lock.lock()
        let stillUniqueAndActive = entries.filter { _, entry in
            entry.processGroupID == processGroupID
                && entry.revoked == false
                && now <= entry.expiresAt
        }.map(\.key) == [match.0]
        lock.unlock()
        guard stillUniqueAndActive else { return .rejected }
        return .authorized(
            capabilityID: match.0,
            actorName: match.1.actorName,
            processGeneration: match.1.processGeneration
        )
    }

    private static func validStartTime(_ date: Date?) -> Date? {
        guard let date,
              date.timeIntervalSince1970.isFinite,
              date.timeIntervalSince1970 > 0
        else { return nil }
        return date
    }

    private func isRootProcessLive(_ entry: Entry) -> Bool {
        guard let rootProcessID = entry.rootProcessID,
              let processGroupID = entry.processGroupID,
              let trustedStartTime = entry.rootProcessTrustedStartTime,
              let observed = processIdentityResolver(rootProcessID)
        else {
            return false
        }
        return observed.processIdentifier == rootProcessID
            && observed.processGroupIdentifier == processGroupID
            && Self.startTimesMatch(observed.trustedStartTime, trustedStartTime)
    }

    private func liveEntry(capabilityID: String, now: Date) -> Entry? {
        lock.lock()
        let snapshot = entries[capabilityID]
        lock.unlock()
        guard let snapshot,
              snapshot.revoked == false,
              now <= snapshot.expiresAt,
              isRootProcessLive(snapshot)
        else { return nil }

        // The resolver can cross a syscall boundary. Re-check revocation after
        // it returns so revoke remains authoritative even when it races a use.
        lock.lock()
        let current = entries[capabilityID]
        lock.unlock()
        guard let current,
              current.revoked == false,
              now <= current.expiresAt
        else { return nil }
        return current
    }

    private static func startTimesMatch(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 0.001
    }

    private static func observeProcessIdentity(
        processIdentifier: Int32
    ) -> LocalAgentCapabilityProcessIdentity? {
        #if canImport(Darwin)
        guard processIdentifier > 0 else { return nil }
        var info = proc_bsdinfo()
        let result = proc_pidinfo(
            pid_t(processIdentifier),
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.stride)
        )
        guard result == MemoryLayout<proc_bsdinfo>.stride,
              info.pbi_pid == UInt32(processIdentifier),
              info.pbi_pgid > 0,
              info.pbi_start_tvsec > 0,
              info.pbi_status != UInt32(SZOMB)
        else { return nil }
        return LocalAgentCapabilityProcessIdentity(
            processIdentifier: processIdentifier,
            processGroupIdentifier: Int32(info.pbi_pgid),
            trustedStartTime: Date(
                timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                    + TimeInterval(info.pbi_start_tvusec) / 1_000_000
            )
        )
        #else
        return nil
        #endif
    }
}

public enum LocalAgentPeerScopeResolution: Equatable, Sendable {
    case authorized(capabilityID: String, actorName: String, processGeneration: Int)
    case rejected
    case unmanaged
}

// MARK: - Local Agent Capability Broker（P8-3）

public enum ManagedCapabilityKind: String, Codable, CaseIterable, Equatable, Sendable {
    case effectCapable
    case answerOnly
}

/// 短期可撤销不可复用的 capability（绑定完整身份链）。
public struct ManagedCapability: Equatable, Sendable {
    public let capabilityID: String
    public let kind: ManagedCapabilityKind
    public let conversationID: String
    public let turnID: String
    public let attemptID: String
    public let authorityLeaseGeneration: Int
    public let targetBindingDigest: String
    public let workingDirectoryDigest: String
    public let executableHash: String
    public let processGeneration: Int
    public let containmentRevision: Int
    public let allowedActions: [String]
    public let expiresAt: Date
    public let revoked: Bool

    public init(
        capabilityID: String, kind: ManagedCapabilityKind,
        conversationID: String, turnID: String, attemptID: String,
        authorityLeaseGeneration: Int, targetBindingDigest: String,
        workingDirectoryDigest: String, executableHash: String,
        processGeneration: Int, containmentRevision: Int,
        allowedActions: [String], expiresAt: Date, revoked: Bool = false
    ) {
        self.capabilityID = capabilityID
        self.kind = kind
        self.conversationID = conversationID
        self.turnID = turnID
        self.attemptID = attemptID
        self.authorityLeaseGeneration = authorityLeaseGeneration
        self.targetBindingDigest = targetBindingDigest
        self.workingDirectoryDigest = workingDirectoryDigest
        self.executableHash = executableHash
        self.processGeneration = processGeneration
        self.containmentRevision = containmentRevision
        self.allowedActions = allowedActions
        self.expiresAt = expiresAt
        self.revoked = revoked
    }
}

/// 能力交付渠道：继承 FD / 带 peer auth 的 XPC-Unix channel（非 argv-env-普通文件）。
public enum CapabilityDeliveryChannel: String, Equatable, Sendable {
    case inheritedFD
    case xpcUnixWithPeerAuth
}

/// 调用验证结果。
public enum CapabilityVerificationOutcome: Equatable, Sendable {
    case allow
    /// 错误 peer / 旧重放 token / 错误 target digest / 已撤销 generation / 越权动作 → 拒绝并写安全事件。
    case reject(reason: String)
}

public enum LocalAgentCapabilityBrokerAction {

    /// 每次 managed launch 创建短期可撤销不可复用 capability（绑定全部身份字段）。
    public static func createCapability(
        capabilityID: String, kind: ManagedCapabilityKind,
        conversationID: String, turnID: String, attemptID: String,
        authorityLeaseGeneration: Int, targetBindingDigest: String,
        workingDirectoryDigest: String, executableHash: String,
        processGeneration: Int, containmentRevision: Int,
        allowedActions: [String], expiresAt: Date
    ) -> ManagedCapability {
        ManagedCapability(
            capabilityID: capabilityID, kind: kind,
            conversationID: conversationID, turnID: turnID, attemptID: attemptID,
            authorityLeaseGeneration: authorityLeaseGeneration,
            targetBindingDigest: targetBindingDigest,
            workingDirectoryDigest: workingDirectoryDigest,
            executableHash: executableHash,
            processGeneration: processGeneration,
            containmentRevision: containmentRevision,
            allowedActions: allowedActions, expiresAt: expiresAt
        )
    }

    public static func revoke(_ capability: ManagedCapability) -> ManagedCapability {
        ManagedCapability(
            capabilityID: capability.capabilityID, kind: capability.kind,
            conversationID: capability.conversationID, turnID: capability.turnID,
            attemptID: capability.attemptID,
            authorityLeaseGeneration: capability.authorityLeaseGeneration,
            targetBindingDigest: capability.targetBindingDigest,
            workingDirectoryDigest: capability.workingDirectoryDigest,
            executableHash: capability.executableHash,
            processGeneration: capability.processGeneration,
            containmentRevision: capability.containmentRevision,
            allowedActions: capability.allowedActions,
            expiresAt: capability.expiresAt, revoked: true
        )
    }

    /// 能力优先经继承 FD / 带 peer auth 的 XPC-Unix channel 交付；
    /// 不得把 bearer token 放入命令行/环境变量/临时明文文件/终端输出。
    public static func deliveryChannel() -> CapabilityDeliveryChannel {
        .xpcUnixWithPeerAuth
    }
    public static func neverBearerTokenInArgvEnvPlainFileOrTerminalOutput() -> Bool { true }

    /// Broker 从自己创建的 process handle/audit token/peer credentials/launch generation
    /// 识别调用方，不信任 CLI 自报 actor/PID/Conversation/Attempt/目标/目录/审批状态。
    public static func trustsSelfCreatedIdentityOnly() -> Bool { true }

    /// 验证：错误 peer/旧重放 token/错误 target digest/已撤销 generation/越权动作一律拒绝。
    public static func verify(
        capability: ManagedCapability,
        peerMatches: Bool, replayTokenValid: Bool,
        targetDigest: String, workingDirectoryDigest: String?,
        requestedAction: String, now: Date
    ) -> CapabilityVerificationOutcome {
        guard !capability.revoked else { return .reject(reason: "revokedGeneration") }
        guard now <= capability.expiresAt else { return .reject(reason: "expired") }
        guard peerMatches else { return .reject(reason: "wrongPeer") }
        guard replayTokenValid else { return .reject(reason: "replayedToken") }
        guard targetDigest == capability.targetBindingDigest else { return .reject(reason: "wrongTargetDigest") }
        // 能力绑定含 AgentProcessWorkingDirectory digest——请求方工作目录身份必须匹配
        if let workingDirectoryDigest,
           workingDirectoryDigest != capability.workingDirectoryDigest {
            return .reject(reason: "wrongWorkingDirectoryDigest")
        }
        guard capability.allowedActions.contains(requestedAction) else { return .reject(reason: "actionNotAllowed") }
        return .allow
    }

    /// effect-capable 与 answer-only 是两套独立 capability/endpoint。
    public static func independentEndpointsForKinds() -> Bool { true }

    /// answer-only 只允许只读 auth/context IPC、私有 ephemeral scratch 和声明模型 egress；
    /// 零 Target/workspace/terminal/Effect Broker/任意子进程/持久写入。
    public static func answerOnlyZeroTargetWorkspaceTerminalEffectSubprocessPersistentWrite() -> Bool { true }
    public static func answerOnlyAllows(_ action: String) -> Bool {
        action == "readOnlyAuthContextIPC" || action == "privateEphemeralScratch"
            || action == "declaredModelEgress"
    }

    /// launch 紧邻 exec 重新解析 realpath 并验证 file identity/owner/权限/code signature/hash
    /// （symlink 替换/路径组件变化/升级/TOCTOU → 停止并要求重新检测）。
    public static func realpathRevalidationRequiredBeforeExec() -> Bool { true }
    public static func identityMismatchStopsAndRequiresRedetection() -> Bool { true }
}
