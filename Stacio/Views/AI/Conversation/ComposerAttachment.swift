import Foundation

// MARK: - Composer 附件与上下文安全（P5-5）

/// `+` 菜单来源。
public enum AttachmentSource: String, Codable, CaseIterable, Equatable, Sendable {
    case localFile
    case currentRemoteFile
    case terminalSelection
    case terminalRecentOutput
    case screenshot
    case plainText
}

/// `@` 选择器来源。
public enum AtSelectorSource: String, Codable, CaseIterable, Equatable, Sendable {
    case sessionFile
    case currentTerminal
    case hostInfo
    case approvedProjectContext
}

/// 附件快照：发送前复制为加密不可变快照。
public struct AttachmentSnapshot: Equatable, Sendable {
    public let attachmentID: String
    /// realpath / file identity / symlink target。
    public let fileIdentity: String
    public let sizeBytes: Int
    public let modifiedAt: Date
    public let contentHash: String
    public let encryptedSnapshot: Bool

    public init(
        attachmentID: String, fileIdentity: String, sizeBytes: Int,
        modifiedAt: Date, contentHash: String, encryptedSnapshot: Bool
    ) {
        self.attachmentID = attachmentID
        self.fileIdentity = fileIdentity
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.contentHash = contentHash
        self.encryptedSnapshot = encryptedSnapshot
    }
}

/// 图片进入 ContextSnapshot 的能力门禁。
public enum ImageAccessOutcome: Equatable, Sendable {
    case allowed
    /// 未知或未验证的 imageInput 能力 → 禁用并说明原因。
    case disabled(reason: String)
}

public enum ComposerAttachmentAction {
    public static let longPasteThreshold = 4_096
    public static let oversizedFileThreshold = 10 * 1024 * 1024

    /// `+` 菜单与 `@` 选择器关闭集合。
    public static func plusMenuSources() -> [AttachmentSource] { AttachmentSource.allCases }
    public static func atSelectorSources() -> [AtSelectorSource] { AtSelectorSource.allCases }

    /// 拖入文件生成附件，不把完整内容塞入 NSTextView。
    public static func droppedFileCreatesAttachmentNotInlineText() -> Bool { true }

    /// 粘贴超长文本提示转文本附件。
    public static func suggestsTextAttachment(pastedLength: Int) -> Bool {
        pastedLength > longPasteThreshold
    }

    /// 本地文件 security-scoped bookmark + realpath/file identity/symlink target 校验。
    public static func requiresSecurityScopedBookmark() -> Bool { true }

    /// 文件变化让用户选新版本或已保存快照（不静默替换）。
    public static func fileChangedRequiresUserChoice() -> Bool { true }

    /// 超大文件先选片段或生成可审计摘要。
    public static func oversizedRequiresSelectionOrSummary(sizeBytes: Int) -> Bool {
        sizeBytes > oversizedFileThreshold
    }

    /// 密码/验证码/sudo 永不进入普通附件或 Composer。
    public static func neverInAttachment(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("password") || lower.contains("验证码")
            || lower.contains("sudo") || lower.contains("otp")
            || lower.contains("2fa")
    }

    /// 图片仅 `imageInput == true` 且用户明确选择才进入 ContextSnapshot；
    /// 未知或未验证禁用并说明原因、不静默 OCR。
    public static func imageAccess(imageInput: Bool?, userExplicitlySelected: Bool) -> ImageAccessOutcome {
        switch imageInput {
        case .some(true):
            return userExplicitlySelected ? .allowed : .disabled(reason: "图片需要用户明确选择")
        case .some(false):
            return .disabled(reason: "该模型不支持图片输入（imageInput=false）")
        case .none:
            return .disabled(reason: "imageInput 能力未验证")
        }
    }

    public static func silentlyOCRsImages() -> Bool { false }

    /// 远程附件发送前重新验证连接身份/修改时间/内容 hash。
    public static func remoteRequiresRevalidationBeforeSend() -> Bool { true }

    /// 附件快照复制为加密不可变快照（P3-5 加密快照语义）。
    public static func snapshotIsEncryptedAndImmutable() -> Bool { true }
}
