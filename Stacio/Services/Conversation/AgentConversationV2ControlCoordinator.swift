import Foundation

// MARK: - 结构化错误（Rust ConversationV2Error Debug 文本 → Swift 枚举）

public enum V2ControlError: Error, Equatable {
    case staleGeneration(expected: Int64, current: Int64)
    case invalidTransition(from: String, to: String)
    case invalidSettlement(permitID: String, detail: String)
    case preparedRequiresAbortDecision(permitID: String)
    case partialCommitBlocksDisabled(detail: String)
    case authorizationClosed(state: String)
    case evidenceTooWeak(effectID: String, required: String)
    case notFound(id: String)
    case storage(String)

    /// 从 Rust 侧 `ConversationV2Error` 的 Debug 文本解析结构化错误。
    /// UniFFI 包装为 `Message(message: "StaleGeneration { ... }")`，先剥离外层包装。
    public static func parse(_ message: String) -> V2ControlError {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrapperPrefix = "Message(message: \""
        if text.hasPrefix(wrapperPrefix), text.hasSuffix("\")") {
            text = String(text.dropFirst(wrapperPrefix.count).dropLast(2))
        }
        text = text.replacingOccurrences(of: "\\\"", with: "\"")
        if text.hasPrefix("StaleGeneration") {
            return .staleGeneration(expected: intField(text, "expected"), current: intField(text, "current"))
        }
        if text.hasPrefix("InvalidTransition") {
            return .invalidTransition(from: stringField(text, "from"), to: stringField(text, "to"))
        }
        if text.hasPrefix("InvalidSettlement") {
            return .invalidSettlement(permitID: stringField(text, "permit_id"), detail: stringField(text, "detail"))
        }
        if text.hasPrefix("PreparedRequiresAbortDecision") {
            return .preparedRequiresAbortDecision(permitID: stringField(text, "permit_id"))
        }
        if text.hasPrefix("PartialCommitBlocksDisabled") {
            return .partialCommitBlocksDisabled(detail: stringField(text, "detail"))
        }
        if text.hasPrefix("AuthorizationClosed") {
            return .authorizationClosed(state: stringField(text, "state"))
        }
        if text.hasPrefix("EvidenceTooWeak") {
            return .evidenceTooWeak(effectID: stringField(text, "effect_id"), required: stringField(text, "required"))
        }
        if text.hasPrefix("NotFound") {
            return .notFound(id: stringField(text, "id"))
        }
        return .storage(text)
    }

    private static func intField(_ text: String, _ name: String) -> Int64 {
        let pattern = "\(name):\\s*(-?\\d+)"
        let nsText = text as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1
        else { return -1 }
        return Int64(nsText.substring(with: match.range(at: 1))) ?? -1
    }

    private static func stringField(_ text: String, _ name: String) -> String {
        let pattern = "\(name):\\s*\"([^\"]*)\""
        let nsText = text as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1
        else { return "" }
        return nsText.substring(with: match.range(at: 1))
    }
}

// MARK: - 控制面协调器（唯一写入者：单 Actor 队列内调用）

/// `agentConversationV2` 三态控制面协调器：Swift facade → CoreBridge control* → Rust 控制面独立库。
/// 控制面的每个 transition 都持久化（generation CAS + transition ID 幂等），
/// 崩溃恢复后从 Rust 库重建权威状态。
public final class AgentConversationV2ControlCoordinator {
    let handle: UInt64

    public init(databasePath: String) throws {
        handle = try CoreBridge.controlOpen(path: databasePath)
    }

    deinit {
        CoreBridge.controlClose(handle: handle)
    }

    public func controlState() throws -> AgentConversationV2ControlState {
        let raw = try CoreBridge.controlState(handle: handle)
        guard let state = AgentConversationV2ControlState(rawValue: raw) else {
            throw V2ControlError.storage("unknown control state: \(raw)")
        }
        return state
    }

    /// CAS 三态迁移。`expectedGeneration` 必须等于当前代际；同 `transitionID` 幂等重放。
    public func transition(to state: AgentConversationV2ControlState, expectedGeneration: Int64, transitionID: String) throws {
        do {
            try CoreBridge.controlTransition(
                handle: handle, to: state.rawValue,
                expectedGeneration: expectedGeneration, transitionId: transitionID
            )
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    /// 仅 enabled 可创建新 authorization；draining/disabled 只允许既有工作走结算 API。
    public func authorizationAllowed() throws -> Bool {
        do {
            return try CoreBridge.controlAuthorizationAllowed(handle: handle)
        } catch {
            throw V2ControlError.parse("\(error)")
        }
    }

    /// Scheduler admission gate：与 Control 同事务域——旗标权威状态是 Rust 控制面库
    /// （`AgentConversationV2ControlState`，不是 UI 布尔值）。gate 只在 disabled 关闭
    /// （draining 允许存量结算，但禁止新 admission）。
    public func admissionGateAllowsNewExecution() throws -> V2AdmissionGate {
        let allowed = try authorizationAllowed()
        return allowed ? .open : .closed
    }
}
