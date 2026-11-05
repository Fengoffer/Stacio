import Foundation

/// oh-my-zsh 插件条目（从 vendored 快照扫描）。
// MARK: - 扫描结果静态缓存（跨实例共享；已安装资源版本/摘要是缓存键的一部分）

private let ohMyZshScanLock = NSLock()
private var ohMyZshPluginScanCache: [String: [OhMyZshPluginEntry]] = [:]
private var ohMyZshThemeScanCache: [String: [OhMyZshThemeEntry]] = [:]

public struct OhMyZshPluginEntry: Equatable, Sendable {
    public let name: String
    public let summary: String

    public init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }
}

/// oh-my-zsh 主题条目。
public struct OhMyZshThemeEntry: Equatable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// 扫描已验证的 Application Support oh-my-zsh 资源目录，提供插件/主题索引。
/// 目录缺失时返回空列表（如尚未下载资源）。测试或离线工具可显式注入目录。
public final class OhMyZshCatalog {
    private let directoryURL: URL?
    private var cachedPlugins: [OhMyZshPluginEntry]?
    private var cachedThemes: [OhMyZshThemeEntry]?
    private var cachedPluginSignature: String?
    private var cachedThemeSignature: String?

    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            self.directoryURL = OhMyZshResourceManager.shared.installedDirectoryURL
        }
    }

    public var isAvailable: Bool {
        guard let directoryURL else {
            return false
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public func plugins() -> [OhMyZshPluginEntry] {
        let key = Self.cacheKey(for: directoryURL)
        if let cachedPlugins, cachedPluginSignature == key {
            return cachedPlugins
        }
        ohMyZshScanLock.lock()
        defer { ohMyZshScanLock.unlock() }
        if let cached = ohMyZshPluginScanCache[key] {
            cachedPlugins = cached
            cachedPluginSignature = key
            return cached
        }
        let entries = Self.scanPlugins(directoryURL)
        ohMyZshPluginScanCache[key] = entries
        cachedPlugins = entries
        cachedPluginSignature = key
        return entries
    }

    public func themes() -> [OhMyZshThemeEntry] {
        let key = Self.cacheKey(for: directoryURL)
        if let cachedThemes, cachedThemeSignature == key {
            return cachedThemes
        }
        ohMyZshScanLock.lock()
        defer { ohMyZshScanLock.unlock() }
        if let cached = ohMyZshThemeScanCache[key] {
            cachedThemes = cached
            cachedThemeSignature = key
            return cached
        }
        let entries = Self.scanThemes(directoryURL)
        ohMyZshThemeScanCache[key] = entries
        cachedThemes = entries
        cachedThemeSignature = key
        return entries
    }

    public func containsPlugin(_ name: String) -> Bool {
        plugins().contains { $0.name == name }
    }

    public func containsTheme(_ name: String) -> Bool {
        themes().contains { $0.name == name }
    }

    public func pluginSummary(named name: String) -> String? {
        plugins().first { $0.name == name }?.summary
    }

    public static func defaultPluginNames() -> [String] {
        ["git"]
    }

    /// 后台预热静态扫描缓存（App 启动时调用）：打开设置时命中缓存，
    /// 避免首次在主线程扫描几百个插件目录并逐插件读 README。
    public static func warmCacheIfNeeded() {
        DispatchQueue.global(qos: .utility).async {
            _ = OhMyZshCatalog().plugins()
            _ = OhMyZshCatalog().themes()
        }
    }

    // MARK: - 扫描

    private static func cacheKey(for root: URL?) -> String {
        guard let root else { return "nil" }
        let fileManager = FileManager.default
        let markerNames = [
            OhMyZshResourceManager.versionMarkerFileName,
            OhMyZshResourceManager.manifestHashMarkerFileName,
            OhMyZshResourceManager.installTreeHashMarkerFileName
        ]
        let markers = markerNames.map { markerName -> String in
            let marker = root.appendingPathComponent(markerName)
            return (try? String(contentsOf: marker, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
        }
        let directoryStamp: String
        if let attributes = try? fileManager.attributesOfItem(atPath: root.path),
           let modificationDate = attributes[.modificationDate] as? Date {
            directoryStamp = "\(modificationDate.timeIntervalSince1970)"
        } else {
            directoryStamp = "missing"
        }
        return ([root.standardizedFileURL.path, directoryStamp] + markers).joined(separator: "|")
    }

    private static func scanPlugins(_ root: URL?) -> [OhMyZshPluginEntry] {
        guard let root else {
            return []
        }
        let pluginsRoot = root.appendingPathComponent("plugins", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: pluginsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.compactMap { pluginDirectory in
            let name = pluginDirectory.lastPathComponent
            // 与 oh-my-zsh.sh 的 is_plugin 一致：存在 <name>.plugin.zsh 或 _<name> 文件
            let hasPluginFile = FileManager.default.fileExists(
                atPath: pluginDirectory.appendingPathComponent("\(name).plugin.zsh").path
            )
            let hasCompletionFile = FileManager.default.fileExists(
                atPath: pluginDirectory.appendingPathComponent("_\(name)").path
            )
            guard hasPluginFile || hasCompletionFile else {
                return nil
            }
            return OhMyZshPluginEntry(name: name, summary: pluginSummary(pluginDirectory))
        }
        .sorted { $0.name < $1.name }
    }

    private static func pluginSummary(_ pluginDirectory: URL) -> String {
        let readme = pluginDirectory.appendingPathComponent("README.md")
        // 只读前 4KB 摘要（数百个插件 × 全文件 IO 会显著拖慢首次扫描）
        guard let data = try? Data(contentsOf: readme, options: .mappedIfSafe) else {
            return ""
        }
        // 字节级截断可能切断多字节 UTF-8 序列（中文 README 尾部会出现 �）；
        // 逐字节回退直到能完整解码（最多回退 3 字节）。
        var slice = data.prefix(4096)
        var content = ""
        while !slice.isEmpty {
            if let decoded = String(data: slice, encoding: .utf8) {
                content = decoded
                break
            }
            slice = slice.dropLast()
        }
        // UI 摘要只需首句：避免静态缓存长期持有数百条全量 README（内存上限可控）
        let contentForCache = String(content.prefix(200))
        let trimmed = contentForCache.trimmingCharacters(in: .whitespacesAndNewlines)
        // 跳过标题行，取首个非空段落首句
        let lines = trimmed.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for line in lines {
            if line.hasPrefix("#") || line.isEmpty {
                continue
            }
            let sentence = line.components(separatedBy: ". ").first ?? line
            return String(sentence.prefix(120))
        }
        return ""
    }

    private static func scanThemes(_ root: URL?) -> [OhMyZshThemeEntry] {
        guard let root else {
            return []
        }
        let themesRoot = root.appendingPathComponent("themes", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: themesRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension == "zsh-theme" }
            .map { OhMyZshThemeEntry(name: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.name < $1.name }
    }
}
