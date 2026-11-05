import XCTest
import Foundation
@testable import StacioApp

/// P5-5：Composer 附件与上下文安全（来源菜单、拖入/粘贴、快照、能力门禁、敏感内容）。
final class ComposerAttachmentTests: XCTestCase {

    // MARK: - 来源菜单

    func testPlusMenuAndAtSelectorSources() {
        XCTAssertEqual(
            ComposerAttachmentAction.plusMenuSources(),
            [.localFile, .currentRemoteFile, .terminalSelection, .terminalRecentOutput, .screenshot, .plainText]
        )
        XCTAssertEqual(
            ComposerAttachmentAction.atSelectorSources(),
            [.sessionFile, .currentTerminal, .hostInfo, .approvedProjectContext]
        )
    }

    // MARK: - 拖入与粘贴

    func testDroppedFileCreatesAttachmentNotInlineText() {
        XCTAssertTrue(ComposerAttachmentAction.droppedFileCreatesAttachmentNotInlineText(),
                      "拖入文件生成附件不把完整内容塞入 NSTextView")
    }

    func testLongPasteSuggestsTextAttachment() {
        XCTAssertFalse(ComposerAttachmentAction.suggestsTextAttachment(pastedLength: 100))
        XCTAssertTrue(ComposerAttachmentAction.suggestsTextAttachment(pastedLength: 4_097),
                      "粘贴超长文本提示转文本附件")
    }

    // MARK: - 快照与文件变化

    func testLocalFileRequiresSecurityScopedBookmark() {
        XCTAssertTrue(ComposerAttachmentAction.requiresSecurityScopedBookmark(),
                      "本地文件 security-scoped bookmark")
        let snapshot = AttachmentSnapshot(
            attachmentID: "att-1", fileIdentity: "realpath:/Users/mac/x.txt",
            sizeBytes: 2048, modifiedAt: Date(), contentHash: "sha256:abc",
            encryptedSnapshot: true
        )
        XCTAssertEqual(snapshot.fileIdentity, "realpath:/Users/mac/x.txt", "realpath/file identity/symlink target")
        XCTAssertTrue(snapshot.encryptedSnapshot, "发送前复制为加密不可变快照")
        XCTAssertTrue(ComposerAttachmentAction.snapshotIsEncryptedAndImmutable())
    }

    func testFileChangeRequiresUserChoiceNotSilentReplace() {
        XCTAssertTrue(ComposerAttachmentAction.fileChangedRequiresUserChoice(),
                      "文件变化让用户选新版本或已保存快照，不静默替换")
    }

    func testOversizedFileRequiresSelectionOrSummary() {
        XCTAssertFalse(ComposerAttachmentAction.oversizedRequiresSelectionOrSummary(sizeBytes: 1024))
        XCTAssertTrue(
            ComposerAttachmentAction.oversizedRequiresSelectionOrSummary(
                sizeBytes: 10 * 1024 * 1024 + 1
            ),
            "超大文件先选片段或生成可审计摘要"
        )
    }

    // MARK: - 敏感内容

    func testSecretsNeverEnterAttachment() {
        XCTAssertTrue(ComposerAttachmentAction.neverInAttachment("password=abc"))
        XCTAssertTrue(ComposerAttachmentAction.neverInAttachment("验证码 123456"))
        XCTAssertTrue(ComposerAttachmentAction.neverInAttachment("sudo rm -rf"))
        XCTAssertTrue(ComposerAttachmentAction.neverInAttachment("OTP 987654"))
        XCTAssertFalse(ComposerAttachmentAction.neverInAttachment("普通文件内容"))
    }

    // MARK: - 图片能力门禁

    func testImageRequiresVerifiedCapabilityAndExplicitSelection() {
        // imageInput == true + 用户明确选择 → allowed
        XCTAssertEqual(
            ComposerAttachmentAction.imageAccess(imageInput: true, userExplicitlySelected: true),
            .allowed
        )
        // imageInput == true 但未明确选择 → 禁用
        XCTAssertEqual(
            ComposerAttachmentAction.imageAccess(imageInput: true, userExplicitlySelected: false),
            .disabled(reason: "图片需要用户明确选择")
        )
        // imageInput == false → 禁用并说明原因
        XCTAssertEqual(
            ComposerAttachmentAction.imageAccess(imageInput: false, userExplicitlySelected: true),
            .disabled(reason: "该模型不支持图片输入（imageInput=false）")
        )
        // 未知能力 → 禁用（不静默 OCR）
        XCTAssertEqual(
            ComposerAttachmentAction.imageAccess(imageInput: nil, userExplicitlySelected: true),
            .disabled(reason: "imageInput 能力未验证")
        )
        XCTAssertFalse(ComposerAttachmentAction.silentlyOCRsImages(), "不静默 OCR")
    }

    // MARK: - 远程附件

    func testRemoteRequiresRevalidationBeforeSend() {
        XCTAssertTrue(ComposerAttachmentAction.remoteRequiresRevalidationBeforeSend(),
                      "远程附件发送前重新验证连接身份/修改时间/内容 hash")
    }
}
