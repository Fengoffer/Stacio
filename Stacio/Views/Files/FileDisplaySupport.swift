import AppKit
import StacioCoreBindings
import UniformTypeIdentifiers

public enum RemoteFileContentKind: Equatable {
    case text
    case image
    case video
    case audio
    case other

    var isEditableText: Bool {
        self == .text
    }

    var isPreviewableMedia: Bool {
        switch self {
        case .image, .video, .audio:
            return true
        case .text, .other:
            return false
        }
    }
}

public struct RemoteTextEditorDisplayOptions: Codable, Equatable {
    public static let defaultValue = RemoteTextEditorDisplayOptions(
        lineNumbersEnabled: true,
        wordWrapEnabled: false,
        minimapEnabled: true
    )

    public var lineNumbersEnabled: Bool
    public var wordWrapEnabled: Bool
    public var minimapEnabled: Bool

    public init(
        lineNumbersEnabled: Bool = true,
        wordWrapEnabled: Bool = false,
        minimapEnabled: Bool = true
    ) {
        self.lineNumbersEnabled = lineNumbersEnabled
        self.wordWrapEnabled = wordWrapEnabled
        self.minimapEnabled = minimapEnabled
    }

    public static func load(defaults: UserDefaults = .standard) -> RemoteTextEditorDisplayOptions {
        RemoteTextEditorDisplayOptions(
            lineNumbersEnabled: boolValue(
                forKey: DefaultsKey.lineNumbersEnabled,
                defaults: defaults,
                defaultValue: defaultValue.lineNumbersEnabled
            ),
            wordWrapEnabled: boolValue(
                forKey: DefaultsKey.wordWrapEnabled,
                defaults: defaults,
                defaultValue: defaultValue.wordWrapEnabled
            ),
            minimapEnabled: boolValue(
                forKey: DefaultsKey.minimapEnabled,
                defaults: defaults,
                defaultValue: defaultValue.minimapEnabled
            )
        )
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(lineNumbersEnabled, forKey: DefaultsKey.lineNumbersEnabled)
        defaults.set(wordWrapEnabled, forKey: DefaultsKey.wordWrapEnabled)
        defaults.set(minimapEnabled, forKey: DefaultsKey.minimapEnabled)
    }

    private enum DefaultsKey {
        static let lineNumbersEnabled = "Stacio.RemoteTextEditor.lineNumbersEnabled"
        static let wordWrapEnabled = "Stacio.RemoteTextEditor.wordWrapEnabled"
        static let minimapEnabled = "Stacio.RemoteTextEditor.minimapEnabled"
    }

