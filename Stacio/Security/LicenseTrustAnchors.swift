import Foundation

/// Public verification material shared by every Stacio client build.
///
/// Private signing and encryption keys never ship in the client. These values
/// are only trust anchors used to verify server-issued authorization data.
public enum LicenseTrustAnchors {
    public static let productID = "stacio"
    public static let apiBaseURL = "https://ops.stacio.cn"

    public static let onlineSignatureKeyID = "online-license-signing-2026-01"
    public static let onlinePublicKeyBase64 = "vDKaOq0LGT5s3km7DzuPXxjmJPOnGrXbGRBDrlQ/Glg="

    public static let offlineExchangeURL = "https://ops.stacio.cn/api/v1/public/products/stacio/offline-license/exchange"
    public static let offlineRequestKeyID = "offline-encryption-2026-01"
    public static let offlineExchangePublicKeyBase64 = "EKuNUsbkqkkRJ3B5Q69RQ2UWdjirgMyMKxfB9KO0fFQ="
    public static let offlineSignatureKeyID = "offline-signing-2026-01"
    public static let offlineAuthorizationPublicKeyBase64 = "yGh4lpWhGxrhjFKGBjtNGy1+trm9yOOxwF3+LUmzbWc="

    public static let storageContractID = "stacio-license-vault-v1"
    public static let storageSchemaVersion = 1
}
