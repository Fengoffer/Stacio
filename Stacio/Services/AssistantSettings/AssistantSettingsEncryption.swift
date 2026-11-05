import CryptoKit
import Foundation

// MARK: - AssistantPreferenceContentKey（P4-2 加密域）

public enum AssistantSettingsEncryptionError: Error, Equatable {
    case invalidMasterKey
    case authenticationFailed
    case cryptoFailure
}

/// 设置值加密域：主密钥 → HKDF 派生 preference 域密钥 → AES-GCM 密封。
/// canonical AAD 绑定域名与 setting id，防止跨域替换。
public enum AssistantPreferenceContentKey {
    public static let domain = "stacio.settings"

    /// 主密钥派生 preference 域密钥（HKDF-SHA256）。
    public static func deriveKey(masterKeyData: Data) -> SymmetricKey {
        let info = Data("stacio.v2|preferenceContentKey|v1".utf8)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKeyData),
            salt: Data(domain.utf8),
            info: info,
            outputByteCount: 32
        )
        return derived
    }

    /// 密封 setting 值：AAD = `stacio.settings|settingID|revision|schema-1`。
    public static func seal(value: Data, settingID: String, revision: Int, masterKeyData: Data) throws -> Data {
        guard !masterKeyData.isEmpty else {
            throw AssistantSettingsEncryptionError.invalidMasterKey
        }
        let key = deriveKey(masterKeyData: masterKeyData)
        let aad = Data("\(domain)|\(settingID)|\(revision)|schema-1".utf8)
        do {
            let box = try AES.GCM.seal(value, using: key, authenticating: aad)
            guard let combined = box.combined else {
                throw AssistantSettingsEncryptionError.cryptoFailure
            }
            return combined
        } catch {
            throw AssistantSettingsEncryptionError.cryptoFailure
        }
    }

    /// 打开密封值：tag/AAD 不匹配 → authenticationFailed（跨域替换被拒）。
    public static func open(sealed: Data, settingID: String, revision: Int, masterKeyData: Data) throws -> Data {
        guard !masterKeyData.isEmpty else {
            throw AssistantSettingsEncryptionError.invalidMasterKey
        }
        let key = deriveKey(masterKeyData: masterKeyData)
        let aad = Data("\(domain)|\(settingID)|\(revision)|schema-1".utf8)
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw AssistantSettingsEncryptionError.authenticationFailed
        }
    }
}
