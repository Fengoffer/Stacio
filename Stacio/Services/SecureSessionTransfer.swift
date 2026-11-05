import AppKit
import CommonCrypto
import CryptoKit
import Foundation
import Security
import StacioCoreBindings

public enum SecureSessionTransferError: Error, Equatable, LocalizedError {
    case emptyPassphrase
    case invalidEnvelope
    case unsupportedFormat
    case invalidCipherData
    case decryptionFailed
    case invalidPayload
    case credentialUnavailable
    case unsupportedCredentialKind
    case privateKeyUnavailable
    case privateKeyInstallFailed
    case keyDerivationFailed

    public var errorDescription: String? {
        switch self {
        case .emptyPassphrase:
            return L10n.SecureSessionTransfer.emptyPassphrase
        case .invalidEnvelope:
            return L10n.SecureSessionTransfer.invalidEnvelope
        case .unsupportedFormat:
            return L10n.SecureSessionTransfer.unsupportedFormat
        case .invalidCipherData, .decryptionFailed:
            return L10n.SecureSessionTransfer.decryptionFailed
        case .invalidPayload:
            return L10n.SecureSessionTransfer.invalidPayload
        case .credentialUnavailable:
            return L10n.SecureSessionTransfer.credentialUnavailable
        case .unsupportedCredentialKind:
            return L10n.SecureSessionTransfer.unsupportedCredentialKind
        case .privateKeyUnavailable:
            return L10n.SecureSessionTransfer.privateKeyUnavailable
        case .privateKeyInstallFailed:
            return L10n.SecureSessionTransfer.privateKeyInstallFailed
        case .keyDerivationFailed:
            return L10n.SecureSessionTransfer.keyDerivationFailed
        }
    }
}

public struct SecureSessionTransferCredential: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case password
        case privateKeyPassphrase = "private_key_passphrase"
    }

    public let kind: Kind
    public let secret: String

    public init(kind: Kind, secret: String) {
        self.kind = kind
        self.secret = secret
    }
}

public struct SecureSessionTransferPrivateKey: Codable, Equatable, Sendable {
    public let fileName: String
    public let contents: Data

    public init(fileName: String, contents: Data) {
        self.fileName = fileName
        self.contents = contents
    }
}

public struct SecureSessionTransferSessionMetadata: Codable, Equatable, Sendable {
    public let name: String
    public let protocolName: String
    public let host: String
    public let port: UInt16
    public let username: String?

    public init(name: String, protocolName: String, host: String, port: UInt16, username: String?) {
        self.name = name
        self.protocolName = protocolName
        self.host = host
        self.port = port
        self.username = username
    }
}

public struct SecureSessionTransferPayload: Codable, Equatable, Sendable {
    public let sessionJSON: String
    public let metadata: SecureSessionTransferSessionMetadata
    public let credential: SecureSessionTransferCredential?
    public let privateKey: SecureSessionTransferPrivateKey?

    public init(
        sessionJSON: String,
        metadata: SecureSessionTransferSessionMetadata,
        credential: SecureSessionTransferCredential?,
        privateKey: SecureSessionTransferPrivateKey?
    ) {
        self.sessionJSON = sessionJSON
        self.metadata = metadata
        self.credential = credential
        self.privateKey = privateKey
    }

    public func externalCredentialPayload() -> ExternalSessionImportPayload? {
        guard let credential else {
            return nil
        }
        let importedCredential: ExternalImportedCredential
        switch credential.kind {
        case .password:
            importedCredential = .password(credential.secret)
        case .privateKeyPassphrase:
            importedCredential = .privateKeyPassphrase(credential.secret)
        }
        return ExternalSessionImportPayload(
            sessions: [
                ExternalImportedSession(
                    name: metadata.name,
                    folderPath: nil,
                    protocolName: metadata.protocolName,
                    host: metadata.host,
                    port: metadata.port,
                    username: metadata.username,
                    privateKeyPath: nil,
                    credential: importedCredential
                )
            ],
            warnings: []
        )
    }
}

public enum SecureSessionTransfer {
    public static let format = "stacio.secure-session.v1"
    public static let fileExtension = "stacio-session"

    private static let kdfIterations: UInt32 = 310_000
    private static let minimumKDFIterations: UInt32 = 100_000
    private static let maximumKDFIterations: UInt32 = 1_000_000
    private static let saltByteCount = 16
    private static let keyByteCount = 32
    private static let nonceByteCount = 12
    private static let authenticationTagByteCount = 16

