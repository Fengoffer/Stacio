import CryptoKit
import XCTest
import Foundation
@testable import StacioApp

/// P3-5：ConversationEncryption（canonical AAD sealed box）。
///
/// 合同：
/// - V2 master key 可经 Keychain provider 提供；
/// - HKDF 以 conversation ID + schema generation 派生会话密钥；
/// - 每条敏感记录独立 nonce + AES-GCM sealed box；
/// - canonical AAD = record type + ID + candidate sequence + schema version（不接受调用方另传任意 AAD）；
/// - 提交前本地 sealed-box 验证（tag/AAD 失败不提交）；
/// - Loader 每次解密再验证（失败进入只读损坏隔离，不视为缺失 payload、不自动重加密覆盖）。
final class ConversationEncryptionTests: XCTestCase {

    private func makeEncryption() -> ConversationEncryption {
        let masterKeyData = Data((0..<32).map { UInt8($0) }) // 确定性测试密钥
        return ConversationEncryption(masterKeyData: masterKeyData)
    }

    // MARK: - 主密钥

    func testMasterKeyProviderAvailable() throws {
        // 真实 Keychain provider 类型存在且可构造（读取/生成主密钥由 Keychain 承载）
        _ = KeychainConversationMasterKeyProvider.self
        let encryption = try ConversationEncryption(masterKeyProvider: InMemoryMasterKeyProvider())
        XCTAssertNotNil(encryption)
    }

    // MARK: - HKDF 会话密钥

    func testSessionKeyDerivedFromConversationAndGeneration() {
        let encryption = makeEncryption()
        let keyA1 = encryption.sessionKey(conversationID: "c-1", schemaGeneration: 1)
        let keyA1Again = encryption.sessionKey(conversationID: "c-1", schemaGeneration: 1)
        let keyA2 = encryption.sessionKey(conversationID: "c-1", schemaGeneration: 2)
        let keyB1 = encryption.sessionKey(conversationID: "c-2", schemaGeneration: 1)

        XCTAssertEqual(keyA1.withUnsafeBytes { Data($0) }, keyA1Again.withUnsafeBytes { Data($0) }, "同 conversation+generation 派生相同密钥")
        XCTAssertNotEqual(keyA1.withUnsafeBytes { Data($0) }, keyA2.withUnsafeBytes { Data($0) }, "schema generation 变化必须派生不同密钥")
        XCTAssertNotEqual(keyA1.withUnsafeBytes { Data($0) }, keyB1.withUnsafeBytes { Data($0) }, "conversation 变化必须派生不同密钥")
    }

    // MARK: - seal / open round trip

    func testSealOpenRoundTrip() throws {
        let encryption = makeEncryption()
        let payload = Data("敏感负载".utf8)
        let box = try encryption.seal(
            payload: payload, conversationID: "c-1",
            recordType: "conversationEvent", recordID: "ev-1",
            candidateSequence: 5, schemaVersion: 1
        )
        XCTAssertEqual(box.cipherVersion, "stacio.aes-256-gcm.v1")
        XCTAssertFalse(box.ciphertext.isEmpty)
        XCTAssertEqual(box.nonce.count, 12, "AES-GCM nonce 12 字节")

        let opened = try encryption.open(
            box, conversationID: "c-1",
            recordType: "conversationEvent", recordID: "ev-1",
            candidateSequence: 5, schemaVersion: 1
        )
        XCTAssertEqual(opened, payload, "seal → open 还原原文")
    }

    // MARK: - canonical AAD 不接受调用方另传

