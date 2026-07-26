import AppKit
import CoreFoundation
import Foundation
import StacioCoreBindings

struct FileTransferDocumentIdentity: Equatable, Sendable {
    let documentID: String
    let monacoURI: String

    static func local(url: URL) -> FileTransferDocumentIdentity {
        let normalizedURL = url.standardizedFileURL
        return FileTransferDocumentIdentity(
            documentID: "local|\(normalizedURL.path)",
            monacoURI: makeMonacoURI(kind: "local", runtimeID: nil, path: normalizedURL.path)
        )
    }

    static func remote(
        runtimeID: String,
        path: String,
        fileName _: String
    ) -> FileTransferDocumentIdentity {
        FileTransferDocumentIdentity(
            documentID: "remote|\(runtimeID)|\(path)",
            monacoURI: makeMonacoURI(kind: "remote", runtimeID: runtimeID, path: path)
        )
    }

    private static func makeMonacoURI(kind: String, runtimeID: String?, path: String) -> String {
        var components = URLComponents()
        components.scheme = "stacio-document"
        components.host = kind
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        components.path = runtimeID.map { "/\($0)\(normalizedPath)" } ?? normalizedPath
        return components.string ?? "stacio-document:\(kind):\(path)"
    }
}

@MainActor
struct FileTransferRemoteDocumentSource {
    let runtimeID: String
    let context: TunnelLiveSessionContext
    let bridge: RemoteFilesBridging
    let transferScheduler: SCPTransferScheduling?
    let setStatus: (String) -> Void
}

public enum FileTransferDocumentError: Error, LocalizedError, Equatable {
    case fileTooLarge(String, UInt64)
    case invalidTextEncoding(String)
    case cannotEncodeText(String, String)
    case remoteFileChangedSinceOpen(String)
    case remoteWriteVerificationFailed(String)
    case remoteWriteRollbackFailed(String)
    case previewPreparationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge(let fileName, let size):
            return "“\(fileName)”大小为 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))，超过内置编辑器 10 MB 的单文件限制。"
        case .invalidTextEncoding(let fileName):
            return "“\(fileName)”不是可识别的文本格式，将以只读方式打开。"
        case .cannotEncodeText(let fileName, let encoding):
            return "“\(fileName)”包含无法用 \(encoding) 保存的字符。"
        case .remoteFileChangedSinceOpen(let path):
            return "远端文件自打开后已被修改，为避免覆盖他人的更改，本次保存已取消：\(path)"
        case .remoteWriteVerificationFailed(let path):
            return "远端文件写入后校验失败：\(path)"
        case .remoteWriteRollbackFailed(let path):
            return "远端文件保存失败且自动恢复未完成，请立即检查：\(path)"
        case .previewPreparationFailed(let fileName):
            return "无法准备“\(fileName)”的快速预览。"
        }
    }
}

enum FileTransferTextEncoding: Equatable, Sendable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
    case utf32LittleEndian
    case utf32BigEndian
    case gb18030
    case windowsCP1252
    case isoLatin1

    var foundationEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16LittleEndian: return .utf16LittleEndian
        case .utf16BigEndian: return .utf16BigEndian
        case .utf32LittleEndian: return .utf32LittleEndian
        case .utf32BigEndian: return .utf32BigEndian
        case .gb18030: return FileTransferTextDocument.gb18030Encoding
        case .windowsCP1252: return .windowsCP1252
        case .isoLatin1: return .isoLatin1
        }
    }

    var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        case .utf32LittleEndian: return "UTF-32 LE"
        case .utf32BigEndian: return "UTF-32 BE"
        case .gb18030: return "GB18030"
        case .windowsCP1252: return "Windows-1252"
        case .isoLatin1: return "ISO-8859-1"
        }
    }

    var byteOrderMark: Data {
        switch self {
        case .utf8: return Data([0xEF, 0xBB, 0xBF])
        case .utf16LittleEndian: return Data([0xFF, 0xFE])
        case .utf16BigEndian: return Data([0xFE, 0xFF])
        case .utf32LittleEndian: return Data([0xFF, 0xFE, 0x00, 0x00])
        case .utf32BigEndian: return Data([0x00, 0x00, 0xFE, 0xFF])
        case .gb18030, .windowsCP1252, .isoLatin1: return Data()
        }
    }
}

struct FileTransferTextDocument: Equatable, Sendable {
    let text: String
    let encoding: FileTransferTextEncoding
    let hasByteOrderMark: Bool