    private static func boolValue(
        forKey key: String,
        defaults: UserDefaults,
        defaultValue: Bool
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

enum StacioFileDisplay {
    static let iconDimension: CGFloat = 28
    static let iconSize = NSSize(width: iconDimension, height: iconDimension)
    static let tableRowHeight: CGFloat = 34

    static func sortedRemoteRows(_ rows: [RemoteFileRow]) -> [RemoteFileRow] {
        rows.sorted(by: compareFileRows)
    }

    static func sortedLocalRows(_ rows: [LocalFileRow]) -> [LocalFileRow] {
        rows.sorted(by: compareFileRows)
    }

    static func remoteIcon(for row: RemoteFileRow) -> NSImage {
        switch row.kindValue {
        case .directory:
            folderIcon()
        case .file, .symlink:
            fileIcon(fileName: row.name)
        }
    }

    static func localIcon(for row: LocalFileRow) -> NSImage {
        if row.isDirectory {
            return folderIcon()
        }
        let icon = NSWorkspace.shared.icon(forFile: row.url.path)
        icon.size = iconSize
        return icon
    }

    static func timeText(for date: Date?) -> String {
        guard let date else {
            return "-"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func remoteTimeText(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "-" : trimmed
    }

    static func byteSizeText(_ size: Int?) -> String {
        guard let size else {
            return ""
        }
        return String(format: "%.2f KB", Double(size) / 1_024)
    }

    static func iconAccessibilityLabel(for row: RemoteFileRow) -> String {
        switch row.kindValue {
        case .directory:
            "文件夹图标"
        case .file:
            "\(fileExtensionLabel(row.name)) 文件图标"
        case .symlink:
            "符号链接图标"
        }
    }

    static func iconAccessibilityLabel(for row: LocalFileRow) -> String {
        row.isDirectory ? "文件夹图标" : "\(fileExtensionLabel(row.name)) 文件图标"
    }

    static func contentKind(forFileName fileName: String) -> RemoteFileContentKind {
        let lowercasedName = fileName.lowercased()
        let fileExtension = (lowercasedName as NSString).pathExtension
        let type = fileExtension.isEmpty ? nil : UTType(filenameExtension: fileExtension)

        if isKnownImageExtension(fileExtension) || type?.conforms(to: .image) == true {
            return .image
        }
        if isKnownVideoExtension(fileExtension)
            || type?.conforms(to: .movie) == true
            || type?.conforms(to: .video) == true
        {
            return .video
        }
        if isKnownAudioExtension(fileExtension) || type?.conforms(to: .audio) == true {
            return .audio
        }
        return .text
    }

    static func languageIdentifier(forFileName fileName: String, content: String = "") -> String {
        let baseName = (fileName as NSString).lastPathComponent.lowercased()
        let fileExtension = (baseName as NSString).pathExtension

        if ["conf", "cfg", "ini", "service", "timer", "socket", "mount", "target", "desktop", "list", "sources"].contains(fileExtension) {
            return "ini"
        }
        if baseName.hasPrefix(".env.") {
            return "ini"
        }
        if baseName.hasSuffix(".kubeconfig") {
            return "yaml"
        }
        if ["yml", "yaml"].contains(fileExtension) {
            return "yaml"
        }
        if baseName.hasPrefix("dockerfile.") || baseName.hasPrefix("containerfile.") {
            return "dockerfile"
        }
        if let namedLanguage = knownLanguageByFileName[baseName] {
            return namedLanguage
        }
        if let extensionLanguage = knownLanguageByExtension[fileExtension] {
            return extensionLanguage
        }
        if let shebangLanguage = languageFromShebang(content) {
            return shebangLanguage
        }
        return "plaintext"
    }

    private static func compareFileRows<Row: StacioFileDisplayRow>(_ lhs: Row, _ rhs: Row) -> Bool {
        if lhs.displayGroup != rhs.displayGroup {
            return lhs.displayGroup < rhs.displayGroup
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func folderIcon() -> NSImage {
        let folderPath = "/System/Library/CoreServices"
        let icon = NSWorkspace.shared.icon(forFile: folderPath)
        icon.size = iconSize
        return icon
    }

    private static func fileIcon(fileName: String) -> NSImage {
        let fileExtension = (fileName as NSString).pathExtension
        let contentType = fileExtension.isEmpty
            ? UTType.data
            : UTType(filenameExtension: fileExtension) ?? .data
        let icon = NSWorkspace.shared.icon(for: contentType)
        icon.size = iconSize
        guard fileExtension.isEmpty == false else {
            return icon
        }
        return badgedFileIcon(base: icon, extensionLabel: fileExtensionLabel(fileName))
    }

    private static func fileExtensionLabel(_ fileName: String) -> String {
        let fileExtension = (fileName as NSString).pathExtension
        return fileExtension.isEmpty ? "通用" : fileExtension.uppercased()
    }

    private static func badgedFileIcon(base: NSImage, extensionLabel: String) -> NSImage {
        let badgeText = String(extensionLabel.prefix(3)).uppercased()
        let image = NSImage(size: iconSize)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        base.draw(
            in: NSRect(origin: .zero, size: iconSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )

        let badgeWidth: CGFloat = badgeText.count <= 2 ? 16 : 20
        let badgeRect = NSRect(
            x: iconSize.width - badgeWidth,
            y: 1,
            width: badgeWidth,
            height: 11
        )
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 3, yRadius: 3)
        badgeColor(for: extensionLabel).setFill()
        badgePath.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 6.5, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = badgeText.size(withAttributes: attributes)
        let textRect = NSRect(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        badgeText.draw(in: textRect, withAttributes: attributes)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func badgeColor(for extensionLabel: String) -> NSColor {
        switch extensionLabel.uppercased() {
        case "JSON", "YAML", "YML":
            return NSColor.systemOrange
        case "MD", "TXT", "LOG":
            return NSColor.systemBlue
        case "SH", "ZSH", "BASH", "COMMAND":
            return NSColor.systemGreen
        case "ZIP", "TAR", "GZ", "TGZ":
            return NSColor.systemPurple
        case "PNG", "JPG", "JPEG", "GIF", "WEBP", "HEIC":
            return NSColor.systemPink
        case "PDF":
            return NSColor.systemRed
        default:
            return NSColor.systemTeal
        }
    }

    private static func isKnownImageExtension(_ fileExtension: String) -> Bool {
        [
            "avif", "bmp", "gif", "heic", "heif", "ico", "jpeg", "jpg", "png",
            "svg", "tif", "tiff", "webp"
        ].contains(fileExtension)
    }

    private static func isKnownVideoExtension(_ fileExtension: String) -> Bool {
        [
            "avi", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "webm", "wmv"
        ].contains(fileExtension)
    }

    private static func isKnownAudioExtension(_ fileExtension: String) -> Bool {
        [
            "aac", "aif", "aiff", "flac", "m4a", "mp3", "ogg", "opus", "wav"
        ].contains(fileExtension)
    }

    private static let knownLanguageByFileName: [String: String] = [
        ".bash_profile": "shell",
        ".bashrc": "shell",
        ".dockerignore": "ignore",
        ".editorconfig": "ini",
        ".env": "ini",
        ".gitattributes": "ignore",
        ".gitconfig": "ini",
        ".gitignore": "ignore",
        ".npmrc": "ini",
        ".dockerfile": "dockerfile",
        ".profile": "shell",
        ".vimrc": "plaintext",
        ".zprofile": "shell",
        ".zshenv": "shell",
        ".zshrc": "shell",
        "caddyfile": "plaintext",
        "containerfile": "dockerfile",
        "crontab": "ini",
        "fstab": "ini",
        "hostname": "ini",
        "hosts": "ini",
        "dockerfile": "dockerfile",
        "gemfile": "ruby",
        "limits.conf": "ini",
        "logrotate.conf": "ini",
        "makefile": "makefile",
        "chrony.conf": "ini",
        "dnf.conf": "ini",
        "ntp.conf": "ini",
        "procfile": "plaintext",
        "rakefile": "ruby",
        "resolv.conf": "ini",
        "ssh_config": "ini",
        "sshd_config": "ini",
        "sudoers": "ini",
        "sysctl.conf": "ini",
        "yum.conf": "ini",
        "vagrantfile": "ruby"
    ]

    private static let knownLanguageByExtension: [String: String] = [
        "bash": "shell",
        "bat": "bat",
        "c": "c",
        "cc": "cpp",
        "clj": "clojure",
        "cljs": "clojure",
        "cmd": "bat",
        "cpp": "cpp",
        "cs": "csharp",
        "css": "css",
        "csv": "csv",
        "dart": "dart",
        "dockerfile": "dockerfile",
        "ex": "elixir",
        "exs": "elixir",
        "fs": "fsharp",
        "fsx": "fsharp",
        "gql": "graphql",
        "go": "go",
        "graphql": "graphql",
        "h": "c",
        "hpp": "cpp",
        "htm": "html",
        "html": "html",
        "java": "java",
        "js": "javascript",
        "json": "json",
        "jsx": "javascript",
        "hcl": "hcl",
        "kt": "kotlin",
        "kts": "kotlin",
        "less": "less",
        "log": "plaintext",
        "lua": "lua",
        "m": "objective-c",
        "md": "markdown",
        "mm": "objective-c",
        "pl": "perl",
        "pm": "perl",
        "php": "php",
        "plist": "xml",
        "proto": "protobuf",
        "properties": "ini",
        "ps1": "powershell",
        "psd1": "powershell",
        "psm1": "powershell",
        "py": "python",
        "r": "r",
        "rmd": "markdown",
        "rb": "ruby",
        "rs": "rust",
        "sass": "scss",
        "scala": "scala",
        "scss": "scss",
        "sh": "shell",
        "sql": "sql",
        "swift": "swift",
        "tf": "hcl",
        "tfvars": "hcl",
        "toml": "toml",
        "ts": "typescript",
        "tsx": "typescript",
        "txt": "plaintext",
        "vue": "html",
        "xml": "xml",
        "zsh": "shell"
    ]

    private static func languageFromShebang(_ content: String) -> String? {
        guard content.hasPrefix("#!") else { return nil }
        let firstLine = content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        if firstLine.contains("python") { return "python" }
        if firstLine.contains("node") { return "javascript" }
        if firstLine.contains("ruby") { return "ruby" }
        if firstLine.contains("bash") || firstLine.contains("sh") || firstLine.contains("zsh") {
            return "shell"
        }
        return nil
    }
}

protocol StacioFileDisplayRow {
    var name: String { get }
    var isDirectory: Bool { get }
    var isHiddenItem: Bool { get }
}

extension StacioFileDisplayRow {
    var displayGroup: Int {
        if isHiddenItem {
            return 0
        }
        if isDirectory {
            return 1
        }
        return 2
    }
}