    public static func isEncryptedTransfer(_ contents: String) -> Bool {
        guard let data = contents.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return object["format"] as? String == format
    }

    public static func encrypt(
        _ payload: SecureSessionTransferPayload,
        passphrase: String
    ) throws -> String {
        let payloadData: Data
        do {
            payloadData = try JSONEncoder().encode(payload)
        } catch {
            throw SecureSessionTransferError.invalidPayload
        }
        let salt = try randomData(count: saltByteCount)
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: kdfIterations)
        let nonce = try AES.GCM.Nonce(data: randomData(count: nonceByteCount))
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(payloadData, using: key, nonce: nonce)
        } catch {
            throw SecureSessionTransferError.invalidPayload
        }

        let envelope = Envelope(
            format: format,
            kdf: .init(
                name: "PBKDF2-HMAC-SHA256",
                iterations: kdfIterations,
                salt: salt.base64EncodedString()
            ),
            cipher: .init(
                name: "AES-256-GCM",
                nonce: Data(nonce).base64EncodedString(),
                ciphertext: sealedBox.ciphertext.base64EncodedString(),
                tag: sealedBox.tag.base64EncodedString()
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let output = String(data: try encoder.encode(envelope), encoding: .utf8) else {
            throw SecureSessionTransferError.invalidPayload
        }
        return output
    }

    public static func decrypt(
        _ contents: String,
        passphrase: String
    ) throws -> SecureSessionTransferPayload {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: Data(contents.utf8))
        } catch {
            throw SecureSessionTransferError.invalidEnvelope
        }
        guard envelope.format == format else {
            throw SecureSessionTransferError.unsupportedFormat
        }
        guard envelope.kdf.name == "PBKDF2-HMAC-SHA256",
              envelope.kdf.iterations >= minimumKDFIterations,
              envelope.kdf.iterations <= maximumKDFIterations,
              envelope.cipher.name == "AES-256-GCM",
              let salt = Data(base64Encoded: envelope.kdf.salt),
              let nonceData = Data(base64Encoded: envelope.cipher.nonce),
              let ciphertext = Data(base64Encoded: envelope.cipher.ciphertext),
              let tag = Data(base64Encoded: envelope.cipher.tag),
              salt.count == saltByteCount,
              nonceData.count == nonceByteCount,
              tag.count == authenticationTagByteCount,
              ciphertext.isEmpty == false
        else {
            throw SecureSessionTransferError.invalidCipherData
        }

        let key = try deriveKey(
            passphrase: passphrase,
            salt: salt,
            iterations: envelope.kdf.iterations
        )
        let plaintext: Data
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag
            )
            plaintext = try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw SecureSessionTransferError.decryptionFailed
        }
        do {
            return try JSONDecoder().decode(SecureSessionTransferPayload.self, from: plaintext)
        } catch {
            throw SecureSessionTransferError.invalidPayload
        }
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(repeating: 0, count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw SecureSessionTransferError.keyDerivationFailed
        }
        return data
    }

    private static func deriveKey(
        passphrase: String,
        salt: Data,
        iterations: UInt32
    ) throws -> SymmetricKey {
        guard passphrase.isEmpty == false else {
            throw SecureSessionTransferError.emptyPassphrase
        }
        var output = [UInt8](repeating: 0, count: keyByteCount)
        let status: Int32 = passphrase.withCString { password in
            salt.withUnsafeBytes { rawSalt in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password,
                    passphrase.lengthOfBytes(using: .utf8),
                    rawSalt.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    &output,
                    output.count
                )
            }
        }
        guard status == kCCSuccess else {
            throw SecureSessionTransferError.keyDerivationFailed
        }
        return SymmetricKey(data: Data(output))
    }

    private struct Envelope: Codable {
        let format: String
        let kdf: KDF
        let cipher: Cipher

        struct KDF: Codable {
            let name: String
            let iterations: UInt32
            let salt: String
        }

        struct Cipher: Codable {
            let name: String
            let nonce: String
            let ciphertext: String
            let tag: String
        }
    }
}

public protocol SecureSessionTransferExporting {
    func encryptedTransfer(
        for session: SessionRecord,
        configJSON: String?,
        credential: CredentialRecord?,
        passphrase: String
    ) throws -> String
}

public final class KeychainSecureSessionTransferExporter: SecureSessionTransferExporting {
    private let keychainStore: KeychainCredentialStore
    private let fileManager: FileManager