    static let gb18030Encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
    ))

    static func decode(_ data: Data) -> FileTransferTextDocument? {
        if data.isEmpty {
            return FileTransferTextDocument(text: "", encoding: .utf8, hasByteOrderMark: false)
        }
        let signatures: [(Data, FileTransferTextEncoding)] = [
            (Data([0xFF, 0xFE, 0x00, 0x00]), .utf32LittleEndian),
            (Data([0x00, 0x00, 0xFE, 0xFF]), .utf32BigEndian),
            (Data([0xEF, 0xBB, 0xBF]), .utf8),
            (Data([0xFF, 0xFE]), .utf16LittleEndian),
            (Data([0xFE, 0xFF]), .utf16BigEndian)
        ]
        for (signature, encoding) in signatures where data.starts(with: signature) {
            let payload = Data(data.dropFirst(signature.count))
            guard let text = String(data: payload, encoding: encoding.foundationEncoding),
                  isPlausibleText(text)
            else { return nil }
            return FileTransferTextDocument(text: text, encoding: encoding, hasByteOrderMark: true)
        }

        if let text = String(data: data, encoding: .utf8), isPlausibleText(text) {
            return FileTransferTextDocument(text: text, encoding: .utf8, hasByteOrderMark: false)
        }

        var candidates: [(encoding: FileTransferTextEncoding, text: String)] = []
        if data.count.isMultiple(of: 2) {
            candidates.append(contentsOf: utf16CandidateEncodings(for: data).compactMap { encoding in
                guard let text = String(data: data, encoding: encoding.foundationEncoding),
                      isPlausibleText(text),
                      isCredibleLegacyText(text, sourceData: data, encoding: encoding)
                else { return nil }
                return (encoding, text)
            })
        }
        candidates.append(contentsOf: [
            FileTransferTextEncoding.gb18030,
            .windowsCP1252,
            .isoLatin1
        ].compactMap { encoding in
            guard let text = String(data: data, encoding: encoding.foundationEncoding),
                  isPlausibleText(text),
                  isCredibleLegacyText(text, sourceData: data, encoding: encoding)
            else { return nil }
            return (encoding, text)
        })
        guard let best = candidates.max(by: {
            textQualityScore($0.text, encoding: $0.encoding)
                < textQualityScore($1.text, encoding: $1.encoding)
        }) else { return nil }
        return FileTransferTextDocument(text: best.text, encoding: best.encoding, hasByteOrderMark: false)
    }

    func encodedData(replacingWith updatedText: String, fileName: String = "文件") throws -> Data {
        guard let payload = updatedText.data(using: encoding.foundationEncoding, allowLossyConversion: false) else {
            throw FileTransferDocumentError.cannotEncodeText(fileName, encoding.displayName)
        }
        guard hasByteOrderMark else { return payload }
        return encoding.byteOrderMark + payload
    }

    private static func utf16CandidateEncodings(for data: Data) -> [FileTransferTextEncoding] {
        let sampleCount = min(data.count, 4_096)
        let pairs = sampleCount / 2
        guard pairs > 0 else { return [] }
        var evenNulls = 0
        var oddNulls = 0
        for index in 0..<sampleCount where data[index] == 0 {
            if index.isMultiple(of: 2) {
                evenNulls += 1
            } else {
                oddNulls += 1
            }
        }
        if oddNulls * 3 >= pairs, evenNulls * 8 < pairs {
            return [.utf16LittleEndian]
        }
        if evenNulls * 3 >= pairs, oddNulls * 8 < pairs {
            return [.utf16BigEndian]
        }
        let sparseNullLimit = max(1, pairs / 8)
        guard evenNulls + oddNulls <= sparseNullLimit else { return [] }
        return [.utf16LittleEndian, .utf16BigEndian]
    }

    private static func textQualityScore(
        _ text: String,
        encoding: FileTransferTextEncoding
    ) -> Int {
        let scalars = Array(text.unicodeScalars.prefix(32_768))
        guard scalars.isEmpty == false else { return Int.max }
        var score = 0
        for scalar in scalars {
            switch scalar.value {
            case 0x0A, 0x0D, 0x09, 0x0C:
                score += 7
            case 0x20...0x7E:
                score += 6
            case 0x4E00...0x9FFF:
                score += 9
            case 0x3400...0x4DBF, 0x20000...0x2FA1F:
                score += 3
            case 0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD:
                score -= 24
            default:
                if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                    score += 4
                } else if CharacterSet.controlCharacters.contains(scalar) {
                    score -= 24
                } else {
                    score += 1
                }
            }
        }
        let encodingPreference: Int
        switch encoding {
        case .utf16LittleEndian, .utf16BigEndian:
            encodingPreference = 30
        case .gb18030:
            encodingPreference = 20
        case .windowsCP1252:
            encodingPreference = 10
        case .utf8, .utf32LittleEndian, .utf32BigEndian, .isoLatin1:
            encodingPreference = 0
        }
        return (score * 100 / scalars.count) + encodingPreference
    }

    private static func isPlausibleText(_ text: String) -> Bool {
        guard text.contains("\0") == false else { return false }
        var scalarCount = 0
        var disallowedControls = 0
        var privateUseScalars = 0
        for scalar in text.unicodeScalars.prefix(32_768) {
            scalarCount += 1
            if CharacterSet.controlCharacters.contains(scalar),
               scalar != "\n", scalar != "\r", scalar != "\t", scalar != "\u{0C}"
            {
                disallowedControls += 1
            }
            switch scalar.value {
            case 0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD:
                privateUseScalars += 1
            default:
                break
            }
        }
        guard scalarCount > 0 else { return true }
        return disallowedControls * 100 <= scalarCount * 2
            && privateUseScalars * 100 <= scalarCount * 2
    }

    private static func isCredibleLegacyText(
        _ text: String,
        sourceData: Data,
        encoding: FileTransferTextEncoding
    ) -> Bool {
        guard text.data(using: encoding.foundationEncoding, allowLossyConversion: false) == sourceData else {
            return false
        }
        let scalars = Array(text.unicodeScalars.prefix(32_768))
        let hasLayout = scalars.contains { scalar in
            scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar == "\u{0C}" || scalar == " "
        }
        let asciiGraphicCount = scalars.count { (0x21...0x7E).contains($0.value) }
        let cjkCount = scalars.count {
            (0x3400...0x4DBF).contains($0.value)
                || (0x4E00...0x9FFF).contains($0.value)
                || (0x20000...0x2FA1F).contains($0.value)
        }
        switch encoding {
        case .gb18030:
            return hasLayout || asciiGraphicCount > 0 || cjkCount >= 4
        case .utf16LittleEndian, .utf16BigEndian:
            return hasLayout || asciiGraphicCount > 0 || cjkCount * 4 >= scalars.count * 3
        case .windowsCP1252, .isoLatin1:
            return hasLayout || asciiGraphicCount * 2 >= scalars.count
        case .utf8, .utf32LittleEndian, .utf32BigEndian:
            return true
        }
    }
}

struct FileTransferLocalTextReadResult: Sendable {
    let document: FileTransferTextDocument?
    let byteCount: UInt64
}

struct FileTransferLocalTextIO: @unchecked Sendable {
    typealias ReadData = @Sendable (URL) throws -> Data
    typealias WriteData = @Sendable (Data, URL) throws -> Void

    static let live = FileTransferLocalTextIO(
        queue: DispatchQueue(label: "Stacio.LocalTextIO", qos: .userInitiated),
        readData: { try Data(contentsOf: $0, options: .mappedIfSafe) },
        writeData: { data, url in try data.write(to: url, options: .atomic) }
    )

    private let queue: DispatchQueue
    private let readData: ReadData
    private let writeData: WriteData

    init(queue: DispatchQueue, readData: @escaping ReadData, writeData: @escaping WriteData) {
        self.queue = queue
        self.readData = readData
        self.writeData = writeData
    }

    func load(
        url: URL,
        completion: @escaping @MainActor (Result<FileTransferLocalTextReadResult, Error>) -> Void
    ) {
        let completionBox = FileWorkspaceUncheckedSendableBox(completion)
        queue.async {
            let result = Result<FileTransferLocalTextReadResult, Error> {
                let data = try readData(url)
                return FileTransferLocalTextReadResult(
                    document: FileTransferTextDocument.decode(data),
                    byteCount: UInt64(data.count)
                )
            }
            DispatchQueue.main.async {
                completionBox.value(result)
            }
        }
    }

    func save(
        document: FileTransferTextDocument,
        updatedText: String,
        fileName: String,
        url: URL,
        afterWrite: (() throws -> Void)? = nil,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        let completionBox = FileWorkspaceUncheckedSendableBox(completion)
        let afterWriteBox = afterWrite.map(FileWorkspaceUncheckedSendableBox.init)
        queue.async {
            let result = Result<Void, Error> {
                let data = try document.encodedData(replacingWith: updatedText, fileName: fileName)
                try writeData(data, url)
                try afterWriteBox?.value()
            }
            DispatchQueue.main.async {
                completionBox.value(result)
            }
        }
    }
}

enum FileTransferRemoteTextSaveOperation {
    static func execute(
        document: FileTransferTextDocument,
        updatedText: String,
        fileName: String,
        remotePath: String,
        write: (Data) throws -> UInt64,
        read: (_ length: UInt64) throws -> Data
    ) throws {
        let data = try document.encodedData(replacingWith: updatedText, fileName: fileName)
        let writtenByteCount = try write(data)
        guard writtenByteCount == UInt64(data.count) else {
            throw FileTransferDocumentError.remoteWriteVerificationFailed(remotePath)
        }
        let verification = try read(UInt64(data.count) + 1)
        guard verification == data else {
            throw FileTransferDocumentError.remoteWriteVerificationFailed(remotePath)
        }
    }

