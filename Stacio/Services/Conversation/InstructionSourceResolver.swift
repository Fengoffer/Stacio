import CryptoKit
import Foundation

// MARK: - 指令层级（§11.1：前两层不可覆盖；后三层非安全偏好冲突时更具体的后一级胜出）

public enum InstructionLayer: Int, Codable, CaseIterable, Equatable, Sendable {
    case appManagedSafetyFloor = 1  // App/管理员强制安全下限（不可覆盖）
    case operationalContract = 2    // Stacio 只读 Operational Contract（不可覆盖）
    case userGlobal = 3             // 用户全局指令
    case projectTargetRules = 4     // 当前项目与目标身份匹配且用户允许的规则文件
    case turnExplicit = 5           // 当前 Turn 明确请求

    public var isProtected: Bool {
        self == .appManagedSafetyFloor || self == .operationalContract
    }
}

// MARK: - 指令来源种类（可信度）

public enum InstructionSourceKind: String, Codable, CaseIterable, Equatable, Sendable {
    case trustedLocal          // 本地用户允许的规则文件 / 全局指令
    case untrustedRemoteFile   // 远程文件（默认不可信）
    case untrustedWebPage      // 网页（默认不可信）
    case untrustedLogOutput    // 日志（默认不可信）
    case untrustedTerminalOutput // 终端输出（默认不可信）

    public var isTrusted: Bool {
        self == .trustedLocal
    }
}

// MARK: - 输入 / 快照

public struct InstructionSourceInput: Equatable, Sendable {
    public var layer: InstructionLayer
    public var sourceID: String
    public var displayName: String
    public var kind: InstructionSourceKind
    public var text: String
    /// 项目规则隔离：仅当与当前 projectIdentity + targetBindingDigest 匹配时纳入
    public var projectIdentity: String?
    public var targetBindingDigest: String?

    public init(
        layer: InstructionLayer,
        sourceID: String,
        displayName: String,
        kind: InstructionSourceKind,
        text: String,
        projectIdentity: String? = nil,
        targetBindingDigest: String? = nil
    ) {
        self.layer = layer
        self.sourceID = sourceID
        self.displayName = displayName
        self.kind = kind
        self.text = text
        self.projectIdentity = projectIdentity
        self.targetBindingDigest = targetBindingDigest
    }
}

public struct InstructionSnapshot: Equatable, Sendable {
    public var sources: [InstructionSource]
    public var digest: String
    public var hashAlgorithm: String
    public var capturedAt: Date

    public init(sources: [InstructionSource], digest: String, hashAlgorithm: String, capturedAt: Date) {
        self.sources = sources
        self.digest = digest
        self.hashAlgorithm = hashAlgorithm
        self.capturedAt = capturedAt
    }
}

public struct InstructionSource: Equatable, Sendable {
    public var layer: InstructionLayer
    public var sourceID: String
    public var displayName: String
    public var contentHash: String
    public var text: String

    public init(layer: InstructionLayer, sourceID: String, displayName: String, contentHash: String, text: String) {
        self.layer = layer
        self.sourceID = sourceID
        self.displayName = displayName
        self.contentHash = contentHash
        self.text = text
    }
}

// MARK: - 不可变边界判定

public enum InstructionImmutabilityVerdict: Equatable, Sendable {
    /// 规则文本只可表达偏好；不能改变受保护边界。
    case cannotMutateProtectedBoundaries(protected: [String])
    case ordinaryPreference
}

// MARK: - InstructionSourceResolver

public enum InstructionSourceResolver {