    func testCanonicalAADIsFixedAndRejectsForeignAAD() throws {
        let encryption = makeEncryption()
        let payload = Data("hello".utf8)
        let box = try encryption.seal(
            payload: payload, conversationID: "c-1",
            recordType: "conversationEvent", recordID: "ev-1",
            candidateSequence: 5, schemaVersion: 1
        )
        // 用错误 AAD 参数打开（调用方无法另传任意 AAD——AAD 由记录字段固定派生）
        XCTAssertThrowsError(try encryption.open(
            box, conversationID: "c-1",
            recordType: "conversationEvent", recordID: "ev-1",
            candidateSequence: 6, schemaVersion: 1
        ), "candidateSequence 变化（AAD 变化）必须打开失败")
        XCTAssertThrowsError(try encryption.open(
            box, conversationID: "c-1",
            recordType: "conversationEvent", recordID: "ev-OTHER",
            candidateSequence: 5, schemaVersion: 1
        ), "recordID 变化（AAD 变化）必须打开失败")
    }

    // MARK: - 提交前本地验证

    func testVerificationDetectsTampering() throws {
        let encryption = makeEncryption()
        let payload = Data("secret".utf8)
        let box = try encryption.seal(
            payload: payload, conversationID: "c-1",
            recordType: "conversationEvent", recordID: "ev-1",
            candidateSequence: 5, schemaVersion: 1
        )
        // 篡改密文
        var tampered = box
        tampered.ciphertext = Data(box.ciphertext.map { $0 ^ 0xFF })
        XCTAssertFalse(
            encryption.verifySealedBox(
                tampered, conversationID: "c-1",
                recordType: "conversationEvent", recordID: "ev-1",
                candidateSequence: 5, schemaVersion: 1
            ),
            "篡改密文必须验证失败（不提交）"
        )
        // 篡改 tag
        var tamperedTag = box
        tamperedTag.tag = Data(repeating: 0x00, count: box.tag.count)
        XCTAssertFalse(
            encryption.verifySealedBox(
                tamperedTag, conversationID: "c-1",
                recordType: "conversationEvent", recordID: "ev-1",
                candidateSequence: 5, schemaVersion: 1
            )
        )
        // 未篡改 → 验证通过（可提交）
        XCTAssertTrue(
            encryption.verifySealedBox(
                box, conversationID: "c-1",
                recordType: "conversationEvent", recordID: "ev-1",
                candidateSequence: 5, schemaVersion: 1
            )
        )
    }

    // MARK: - Loader 损坏隔离

    func testOpenFailureIsIsolationNotMissingPayload() throws {
        let encryption = makeEncryption()
        let payload = Data("仅此一份".utf8)
        let box = try encryption.seal(
            payload: payload, conversationID: "c-1",
            recordType: "conversationEvent", recordID: "ev-1",
            candidateSequence: 5, schemaVersion: 1
        )
        var corrupted = box
        corrupted.ciphertext = Data(repeating: 0xAA, count: box.ciphertext.count)

        XCTAssertThrowsError(try encryption.open(
            corrupted, conversationID: "c-1",
            recordType: "conversationEvent", recordID: "ev-1",
            candidateSequence: 5, schemaVersion: 1
        )) { error in
            XCTAssertEqual(error as? ConversationEncryptionError, .authenticationFailed)
        }
    }

    func testDistinctNoncePerRecord() throws {
        // 每条敏感记录独立 nonce（同 payload 两次 seal 产生不同 nonce）
        let encryption = makeEncryption()
        let payload = Data("same".utf8)
        let box1 = try encryption.seal(
            payload: payload, conversationID: "c-1",
            recordType: "conversationEvent", recordID: "ev-1",
            candidateSequence: 5, schemaVersion: 1
        )
        let box2 = try encryption.seal(
            payload: payload, conversationID: "c-1",
            recordType: "conversationEvent", recordID: "ev-1",
            candidateSequence: 5, schemaVersion: 1
        )
        XCTAssertNotEqual(box1.nonce, box2.nonce, "每条记录必须独立 nonce")
    }
}

/// 测试用 in-memory 主密钥 provider（不触碰真实 Keychain）。
private final class InMemoryMasterKeyProvider: ConversationMasterKeyProviding {
    func masterKeyData() throws -> Data {
        Data((0..<32).map { UInt8($0) })
    }
}