    static func executeAtomically(
        expectedData: Data,
        updatedData: Data,
        remotePath: String,
        read: (_ remotePath: String, _ length: UInt64) throws -> Data,
        write: (_ remotePath: String, _ data: Data) throws -> UInt64,
        rename: (_ fromPath: String, _ toPath: String) throws -> Void,
        delete: (_ remotePath: String) throws -> Void
    ) throws {
        let currentData = try read(remotePath, UInt64(expectedData.count) + 1)
        guard currentData == expectedData else {
            throw FileTransferDocumentError.remoteFileChangedSinceOpen(remotePath)
        }

        let paths = atomicPaths(for: remotePath)
        var stageExists = false
        var backupExists = false
        var promoted = false
        do {
            let writtenByteCount = try write(paths.stage, updatedData)
            stageExists = true
            guard writtenByteCount == UInt64(updatedData.count),
                  try read(paths.stage, UInt64(updatedData.count) + 1) == updatedData
            else {
                throw FileTransferDocumentError.remoteWriteVerificationFailed(remotePath)
            }

            try rename(remotePath, paths.backup)
            backupExists = true
            try rename(paths.stage, remotePath)
            stageExists = false
            promoted = true

            guard try read(remotePath, UInt64(updatedData.count) + 1) == updatedData else {
                throw FileTransferDocumentError.remoteWriteVerificationFailed(remotePath)
            }
            try? delete(paths.backup)
            backupExists = false
        } catch {
            if promoted {
                try? delete(remotePath)
            }
            if backupExists {
                do {
                    try rename(paths.backup, remotePath)
                    backupExists = false
                } catch {
                    if stageExists { try? delete(paths.stage) }
                    throw FileTransferDocumentError.remoteWriteRollbackFailed(remotePath)
                }
            }
            if stageExists { try? delete(paths.stage) }
            throw error
        }
    }

    private static func atomicPaths(for remotePath: String) -> (stage: String, backup: String) {
        let baseName = (remotePath as NSString).lastPathComponent
        let parent = (remotePath as NSString).deletingLastPathComponent
        let token = UUID().uuidString.lowercased()
        let stageName = ".\(baseName).stacio-edit-\(token).partial"
        let backupName = ".\(baseName).stacio-edit-\(token).backup"
        return (
            join(parent: parent, name: stageName),
            join(parent: parent, name: backupName)
        )
    }

    private static func join(parent: String, name: String) -> String {
        if parent.isEmpty { return name }
        if parent == "/" { return "/\(name)" }
        return parent.hasSuffix("/") ? "\(parent)\(name)" : "\(parent)/\(name)"
    }
}

private final class FileTransferRemoteTextDocumentState: @unchecked Sendable {
    private let lock = NSLock()
    private let document: FileTransferTextDocument
    private var expectedData: Data

    init(document: FileTransferTextDocument, expectedData: Data) {
        self.document = document
        self.expectedData = expectedData
    }

    func save(
        updatedText: String,
        fileName: String,
        remotePath: String,
        read: (_ remotePath: String, _ length: UInt64) throws -> Data,
        write: (_ remotePath: String, _ data: Data) throws -> UInt64,
        rename: (_ fromPath: String, _ toPath: String) throws -> Void,
        delete: (_ remotePath: String) throws -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let updatedData = try document.encodedData(replacingWith: updatedText, fileName: fileName)
        try FileTransferRemoteTextSaveOperation.executeAtomically(
            expectedData: expectedData,
            updatedData: updatedData,
            remotePath: remotePath,
            read: read,
            write: write,
            rename: rename,
            delete: delete
        )
        expectedData = updatedData
    }
}

private struct FileTransferLoadedRemoteTextDocument: Sendable {
    let document: FileTransferTextDocument
    let data: Data
}

private enum FileTransferDocumentRoute: Equatable {
    case text
    case image
    case video
    case audio
    case pdf
    case hex
    case quickLook
    case unknown

    static func route(fileName: String) -> FileTransferDocumentRoute {
        let baseName = (fileName as NSString).lastPathComponent.lowercased()
        let fileExtension = (baseName as NSString).pathExtension
        switch StacioFileDisplay.contentKind(forFileName: baseName) {
        case .image: return .image
        case .video: return .video
        case .audio: return .audio
        case .text, .other: break
        }
        if fileExtension == "pdf" { return .pdf }
        if quickLookExtensions.contains(fileExtension) { return .quickLook }
        if hexExtensions.contains(fileExtension) { return .hex }
        if fileExtension.isEmpty || textExtensions.contains(fileExtension) || textFileNames.contains(baseName) {
            return .text
        }
        return .unknown
    }

    var mediaKind: RemoteFileContentKind? {
        switch self {
        case .image: return .image
        case .video: return .video
        case .audio: return .audio
        case .text, .pdf, .hex, .quickLook, .unknown: return nil
        }
    }

    private static let textExtensions: Set<String> = [
        "asm", "bash", "bat", "c", "cc", "cfg", "clj", "cljs", "cmd", "conf", "cpp", "cs",
        "css", "csv", "dart", "desktop", "dockerfile", "env", "ex", "exs", "fs", "fsx", "go",
        "gql", "h", "hcl", "hpp", "htm", "html", "ini", "java", "js", "json", "jsx", "kt",
        "kts", "less", "list", "log", "lua", "m", "md", "mm", "php", "pl", "plist", "pm",
        "diff", "gradle", "lock", "patch", "pem", "properties", "proto", "ps1", "psd1", "psm1",
        "pub", "py", "r", "rb", "rmd", "rs", "sass",
        "scala", "scss", "service", "sh", "socket", "sql", "swift", "tf", "tfvars", "timer",
        "toml", "ts", "tsx", "txt", "vue", "xml", "yaml", "yml", "zsh"
    ]

    private static let textFileNames: Set<String> = [
        ".bash_profile", ".bashrc", ".dockerignore", ".editorconfig", ".env", ".gitattributes",
        ".gitconfig", ".gitignore", ".npmrc", ".profile", ".vimrc", ".zprofile", ".zshenv",
        ".zshrc", "caddyfile", "containerfile", "crontab", "dockerfile", "fstab", "gemfile",
        "hostname", "hosts", "makefile", "procfile", "resolv.conf", "ssh_config", "sshd_config",
        "sudoers", "vagrantfile"
    ]

    private static let quickLookExtensions: Set<String> = [
        "7z", "bz2", "doc", "docm", "docx", "dmg", "gz", "key", "numbers", "odp", "ods", "odt",
        "pages", "pkg", "ppt", "pptm", "pptx", "rar", "rtf", "rtfd", "tar", "tbz", "tgz", "txz",
        "xar", "xls", "xlsm", "xlsx", "xz", "zip", "zst"
    ]

    private static let hexExtensions: Set<String> = [
        "a", "bin", "class", "dat", "db", "dll", "dylib", "elf", "exe", "img", "iso", "o", "pyc",
        "raw", "so", "sqlite", "sqlite3", "wasm"
    ]
}

@MainActor
final class FileTransferPendingPreparationRegistry {
    enum Outcome: Equatable {
        case failure
        case successTransfersRoot
    }

    private struct Entry {
        let root: URL
        let jobID: String
        let cancel: (String) -> Void
    }

    private var entries: [UUID: Entry] = [:]