    public init(
        keychainStore: KeychainCredentialStore = KeychainCredentialStore(),
        fileManager: FileManager = .default
    ) {
        self.keychainStore = keychainStore
        self.fileManager = fileManager
    }

    public func encryptedTransfer(
        for session: SessionRecord,
        configJSON: String?,
        credential: CredentialRecord?,
        passphrase: String
    ) throws -> String {
        guard session.port > 0, session.port <= UInt32(UInt16.max) else {
            throw SecureSessionTransferError.invalidPayload
        }
        let payload = SecureSessionTransferPayload(
            sessionJSON: try SessionSidebarSingleSessionExport.jsonString(
                for: session,
                configJSON: configJSON
            ),
            metadata: SecureSessionTransferSessionMetadata(
                name: session.name,
                protocolName: session.protocol,
                host: session.host,
                port: UInt16(session.port),
                username: normalized(session.username)
            ),
            credential: try transferCredential(for: session, credential: credential),
            privateKey: try privateKey(for: session)
        )
        return try SecureSessionTransfer.encrypt(payload, passphrase: passphrase)
    }

    private func transferCredential(
        for session: SessionRecord,
        credential: CredentialRecord?
    ) throws -> SecureSessionTransferCredential? {
        guard let credentialID = normalized(session.credentialId) else {
            return nil
        }
        guard let credential, credential.id == credentialID else {
            throw SecureSessionTransferError.credentialUnavailable
        }
        let kind: SecureSessionTransferCredential.Kind
        switch credential.kind {
        case "password":
            kind = .password
        case "private_key_passphrase":
            kind = .privateKeyPassphrase
        default:
            throw SecureSessionTransferError.unsupportedCredentialKind
        }
        let secret: String
        do {
            secret = try keychainStore.readSecret(
                id: credential.id,
                account: credential.keychainAccount
            )
        } catch {
            throw SecureSessionTransferError.credentialUnavailable
        }
        return SecureSessionTransferCredential(kind: kind, secret: secret)
    }