    /// Attempt 进入 Preparing 前枚举 + 哈希冻结 InstructionSnapshot。
    /// 项目规则按 projectIdentity + targetBindingDigest 隔离；不可信数据全部排除。
    public static func resolve(
        sources: [InstructionSourceInput],
        projectIdentity: String? = nil,
        targetBindingDigest: String? = nil,
        now: Date
    ) -> InstructionSnapshot {
        let trusted = sources.filter { input in
            guard input.kind.isTrusted else { return false }
            if input.layer == .projectTargetRules {
                return input.projectIdentity == projectIdentity && input.targetBindingDigest == targetBindingDigest
            }
            return true
        }
        let merged = merged(sources: trusted)
        let resolved = merged
            .sorted {
                if $0.layer.rawValue != $1.layer.rawValue {
                    return $0.layer.rawValue < $1.layer.rawValue
                }
                if $0.sourceID != $1.sourceID {
                    return $0.sourceID < $1.sourceID
                }
                return $0.displayName < $1.displayName
            }
            .map { input in
                InstructionSource(
                    layer: input.layer,
                    sourceID: input.sourceID,
                    displayName: input.displayName,
                    contentHash: hash(input.text),
                    text: input.text
                )
            }
        let digestMaterial = [
            resolved.map { "\($0.layer.rawValue):\($0.sourceID):\($0.contentHash)" }.joined(separator: ","),
            "capturedAt=\(now.timeIntervalSince1970)"
        ].joined(separator: "|")
        return InstructionSnapshot(
            sources: resolved,
            digest: hash(digestMaterial),
            hashAlgorithm: "sha256-stable",
            capturedAt: now
        )
    }

    /// 层级合并：前两层不可覆盖；后三层非安全偏好冲突时更具体的后一级胜出（标注来源）。
    public static func merged(sources: [InstructionSourceInput]) -> [InstructionSourceInput] {
        var resolvedBySourceID: [String: InstructionSourceInput] = [:]

        // Protected sources always win over an ordinary source with the same ID.
        // If malformed input repeats a protected ID, the strongest (lowest)
        // protected layer wins so later text cannot replace the safety floor.
        for input in sources where input.layer.isProtected {
            guard let existing = resolvedBySourceID[input.sourceID] else {
                resolvedBySourceID[input.sourceID] = input
                continue
            }
            if input.layer.rawValue < existing.layer.rawValue {
                resolvedBySourceID[input.sourceID] = input
            }
        }

        // Ordinary preferences become more specific as the layer number grows.
        // Never let them replace a protected source with the same stable ID.
        for input in sources where input.layer.isProtected == false {
            if resolvedBySourceID[input.sourceID]?.layer.isProtected == true {
                continue
            }
            if let existing = resolvedBySourceID[input.sourceID],
               existing.layer.rawValue > input.layer.rawValue {
                continue
            }
            resolvedBySourceID[input.sourceID] = input
        }
        return Array(resolvedBySourceID.values)
    }

    /// 可信度判定：远程文件/网页/日志/终端输出默认不可信，不能仅因文件名像规则文件升级为指令。
    public static func isTrustedRuleSource(_ kind: InstructionSourceKind) -> Bool {
        kind.isTrusted
    }

    /// 运行中规则变化检测：当前 sources 的 digest 与冻结快照不一致 → 已变化。
    /// 只提示「规则已变化」，不得被同一 Attempt 重新读取后偷偷生效。
    public static func changedSinceSnapshot(
        _ snapshot: InstructionSnapshot,
        current: [InstructionSourceInput],
        projectIdentity: String? = nil,
        targetBindingDigest: String? = nil
    ) -> Bool {
        let currentResolved = resolve(
            sources: current,
            projectIdentity: projectIdentity,
            targetBindingDigest: targetBindingDigest,
            now: snapshot.capturedAt
        )
        return currentResolved.digest != snapshot.digest
    }

    /// 不可变边界判定：任何层级的模型文本或规则文件都不能用文字改变 Policy、
    /// Tool Catalog、lease、credential scope 或管理员下限。
    public static func immutabilityVerdict(for text: String) -> InstructionImmutabilityVerdict {
        let lower = text.lowercased()
        var protected: [String] = []
        let keywords: [(String, String)] = [
            ("policy", "policy"),
            ("tool catalog", "tool catalog"),
            ("lease", "lease"),
            ("credential scope", "credential scope"),
            ("admin", "管理员下限"),
            ("administrator", "管理员下限")
        ]
        for (keyword, label) in keywords where lower.contains(keyword) {
            protected.append(label)
        }
        if protected.isEmpty {
            return .ordinaryPreference
        }
        return .cannotMutateProtectedBoundaries(protected: Array(Set(protected)))
    }

    private static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