    @discardableResult
    func register(
        root: URL,
        jobID: String,
        cancel: @escaping (String) -> Void
    ) -> UUID {
        let id = UUID()
        entries[id] = Entry(root: root, jobID: jobID, cancel: cancel)
        return id
    }

    @discardableResult
    func finish(id: UUID, outcome: Outcome) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else { return false }
        if outcome == .failure {
            try? FileManager.default.removeItem(at: entry.root)
        }
        return true
    }

    func isPending(id: UUID) -> Bool {
        entries[id] != nil
    }

    func cancelAll() {
        let pendingEntries = Array(entries.values)
        entries.removeAll()
        for entry in pendingEntries {
            entry.cancel(entry.jobID)
            try? FileManager.default.removeItem(at: entry.root)
        }
    }

    var pendingCountForTesting: Int {
        entries.count
    }

    deinit {
        let pendingEntries = Array(entries.values)
        for entry in pendingEntries {
            try? FileManager.default.removeItem(at: entry.root)
        }
        Task { @MainActor in
            for entry in pendingEntries {
                entry.cancel(entry.jobID)
            }
        }
    }
}

private final class FileTransferDocumentLifecycle: @unchecked Sendable {
    final class Token: @unchecked Sendable {
        private weak var lifecycle: FileTransferDocumentLifecycle?
        private let generation: UInt64

        fileprivate init(lifecycle: FileTransferDocumentLifecycle, generation: UInt64) {
            self.lifecycle = lifecycle
            self.generation = generation
        }

        var isActive: Bool {
            lifecycle?.isActive(generation: generation) == true
        }

        func checkCancellation() throws {
            guard isActive else { throw CancellationError() }
        }
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0

    func makeToken() -> Token {
        lock.lock()
        let currentGeneration = generation
        lock.unlock()
        return Token(lifecycle: self, generation: currentGeneration)
    }

    func invalidateAll() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    private func isActive(generation candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == candidate
    }
}

@MainActor
final class FileTransferDocumentCoordinator {
    private static let maximumInlineTextBytes: UInt64 = 10 * 1_024 * 1_024

    private var editorWindowController: RemoteTextEditorWindowController?
    private var mediaWindowControllers: [String: FileWorkspaceMediaWindowController] = [:]
    private var hexWindowControllers: [String: FileWorkspaceHexWindowController] = [:]
    private var pdfWindowControllers: [String: FileWorkspacePDFWindowController] = [:]
    private let quickLookCoordinator = FileWorkspaceQuickLookCoordinator()
    private let pendingPreparations = FileTransferPendingPreparationRegistry()
    private let lifecycle = FileTransferDocumentLifecycle()
    private let localTextIO: FileTransferLocalTextIO

    init(localTextIO: FileTransferLocalTextIO = .live) {
        self.localTextIO = localTextIO
    }

    var editorWindowControllerForTesting: RemoteTextEditorWindowController? {
        editorWindowController
    }

    var mediaWindowCountForTesting: Int {
        mediaWindowControllers.count
    }

    var mediaSourceURLsForTesting: [URL] {
        mediaWindowControllers.values.map { $0.mediaViewController.document.sourceURL }
    }

    var hexWindowControllersForTesting: [FileWorkspaceHexWindowController] {
        Array(hexWindowControllers.values)
    }

    var pdfWindowControllersForTesting: [FileWorkspacePDFWindowController] {
        Array(pdfWindowControllers.values)
    }

    func closeMediaWindowsForTesting() {
        Array(mediaWindowControllers.values).forEach { $0.close() }
    }

    func closeDocumentWindows() {
        lifecycle.invalidateAll()
        pendingPreparations.cancelAll()
        let editorController = editorWindowController
        let mediaControllers = Array(mediaWindowControllers.values)
        let hexControllers = Array(hexWindowControllers.values)
        let pdfControllers = Array(pdfWindowControllers.values)
        editorWindowController = nil
        mediaWindowControllers.removeAll()
        hexWindowControllers.removeAll()
        pdfWindowControllers.removeAll()
        editorController?.onClose = nil
        editorController?.close()
        for controller in mediaControllers {
            controller.onClose = nil
            controller.close()
        }
        for controller in hexControllers {
            controller.onClose = nil
            controller.close()
        }
        for controller in pdfControllers {
            controller.onClose = nil
            controller.close()
        }
        quickLookCoordinator.closePreview()
    }

    func closeDocumentWindowsForTesting() {
        closeDocumentWindows()
    }

    var quickLookCoordinatorForTesting: FileWorkspaceQuickLookCoordinator {
        quickLookCoordinator
    }

    func openLocalURL(_ url: URL) {
        let lifecycleToken = lifecycle.makeToken()
        let normalizedURL = url.standardizedFileURL
        let route = FileTransferDocumentRoute.route(fileName: normalizedURL.lastPathComponent)
        switch route {
        case .image, .video, .audio:
            do {
                presentMedia(try Self.makeLocalMediaDocument(
                    url: normalizedURL,
                    kind: route.mediaKind ?? .other
                ))
            } catch {
                quickLookCoordinator.present(urls: [normalizedURL])
            }
        case .pdf:
            presentPDF(sourceID: normalizedURL.path, documentURL: normalizedURL)
        case .hex:
            presentLocalHex(url: normalizedURL)
        case .quickLook:
            quickLookCoordinator.present(urls: [normalizedURL])
        case .text, .unknown:
            let byteCount = Self.localByteCount(at: normalizedURL)
            guard byteCount <= Self.maximumInlineTextBytes else {
                quickLookCoordinator.present(urls: [normalizedURL])
                return
            }
            localTextIO.load(url: normalizedURL) { [weak self] result in
                guard let self, lifecycleToken.isActive else { return }
                switch result {
                case .success(let loaded):
                    guard let document = loaded.document else {
                        if route == .text {
                            self.presentLocalHex(url: normalizedURL)
                        } else {
                            self.quickLookCoordinator.present(urls: [normalizedURL])
                        }
                        return
                    }
                    self.presentLocalEditor(
                        url: normalizedURL,
                        document: document,
                        byteCount: loaded.byteCount,
                        lifecycleToken: lifecycleToken
                    )
                case .failure:
                    self.quickLookCoordinator.present(urls: [normalizedURL])
                }
            }
        }
    }

    func quickLookLocalURLs(_ urls: [URL]) {
        quickLookCoordinator.present(urls: urls)
    }