    private func privateKey(for session: SessionRecord) throws -> SecureSessionTransferPrivateKey? {
        guard let sourcePath = normalized(session.privateKeyPath) else {
            return nil
        }
        let expandedPath = NSString(string: sourcePath).expandingTildeInPath
        guard fileManager.isReadableFile(atPath: expandedPath) else {
            throw SecureSessionTransferError.privateKeyUnavailable
        }
        let contents: Data
        do {
            contents = try Data(contentsOf: URL(fileURLWithPath: expandedPath))
        } catch {
            throw SecureSessionTransferError.privateKeyUnavailable
        }
        guard contents.isEmpty == false else {
            throw SecureSessionTransferError.privateKeyUnavailable
        }
        let fileName = URL(fileURLWithPath: expandedPath).lastPathComponent
        return SecureSessionTransferPrivateKey(
            fileName: fileName.isEmpty ? "private-key" : fileName,
            contents: contents
        )
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public protocol SecureSessionTransferPrivateKeyInstalling {
    func install(
        _ privateKey: SecureSessionTransferPrivateKey,
        for importedSession: SessionRecord,
        databasePath: String
    ) throws
}

public final class StacioImportedPrivateKeyInstaller: SecureSessionTransferPrivateKeyInstalling {
    private let fileManager: FileManager
    private let applicationSupportDirectoryProvider: () throws -> URL
    private let sessionPathUpdater: (String, String, String) throws -> Void

    public init(
        fileManager: FileManager = .default,
        applicationSupportDirectoryProvider: @escaping () throws -> URL = {
            try StacioPaths().applicationSupportDirectory
        },
        sessionPathUpdater: @escaping (String, String, String) throws -> Void = {
            databasePath, sessionID, privateKeyPath in
            _ = try CoreBridge.updateSessionRecord(
                databasePath: databasePath,
                id: sessionID,
                update: SessionUpdate(
                    name: nil,
                    protocol: nil,
                    folderId: nil,
                    host: nil,
                    port: nil,
                    username: nil,
                    privateKeyPath: privateKeyPath,
                    credentialId: nil,
                    tags: nil,
                    configJson: nil
                )
            )
        }
    ) {
        self.fileManager = fileManager
        self.applicationSupportDirectoryProvider = applicationSupportDirectoryProvider
        self.sessionPathUpdater = sessionPathUpdater
    }

    public func install(
        _ privateKey: SecureSessionTransferPrivateKey,
        for importedSession: SessionRecord,
        databasePath: String
    ) throws {
        var destinationURL: URL?
        do {
            let directory = try applicationSupportDirectoryProvider()
                .appendingPathComponent("ImportedPrivateKeys", isDirectory: true)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
            let fileName = safeFileName(privateKey.fileName)
            let target = directory.appendingPathComponent("\(UUID().uuidString)-\(fileName)")
            destinationURL = target
            try privateKey.contents.write(to: target, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: target.path
            )
            try sessionPathUpdater(databasePath, importedSession.id, target.path)
        } catch {
            if let destinationURL {
                try? fileManager.removeItem(at: destinationURL)
            }
            throw SecureSessionTransferError.privateKeyInstallFailed
        }
    }

    private func safeFileName(_ value: String) -> String {
        let allowed = value.filter { character in
            character.isLetter || character.isNumber || character == "." || character == "-" || character == "_"
        }
        let name = allowed.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(name.prefix(80)).isEmpty ? "private-key" : String(name.prefix(80))
    }
}

public protocol SecureSessionTransferPassphrasePrompting {
    func promptForExportPassphrase(sessionName: String, parentWindow: NSWindow?) -> String?
    func promptForImportPassphrase(sourceName: String, parentWindow: NSWindow?) -> String?
}

public final class AppKitSecureSessionTransferPassphrasePrompter: SecureSessionTransferPassphrasePrompting {
    public init() {}

    public func promptForExportPassphrase(sessionName: String, parentWindow: NSWindow?) -> String? {
        runOnMainThread {
            self.promptForExportPassphraseOnMainThread(sessionName: sessionName, parentWindow: parentWindow)
        }
    }

    public func promptForImportPassphrase(sourceName: String, parentWindow: NSWindow?) -> String? {
        runOnMainThread {
            self.promptForImportPassphraseOnMainThread(sourceName: sourceName, parentWindow: parentWindow)
        }
    }

    private func promptForExportPassphraseOnMainThread(sessionName: String, parentWindow: NSWindow?) -> String? {
        prompt(
            title: L10n.SecureSessionTransfer.exportTitle,
            message: L10n.SecureSessionTransfer.exportMessage(sessionName),
            confirmationRequired: true,
            confirmTitle: L10n.SecureSessionTransfer.exportAction,
            parentWindow: parentWindow
        )
    }

    private func promptForImportPassphraseOnMainThread(sourceName: String, parentWindow: NSWindow?) -> String? {
        prompt(
            title: L10n.SecureSessionTransfer.importTitle,
            message: L10n.SecureSessionTransfer.importMessage(sourceName),
            confirmationRequired: false,
            confirmTitle: L10n.SecureSessionTransfer.importAction,
            parentWindow: parentWindow
        )
    }

    private func prompt(
        title: String,
        message: String,
        confirmationRequired: Bool,
        confirmTitle: String,
        parentWindow: NSWindow?
    ) -> String? {
        while true {
            let passphraseField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            passphraseField.placeholderString = L10n.SecureSessionTransfer.passphrasePlaceholder
            var fields: [NSView] = [passphraseField]
            var confirmationField: NSSecureTextField?
            if confirmationRequired {
                let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                field.placeholderString = L10n.SecureSessionTransfer.confirmPassphrasePlaceholder
                fields.append(field)
                confirmationField = field
            }
            let accessory = NSStackView(views: fields)
            accessory.orientation = .vertical
            accessory.alignment = .leading
            accessory.spacing = 8
            accessory.frame = NSRect(x: 0, y: 0, width: 300, height: confirmationRequired ? 56 : 24)

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = title
            alert.informativeText = message
            alert.accessoryView = accessory
            alert.addButton(withTitle: confirmTitle)
            alert.addButton(withTitle: L10n.Common.cancel)
            _ = parentWindow
            guard alert.runModal() == .alertFirstButtonReturn else {
                return nil
            }

            let passphrase = passphraseField.stringValue
            guard passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                presentValidationError(L10n.SecureSessionTransfer.emptyPassphrase)
                continue
            }
            if confirmationRequired, passphrase != confirmationField?.stringValue {
                presentValidationError(L10n.SecureSessionTransfer.passphraseMismatch)
                continue
            }
            return passphrase
        }
    }

    private func presentValidationError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.SecureSessionTransfer.exportTitle
        alert.informativeText = message
        alert.addButton(withTitle: L10n.Common.ok)
        alert.runModal()
    }

    private func runOnMainThread<T>(_ body: @escaping () -> T) -> T {
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }
}