    func openRemoteSelection(
        _ selection: RemoteFileSelection,
        source: FileTransferRemoteDocumentSource
    ) {
        guard selection.isFile else { return }
        let lifecycleToken = lifecycle.makeToken()
        let fileName = Self.fileName(for: selection)
        let route = FileTransferDocumentRoute.route(fileName: fileName)
        let bridgeBox = FileWorkspaceUncheckedSendableBox(source.bridge)
        let contextBox = FileWorkspaceUncheckedSendableBox(source.context)
        let remoteReadSession = Self.makeRemoteReadSession(
            bridge: bridgeBox.value,
            context: contextBox.value
        )
        let reader: @Sendable (UInt64, UInt64?) throws -> Data = { offset, length in
            try lifecycleToken.checkCancellation()
            return try remoteReadSession.read(
                remotePath: selection.path,
                offset: offset,
                length: length
            )
        }

        if let kind = route.mediaKind {
            let sourceURL: URL
            do {
                if kind == .image {
                    sourceURL = try RemoteFileOnlineMediaRegistry.shared.registerForStreaming(
                        fileName: fileName,
                        mimeType: Self.mimeType(forFileName: fileName, kind: kind),
                        byteCount: selection.size,
                        onInvalidate: { remoteReadSession.close() },
                        reader: reader
                    )
                } else {
                    sourceURL = try RemoteFileOnlineMediaRegistry.shared.registerForPlayback(
                        fileName: fileName,
                        mimeType: Self.mimeType(forFileName: fileName, kind: kind),
                        byteCount: selection.size,
                        onInvalidate: { remoteReadSession.close() },
                        reader: reader
                    )
                }
            } catch {
                source.setStatus(RuntimeDiagnosticFormatter.userMessage(for: error))
                return
            }
            presentMedia(FileWorkspaceMediaDocument(
                sourceID: "\(source.runtimeID):\(selection.path)",
                fileName: fileName,
                sourceURL: sourceURL,
                contentKind: kind,
                byteCount: selection.size
            ))
            source.setStatus("已打开 \(fileName)")
            return
        }

        switch route {
        case .pdf:
            prepareRemoteFile(
                selection,
                source: source,
                lifecycleToken: lifecycleToken
            ) { [weak self] result in
                guard let self, lifecycleToken.isActive else { return }
                switch result {
                case .success(let prepared):
                    self.presentPDF(
                        sourceID: "\(source.runtimeID):\(selection.path)",
                        documentURL: prepared.url,
                        temporaryRoot: prepared.temporaryRoot
                    )
                    source.setStatus("已打开 \(fileName)")
                case .failure(let error):
                    source.setStatus(RuntimeDiagnosticFormatter.userMessage(for: error))
                }
            }
            return
        case .hex:
            presentHex(FileWorkspaceHexDocument(
                sourceID: "\(source.runtimeID):\(selection.path)",
                fileName: fileName,
                byteCount: selection.size,
                reader: { offset, length in
                    try reader(offset, length)
                }
            ))
            source.setStatus("已打开 \(fileName)")
            return
        case .quickLook:
            quickLookRemoteSelections([selection], source: source)
            return
        case .text, .unknown:
            break
        case .image, .video, .audio:
            return
        }

        guard selection.size <= Self.maximumInlineTextBytes else {
            quickLookRemoteSelections([selection], source: source)
            return
        }

        source.setStatus("正在打开 \(fileName)...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<FileTransferLoadedRemoteTextDocument, Error>
            do {
                let data = try reader(0, selection.size)
                guard let document = FileTransferTextDocument.decode(data) else {
                    throw FileTransferDocumentError.invalidTextEncoding(fileName)
                }
                result = .success(FileTransferLoadedRemoteTextDocument(document: document, data: data))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, lifecycleToken.isActive else { return }
                switch result {
                case .success(let loaded):
                    let document = loaded.document
                    let saveState = FileTransferRemoteTextDocumentState(
                        document: document,
                        expectedData: loaded.data
                    )
                    let identity = FileTransferDocumentIdentity.remote(
                        runtimeID: source.runtimeID,
                        path: selection.path,
                        fileName: fileName
                    )
                    let descriptor = RemoteTextEditorDocumentDescriptor(
                        documentID: identity.documentID,
                        monacoURI: identity.monacoURI,
                        remotePath: selection.path,
                        fileName: fileName,
                        content: document.text,
                        encodingDisplayName: document.encoding.displayName,
                        contentKind: .text,
                        byteCount: selection.size
                    )
                    self.presentRemoteEditor(
                        descriptor: descriptor,
                        asyncSaveHandler: { updatedText, completion in
                            source.setStatus("正在保存 \(fileName)...")
                            let completionBox = FileWorkspaceUncheckedSendableBox(completion)
                            let statusBox = FileWorkspaceUncheckedSendableBox(source.setStatus)
                            DispatchQueue.global(qos: .userInitiated).async {
                                let saveResult = Result<Void, Error> {
                                    try lifecycleToken.checkCancellation()
                                    let context = contextBox.value
                                    try saveState.save(
                                        updatedText: updatedText,
                                        fileName: fileName,
                                        remotePath: selection.path,
                                        read: { remotePath, length in
                                            try lifecycleToken.checkCancellation()
                                            return try remoteReadSession.read(
                                                remotePath: remotePath,
                                                offset: 0,
                                                length: length
                                            )
                                        },
                                        write: { remotePath, data in
                                            try lifecycleToken.checkCancellation()
                                            return try bridgeBox.value.writeLiveRemoteFile(
                                                config: context.config,
                                                secret: context.secret,
                                                expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                                                remotePath: remotePath,
                                                contents: data
                                            )
                                        },
                                        rename: { fromPath, toPath in
                                            try lifecycleToken.checkCancellation()
                                            try bridgeBox.value.renameLiveRemotePath(
                                                config: context.config,
                                                secret: context.secret,
                                                expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                                                fromPath: fromPath,
                                                toPath: toPath
                                            )
                                        },
                                        delete: { remotePath in
                                            try lifecycleToken.checkCancellation()
                                            try bridgeBox.value.deleteLiveRemotePath(
                                                config: context.config,
                                                secret: context.secret,
                                                expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                                                remotePath: remotePath,
                                                recursive: false
                                            )
                                        }
                                    )
                                }
                                DispatchQueue.main.async {
                                    guard lifecycleToken.isActive else {
                                        completionBox.value(.failure(CancellationError()))
                                        return
                                    }
                                    switch saveResult {
                                    case .success:
                                        statusBox.value("已保存 \(fileName)")
                                    case .failure(let error):
                                        statusBox.value(RuntimeDiagnosticFormatter.userMessage(for: error))
                                    }
                                    completionBox.value(saveResult)
                                }
                            }
                        }
                    )
                    source.setStatus("已打开 \(fileName)")
                case .failure(let error as FileTransferDocumentError) where error == .invalidTextEncoding(fileName):
                    if route == .unknown {
                        self.quickLookRemoteSelections([selection], source: source)
                        return
                    }
                    self.presentHex(FileWorkspaceHexDocument(
                        sourceID: "\(source.runtimeID):\(selection.path)",
                        fileName: fileName,
                        byteCount: selection.size,
                        reader: { offset, length in try reader(offset, length) }
                    ))
                    source.setStatus("已以只读 Hex 打开 \(fileName)")
                case .failure(let error):
                    source.setStatus(RuntimeDiagnosticFormatter.userMessage(for: error))
                }
            }
        }
    }

    func quickLookRemoteSelections(
        _ selections: [RemoteFileSelection],
        source: FileTransferRemoteDocumentSource
    ) {
        guard selections.isEmpty == false else { return }
        let lifecycleToken = lifecycle.makeToken()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioQuickLook", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            source.setStatus(RuntimeDiagnosticFormatter.userMessage(for: error))
            return
        }

        source.setStatus("正在准备快速预览...")
        let scheduledJobIDs: [Int: String]
        if source.transferScheduler != nil {
            // SCP/SFTP transfer engines support recursive directory downloads. Keep
            // directories in the scheduled batch instead of replacing them with an
            // empty placeholder, otherwise Quick Look opens a misleading empty folder.
            scheduledJobIDs = Dictionary(uniqueKeysWithValues: selections.enumerated().map { index, _ in
                (index, "quicklook_\(UUID().uuidString)")
            })
        } else {
            scheduledJobIDs = [:]
        }
        let preparationID = pendingPreparations.register(
            root: root,
            jobID: "quicklook_batch_\(UUID().uuidString)",
            cancel: { [weak transferScheduler = source.transferScheduler] _ in
                for jobID in scheduledJobIDs.values {
                    _ = transferScheduler?.cancelTransfer(jobID: jobID)
                }
            }
        )
        let batch = FileTransferQuickLookBatch(count: selections.count) { [weak self] urls in
            guard let self, lifecycleToken.isActive else { return }
            if urls.isEmpty {
                guard self.pendingPreparations.finish(id: preparationID, outcome: .failure) else { return }
                source.setStatus(FileTransferDocumentError.previewPreparationFailed(Self.fileName(for: selections[0])).localizedDescription)
                return
            }
            guard self.pendingPreparations.finish(
                id: preparationID,
                outcome: .successTransfersRoot
            ) else { return }
            self.quickLookCoordinator.present(urls: urls, temporaryRoots: [root])
            source.setStatus("快速预览已打开")
        }

        for (index, selection) in selections.enumerated() {
            let name = Self.fileName(for: selection)
            let itemDirectory = root.appendingPathComponent(String(index), isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
            } catch {
                batch.finish(index: index, url: nil)
                continue
            }
            let destination = itemDirectory.appendingPathComponent(name, isDirectory: selection.isDirectory)

            if let transferScheduler = source.transferScheduler {
                guard let jobID = scheduledJobIDs[index] else {
                    batch.finish(index: index, url: nil)
                    continue
                }
                transferScheduler.scheduleLiveTransfer(
                    runtimeID: source.runtimeID,
                    config: source.context.config,
                    secret: source.context.secret,
                    expectedFingerprintSHA256: source.context.expectedFingerprintSHA256,
                    job: ScpTransferJob(
                        id: jobID,
                        direction: .download,
                        sourcePath: selection.path,
                        destinationPath: destination.path,
                        bytesTotal: selection.size
                    ),
                    completion: { [weak self] progress in
                        guard Self.isTerminalTransferStatus(progress.status) else { return }
                        DispatchQueue.main.async { [weak self] in
                            guard let self,
                                  lifecycleToken.isActive,
                                  self.pendingPreparations.isPending(id: preparationID)
                            else { return }
                            batch.finish(
                                index: index,
                                url: progress.status == "completed" && Self.preparedQuickLookItemExists(
                                    at: destination,
                                    isDirectory: selection.isDirectory
                                ) ? destination : nil
                            )
                        }
                    }
                )
                continue
            }

            let bridgeBox = FileWorkspaceUncheckedSendableBox(source.bridge)
            let contextBox = FileWorkspaceUncheckedSendableBox(source.context)
            let sourceID = "\(source.runtimeID):\(selection.path)"
            if selection.isDirectory {
                // The bridge fallback is used by tests and by runtimes without the
                // transfer queue. Recreate the directory tree through live listings
                // and stream each file in bounded chunks so Quick Look sees the real
                // contents without loading an entire archive into memory.
                DispatchQueue.global(qos: .userInitiated).async {
                    let result: Result<URL, Error>
                    do {
                        let readSession = Self.makeRemoteReadSession(
                            bridge: bridgeBox.value,
                            context: contextBox.value
                        )
                        try Self.stageRemoteDirectoryForQuickLook(
                            bridge: bridgeBox.value,
                            context: contextBox.value,
                            readSession: readSession,
                            remotePath: selection.path,
                            destination: destination,
                            lifecycleToken: lifecycleToken
                        )
                        result = .success(destination)
                    } catch {
                        result = .failure(error)
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self,
                              lifecycleToken.isActive,
                              self.pendingPreparations.isPending(id: preparationID)
                        else { return }
                        if case .success(let url) = result {
                            batch.finish(index: index, url: url)
                        } else {
                            batch.finish(index: index, url: nil)
                        }
                    }
                }
                continue
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let result: URL?
                do {
                    let readSession = Self.makeRemoteReadSession(
                        bridge: bridgeBox.value,
                        context: contextBox.value
                    )
                    let document = FileWorkspaceHexDocument(
                        sourceID: sourceID,
                        fileName: name,
                        byteCount: selection.size,
                        reader: { offset, length in
                            try lifecycleToken.checkCancellation()
                            return try readSession.read(
                                remotePath: selection.path,
                                offset: offset,
                                length: length
                            )
                        }
                    )
                    try document.export(to: destination)
                    result = destination
                } catch {
                    result = nil
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          lifecycleToken.isActive,
                          self.pendingPreparations.isPending(id: preparationID)
                    else { return }
                    batch.finish(index: index, url: result)
                }
            }
        }
    }

    private nonisolated static let quickLookDirectoryEntryLimit = 2_000
    private nonisolated static let quickLookDirectoryByteLimit: UInt64 = 256 * 1_024 * 1_024
    private nonisolated static let quickLookDirectoryChunkSize: UInt64 = 1 * 1_024 * 1_024

    private nonisolated static func makeRemoteReadSession(
        bridge: RemoteFilesBridging,
        context: TunnelLiveSessionContext
    ) -> RemoteFileReadSession {
        let bridgeBox = FileWorkspaceUncheckedSendableBox(bridge)
        let contextBox = FileWorkspaceUncheckedSendableBox(context)
        return RemoteFileReadSession.deferred(
            open: {
                let context = contextBox.value
                return try bridgeBox.value.openLiveRemoteFileReadSession(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256
                )
            },
            fallback: { remotePath, offset, length in
                let context = contextBox.value
                return try bridgeBox.value.readLiveRemoteFile(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                    remotePath: remotePath,
                    offset: offset,
                    length: length
                )
            }
        )
    }

    private struct QuickLookDirectoryBudget {
        var entryCount = 0
        var byteCount: UInt64 = 0
    }

    private nonisolated static func stageRemoteDirectoryForQuickLook(
        bridge: RemoteFilesBridging,
        context: TunnelLiveSessionContext,
        readSession: RemoteFileReadSession,
        remotePath: String,
        destination: URL,
        lifecycleToken: FileTransferDocumentLifecycle.Token
    ) throws {
        var budget = QuickLookDirectoryBudget()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try stageRemoteDirectoryContentsForQuickLook(
            bridge: bridge,
            context: context,
            readSession: readSession,
            remotePath: remotePath,
            destination: destination,
            lifecycleToken: lifecycleToken,
            budget: &budget,
            depth: 0
        )
    }

    private nonisolated static func stageRemoteDirectoryContentsForQuickLook(
        bridge: RemoteFilesBridging,
        context: TunnelLiveSessionContext,
        readSession: RemoteFileReadSession,
        remotePath: String,
        destination: URL,
        lifecycleToken: FileTransferDocumentLifecycle.Token,
        budget: inout QuickLookDirectoryBudget,
        depth: Int
    ) throws {
        try lifecycleToken.checkCancellation()
        guard depth <= 64 else {
            throw FileTransferDocumentError.previewPreparationFailed((remotePath as NSString).lastPathComponent)
        }

        let entries = try bridge.listLiveRemoteDirectory(
            config: context.config,
            secret: context.secret,
            expectedFingerprintSHA256: context.expectedFingerprintSHA256,
            remotePath: remotePath
        )
        for entry in entries {
            try lifecycleToken.checkCancellation()
            guard entry.kind != .symlink else { continue }
            let name = (entry.path as NSString).lastPathComponent
            guard name.isEmpty == false, name != ".", name != "..", name.contains("/") == false else {
                continue
            }
            budget.entryCount += 1
            guard budget.entryCount <= quickLookDirectoryEntryLimit else {
                throw FileTransferDocumentError.previewPreparationFailed((remotePath as NSString).lastPathComponent)
            }
            let childURL = destination.appendingPathComponent(name, isDirectory: entry.kind == .directory)
            switch entry.kind {
            case .directory:
                try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
                try stageRemoteDirectoryContentsForQuickLook(
                    bridge: bridge,
                    context: context,
                    readSession: readSession,
                    remotePath: entry.path,
                    destination: childURL,
                    lifecycleToken: lifecycleToken,
                    budget: &budget,
                    depth: depth + 1
                )
            case .file:
                budget.byteCount += entry.size
                guard budget.byteCount <= quickLookDirectoryByteLimit else {
                    throw FileTransferDocumentError.previewPreparationFailed((remotePath as NSString).lastPathComponent)
                }
                try stageRemoteFileForQuickLook(
                    readSession: readSession,
                    remotePath: entry.path,
                    destination: childURL,
                    byteCount: entry.size,
                    lifecycleToken: lifecycleToken
                )
            case .symlink:
                continue
            }
        }
    }

    private nonisolated static func stageRemoteFileForQuickLook(
        readSession: RemoteFileReadSession,
        remotePath: String,
        destination: URL,
        byteCount: UInt64,
        lifecycleToken: FileTransferDocumentLifecycle.Token
    ) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var offset: UInt64 = 0
        while offset < byteCount {
            try lifecycleToken.checkCancellation()
            let requestedLength = min(quickLookDirectoryChunkSize, byteCount - offset)
            let data = try readSession.read(
                remotePath: remotePath,
                offset: offset,
                length: requestedLength
            )
            guard data.isEmpty == false else {
                throw FileTransferDocumentError.previewPreparationFailed((remotePath as NSString).lastPathComponent)
            }
            try handle.write(contentsOf: data)
            offset += UInt64(data.count)
            guard offset <= byteCount else {
                throw FileTransferDocumentError.previewPreparationFailed((remotePath as NSString).lastPathComponent)
            }
        }
    }

    private nonisolated static func preparedQuickLookItemExists(
        at url: URL,
        isDirectory: Bool
    ) -> Bool {
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else {
            return false
        }
        return directory.boolValue == isDirectory
    }

    private func presentLocalEditor(
        url: URL,
        document: FileTransferTextDocument,
        byteCount: UInt64,
        lifecycleToken: FileTransferDocumentLifecycle.Token
    ) {
        let identity = FileTransferDocumentIdentity.local(url: url)
        let descriptor = RemoteTextEditorDocumentDescriptor(
            documentID: identity.documentID,
            monacoURI: identity.monacoURI,
            remotePath: url.path,
            fileName: url.lastPathComponent,
            content: document.text,
            encodingDisplayName: document.encoding.displayName,
            contentKind: .text,
            byteCount: byteCount
        )
        presentRemoteEditor(descriptor: descriptor) { [localTextIO] updatedText, completion in
            guard lifecycleToken.isActive else {
                completion(.failure(CancellationError()))
                return
            }
            localTextIO.save(
                document: document,
                updatedText: updatedText,
                fileName: url.lastPathComponent,
                url: url,
                completion: completion
            )
        }
    }

    private func presentRemoteEditor(
        descriptor: RemoteTextEditorDocumentDescriptor,
        saveHandler: @escaping (String) throws -> Void
    ) {
        if let editorWindowController {
            editorWindowController.editorViewController.openDocument(descriptor, onSaveText: saveHandler)
            bringForward(editorWindowController)
            return
        }
        let editor = RemoteTextEditorViewController(document: descriptor, onSaveText: saveHandler)
        presentNewEditor(editor)
    }

    private func presentRemoteEditor(
        descriptor: RemoteTextEditorDocumentDescriptor,
        asyncSaveHandler: @escaping RemoteTextEditorAsyncSaveHandler
    ) {
        if let editorWindowController {
            editorWindowController.editorViewController.openDocument(
                descriptor,
                onSaveTextAsync: asyncSaveHandler
            )
            bringForward(editorWindowController)
            return
        }
        let editor = RemoteTextEditorViewController(
            document: descriptor,
            onSaveTextAsync: asyncSaveHandler
        )
        presentNewEditor(editor)
    }

    private func presentNewEditor(_ editor: RemoteTextEditorViewController) {
        let controller = RemoteTextEditorWindowController(editorViewController: editor)
        controller.onClose = { [weak self] closedController in
            guard self?.editorWindowController === closedController else { return }
            self?.editorWindowController = nil
            closedController.onClose = nil
        }
        editor.onCloseRequested = { [weak controller] in
            controller?.window?.performClose(nil)
        }
        editorWindowController = controller
        bringForward(controller)
    }

    private func presentMedia(_ document: FileWorkspaceMediaDocument) {
        if let existing = mediaWindowControllers[document.sourceID] {
            RemoteFileOnlineMediaRegistry.shared.unregister(url: document.sourceURL)
            bringForward(existing)
            return
        }
        let controller = FileWorkspaceMediaWindowController(document: document)
        controller.onClose = { [weak self] closedController in
            self?.mediaWindowControllers.removeValue(forKey: document.sourceID)
            closedController.onClose = nil
        }
        mediaWindowControllers[document.sourceID] = controller
        bringForward(controller)
    }

    private func presentLocalHex(url: URL) {
        do {
            presentHex(try FileWorkspaceHexDocument.localFile(url))
        } catch {
            quickLookCoordinator.present(urls: [url])
        }
    }

    private func presentHex(_ document: FileWorkspaceHexDocument) {
        if let existing = hexWindowControllers[document.sourceID] {
            bringForward(existing)
            return
        }
        let controller = FileWorkspaceHexWindowController(document: document)
        controller.onClose = { [weak self] closedController in
            self?.hexWindowControllers.removeValue(forKey: document.sourceID)
            closedController.onClose = nil
        }
        hexWindowControllers[document.sourceID] = controller
        bringForward(controller)
    }

    private func presentPDF(sourceID: String, documentURL: URL, temporaryRoot: URL? = nil) {
        if let existing = pdfWindowControllers[sourceID] {
            if let temporaryRoot {
                try? FileManager.default.removeItem(at: temporaryRoot)
            }
            bringForward(existing)
            return
        }
        let controller = FileWorkspacePDFWindowController(
            documentURL: documentURL,
            temporaryRoot: temporaryRoot
        )
        controller.onClose = { [weak self] closedController in
            self?.pdfWindowControllers.removeValue(forKey: sourceID)
            closedController.onClose = nil
        }
        pdfWindowControllers[sourceID] = controller
        bringForward(controller)
    }

    private func prepareRemoteFile(
        _ selection: RemoteFileSelection,
        source: FileTransferRemoteDocumentSource,
        lifecycleToken: FileTransferDocumentLifecycle.Token,
        completion: @escaping (Result<FileTransferPreparedDocument, Error>) -> Void
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioDocumentPreview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            completion(.failure(error))
            return
        }
        let destination = root.appendingPathComponent(Self.fileName(for: selection))
        let preparedFileName = Self.fileName(for: selection)
        let preparedSourceID = "\(source.runtimeID):\(selection.path)"
        source.setStatus("正在准备 \(Self.fileName(for: selection))...")
        let jobID = source.transferScheduler == nil
            ? "document_direct_\(UUID().uuidString)"
            : "document_\(UUID().uuidString)"
        let preparationID = pendingPreparations.register(
            root: root,
            jobID: jobID,
            cancel: { [weak transferScheduler = source.transferScheduler] jobID in
                _ = transferScheduler?.cancelTransfer(jobID: jobID)
            }
        )

        if let transferScheduler = source.transferScheduler {
            transferScheduler.scheduleLiveTransfer(
                runtimeID: source.runtimeID,
                config: source.context.config,
                secret: source.context.secret,
                expectedFingerprintSHA256: source.context.expectedFingerprintSHA256,
                job: ScpTransferJob(
                    id: jobID,
                    direction: .download,
                    sourcePath: selection.path,
                    destinationPath: destination.path,
                    bytesTotal: selection.size
                ),
                completion: { [weak self] progress in
                    guard Self.isTerminalTransferStatus(progress.status) else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, lifecycleToken.isActive else { return }
                        if progress.status == "completed" {
                            guard self.pendingPreparations.finish(
                                id: preparationID,
                                outcome: .successTransfersRoot
                            ) else { return }
                            completion(.success(FileTransferPreparedDocument(url: destination, temporaryRoot: root)))
                        } else {
                            guard self.pendingPreparations.finish(
                                id: preparationID,
                                outcome: .failure
                            ) else { return }
                            completion(.failure(FileTransferDocumentError.previewPreparationFailed(Self.fileName(for: selection))))
                        }
                    }
                }
            )
            return
        }

        let bridgeBox = FileWorkspaceUncheckedSendableBox(source.bridge)
        let contextBox = FileWorkspaceUncheckedSendableBox(source.context)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<FileTransferPreparedDocument, Error> {
                let readSession = Self.makeRemoteReadSession(
                    bridge: bridgeBox.value,
                    context: contextBox.value
                )
                let document = FileWorkspaceHexDocument(
                    sourceID: preparedSourceID,
                    fileName: preparedFileName,
                    byteCount: selection.size,
                    reader: { offset, length in
                        try lifecycleToken.checkCancellation()
                        return try readSession.read(
                            remotePath: selection.path,
                            offset: offset,
                            length: length
                        )
                    }
                )
                try document.export(to: destination)
                return FileTransferPreparedDocument(url: destination, temporaryRoot: root)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, lifecycleToken.isActive else { return }
                let outcome: FileTransferPendingPreparationRegistry.Outcome
                switch result {
                case .success:
                    outcome = .successTransfersRoot
                case .failure:
                    outcome = .failure
                }
                guard self.pendingPreparations.finish(id: preparationID, outcome: outcome) else { return }
                completion(result)
            }
        }
    }

    private func bringForward(_ controller: NSWindowController) {
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func isTerminalTransferStatus(_ status: String) -> Bool {
        switch status.lowercased() {
        case "completed", "failed", "canceled", "cancelled", "stopped":
            return true
        default:
            return false
        }
    }

    private static func fileName(for selection: RemoteFileSelection) -> String {
        let name = (selection.path as NSString).lastPathComponent
        guard name.isEmpty == false, name != ".", name != "..", name.contains("/") == false else {
            return "远端项目"
        }
        return name
    }

    private nonisolated static func localByteCount(at url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private nonisolated static func makeLocalMediaDocument(
        url: URL,
        kind: RemoteFileContentKind
    ) throws -> FileWorkspaceMediaDocument {
        let byteCount = localByteCount(at: url)
        let readSession = try FileTransferLocalMediaReadSession(url: url)
        let reader: @Sendable (UInt64, UInt64?) throws -> Data = { offset, length in
            try readSession.read(offset: offset, length: length)
        }
        let sourceURL: URL
        do {
            if kind == .image {
                sourceURL = try RemoteFileOnlineMediaRegistry.shared.registerForStreaming(
                    fileName: url.lastPathComponent,
                    mimeType: mimeType(forFileName: url.lastPathComponent, kind: kind),
                    byteCount: byteCount,
                    onInvalidate: { readSession.close() },
                    reader: reader
                )
            } else {
                sourceURL = try RemoteFileOnlineMediaRegistry.shared.registerForPlayback(
                    fileName: url.lastPathComponent,
                    mimeType: mimeType(forFileName: url.lastPathComponent, kind: kind),
                    byteCount: byteCount,
                    onInvalidate: { readSession.close() },
                    reader: reader
                )
            }
        } catch {
            readSession.close()
            throw error
        }
        return FileWorkspaceMediaDocument(
            sourceID: url.standardizedFileURL.path,
            fileName: url.lastPathComponent,
            sourceURL: sourceURL,
            contentKind: kind,
            byteCount: byteCount
        )
    }

    private nonisolated static func mimeType(forFileName fileName: String, kind: RemoteFileContentKind) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "m4a": return "audio/mp4"
        case "mp4": return "video/mp4"
        case "webm": return "video/webm"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        default:
            switch kind {
            case .image: return "image/*"
            case .audio: return "audio/*"
            case .video: return "video/*"
            case .text, .other: return "application/octet-stream"
            }
        }
    }
}

private struct FileWorkspaceUncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private final class FileTransferLocalMediaReadSession: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    func read(offset: UInt64, length: UInt64?) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw CancellationError() }
        try handle.seek(toOffset: offset)
        if let length {
            return try handle.read(upToCount: Int(clamping: length)) ?? Data()
        }
        return try handle.readToEnd() ?? Data()
    }

    func close() {
        lock.lock()
        let handle = self.handle
        self.handle = nil
        lock.unlock()
        try? handle?.close()
    }

    deinit {
        close()
    }
}

private struct FileTransferPreparedDocument: Sendable {
    let url: URL
    let temporaryRoot: URL
}

@MainActor
private final class FileTransferQuickLookBatch {
    private var remaining: Int
    private var results: [Int: URL] = [:]
    private var completedIndexes: Set<Int> = []
    private let completion: ([URL]) -> Void

    init(count: Int, completion: @escaping ([URL]) -> Void) {
        remaining = count
        self.completion = completion
    }

    func finish(index: Int, url: URL?) {
        guard completedIndexes.insert(index).inserted else { return }
        if let url {
            results[index] = url
        }
        remaining -= 1
        guard remaining == 0 else { return }
        completion(results.keys.sorted().compactMap { results[$0] })
    }
}
