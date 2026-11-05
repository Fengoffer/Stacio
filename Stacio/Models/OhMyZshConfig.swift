import Foundation

/// 会话级 oh-my-zsh 配置（存储在 Session.configJSON 的 `ohmyzsh` 块中）。
/// 与 `SessionAutomationPolicy` 相互独立，避免耦合。
public struct OhMyZshSessionConfig: Equatable, Sendable {
    /// 是否覆盖全局默认配置；为 false 时完全继承全局（字段级无效）。
    public var overrideDefaults: Bool
    public var enabled: Bool?
    public var theme: String?
    public var plugins: [String]?

    public init(
        overrideDefaults: Bool = false,
        enabled: Bool? = nil,
        theme: String? = nil,
        plugins: [String]? = nil
    ) {
        self.overrideDefaults = overrideDefaults
        self.enabled = enabled
        self.theme = Self.normalizedOptionalString(theme)
        self.plugins = Self.normalizedPlugins(plugins)
    }

    public static let `default` = OhMyZshSessionConfig()

    // MARK: - configJSON 解析/序列化（与 SessionAutomationPolicy 一致的 JSONSerialization 风格）

    public static func fromConfigJSON(_ configJSON: String?) -> OhMyZshSessionConfig {
        guard let configJSON,
              let data = configJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = object["ohmyzsh"] as? [String: Any]
        else {
            return .default
        }
        return OhMyZshSessionConfig(
            overrideDefaults: block["overrideDefaults"] as? Bool ?? false,
            enabled: block["enabled"] as? Bool,
            theme: block["theme"] as? String,
            plugins: Self.stringArray(block["plugins"])
        )
    }

    /// 将配置写回 configJSON（返回新 JSON；若全部为默认值则返回原 JSON 或 nil）。
    public static func serializedJSON(mergingInto configJSON: String?, session: OhMyZshSessionConfig) -> String? {
        let object: [String: Any]
        if let configJSON,
           let data = configJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = parsed
        } else {
            object = [:]
        }

        var block: [String: Any] = ["overrideDefaults": session.overrideDefaults]
        if let enabled = session.enabled {
            block["enabled"] = enabled
        }
        if let theme = session.theme, !theme.isEmpty {
            block["theme"] = theme
        }
        if let plugins = session.plugins, !plugins.isEmpty {
            block["plugins"] = plugins
        }
        if session.overrideDefaults == false {
            // 未勾选"覆盖全局"时字段无效：不写 ohmyzsh 块，保持 configJSON 干净（与 UI 语义一致）
            var merged = object
            merged.removeValue(forKey: "ohmyzsh")
            return serialized(merged)
        }

        var merged = object
        merged["ohmyzsh"] = block
        return serialized(merged)
    }

    private static func serialized(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func stringArray(_ value: Any?) -> [String]? {
        guard let array = value as? [Any] else {
            return nil
        }
        let strings = array.compactMap { $0 as? String }
        let normalized = strings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedOptionalString(_ value: String?) -> String? {
        (value?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func normalizedPlugins(_ plugins: [String]?) -> [String]? {
        guard let plugins else {
            return nil
        }
        let normalized = plugins.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return normalized.isEmpty ? nil : normalized
    }
}

/// 合并全局默认与会话覆盖后的最终 oh-my-zsh 配置。
public struct OhMyZshResolvedConfig: Equatable, Sendable {
    public let enabled: Bool
    public let theme: String
    public let plugins: [String]
    public let extraZshrcLines: String?

    public init(enabled: Bool, theme: String, plugins: [String], extraZshrcLines: String?) {
        self.enabled = enabled
        self.theme = theme.isEmpty ? "robbyrussell" : theme
        self.plugins = plugins.isEmpty ? ["git"] : plugins
        self.extraZshrcLines = extraZshrcLines
    }
}

/// 纯函数：合并全局默认与会话覆盖，渲染/替换/删除 .zshrc 区块。
public enum OhMyZshConfigResolver {
    public static let defaultThemeName = "robbyrussell"
    public static let blockStartMarker = "# >>> STACIO OH-MY-ZSH >>>"
    public static let blockEndMarker = "# <<< STACIO OH-MY-ZSH <<<"

    /// 会话覆盖启用时字段级覆盖（nil 字段继承全局），否则完全继承全局。
    public static func resolve(
        global: AppSettings,
        session: OhMyZshSessionConfig
    ) -> OhMyZshResolvedConfig {
        if session.overrideDefaults {
            return OhMyZshResolvedConfig(
                enabled: session.enabled ?? global.ohmyzshEnabled,
                theme: session.theme ?? global.ohmyzshTheme ?? defaultThemeName,
                plugins: session.plugins ?? global.ohmyzshPlugins,
                extraZshrcLines: global.ohmyzshExtraZshrcLines
            )
        }
        return OhMyZshResolvedConfig(
            enabled: global.ohmyzshEnabled,
            theme: global.ohmyzshTheme ?? defaultThemeName,
            plugins: global.ohmyzshPlugins,
            extraZshrcLines: global.ohmyzshExtraZshrcLines
        )
    }

    // MARK: - .zshrc 区块渲染

    public static func renderZshrcBlock(config: OhMyZshResolvedConfig) -> String {
        var lines: [String] = []
        lines.append(blockStartMarker)
        lines.append("export ZSH=\"$HOME/.oh-my-zsh\"")
        lines.append("ZSH_THEME=\"\(sanitizedToken(config.theme, fallback: defaultThemeName))\"")
        lines.append("plugins=(\(config.plugins.map { sanitizedToken($0, fallback: "git") }.joined(separator: " ")))")
        lines.append("zstyle ':omz:update' mode disabled")
        if let extra = config.extraZshrcLines, !extra.isEmpty {
            // 过滤可能破坏区块边界的标记行（防注入/误判）
            let filtered = extra.components(separatedBy: .newlines)
                .filter { !$0.contains(blockStartMarker) && !$0.contains(blockEndMarker) }
                .joined(separator: "\n")
            if !filtered.isEmpty {
                lines.append(filtered)
            }
        }
        lines.append("source \"$ZSH/oh-my-zsh.sh\"")
        lines.append(blockEndMarker)
        return lines.joined(separator: "\n")
    }

    /// 幂等写入：已存在 Stacio 区块则原位替换（多份时合并为一份），否则追加到文件末尾。
    /// 非破坏式：用户原有 .zshrc 内容完全保留。
    public static func upsertBlock(in zshrc: String, config: OhMyZshResolvedConfig) -> String {
        let block = renderZshrcBlock(config: config)
        // 收集原始串上全部既有区块 range（UTF-16 搜索，从后往前改索引不受影响）
        let ranges = allBlockRanges(in: zshrc)
        guard !ranges.isEmpty else {
            // 追加分支
            var result = zshrc
            if !result.isEmpty && !result.hasSuffix("\n") {
                result += "\n"
            }
            if !result.isEmpty {
                result += "\n"
            }
            result += block
            if !result.hasSuffix("\n") {
                result += "\n"
            }
            return result
        }
        var result = zshrc
        // 从后往前：第一份（ranges.first）替换为新 block，其余旧份删除（合并为一份，避免双 source/主题冲突）
        for range in ranges.dropFirst().reversed() {
            result.removeSubrange(range)
        }
        // 第一份替换：range 已含区块后的换行，必须补回尾换行，否则结束标记与下一用户行拼接（被 zsh 当注释吞掉）
        let first = ranges[0]
        result.replaceSubrange(first, with: block + "\n")
        return result
    }

    /// 删除 Stacio 区块（循环删除全部，仅移除区块本身，保留用户其他内容）。
    public static func removeBlock(from zshrc: String) -> String {
        var result = zshrc
        for range in allBlockRanges(in: zshrc).reversed() {
            result.removeSubrange(range)
        }
        // 清理区块移除后留下的多余空行
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result
    }

    /// 收集 .zshrc 中全部 Stacio 区块 range（基于 NSString 全串搜索，UTF-16 单位换算正确；
    /// 起标记缺结束标记的残块跳过，避免误删用户内容）。
    static func allBlockRanges(in zshrc: String) -> [Range<String.Index>] {
        let ns = zshrc as NSString
        var ranges: [Range<String.Index>] = []
        var searchLocation = 0
        while searchLocation < ns.length {
            let startRange = ns.range(
                of: blockStartMarker,
                options: [],
                range: NSRange(location: searchLocation, length: ns.length - searchLocation)
            )
            guard startRange.location != NSNotFound else { break }
            let endSearchLocation = startRange.location + startRange.length
            let endRange = ns.range(
                of: blockEndMarker,
                options: [],
                range: NSRange(location: endSearchLocation, length: ns.length - endSearchLocation)
            )
            guard endRange.location != NSNotFound else { break }
            let start = String.Index(utf16Offset: startRange.location, in: zshrc)
            var end = String.Index(utf16Offset: endRange.location + endRange.length, in: zshrc)
            // 含区块后的换行（兼容 LF 与 CRLF）
            if end < zshrc.endIndex {
                let rest = zshrc[end...]
                if rest.first == "\n" {
                    end = zshrc.index(after: end)
                } else if rest.first == "\r", rest.dropFirst().first == "\n" {
                    end = zshrc.index(end, offsetBy: 2)
                }
            }
            ranges.append(start..<end)
            searchLocation = endRange.location + endRange.length + 1
        }
        return ranges
    }

    /// 检测 .zshrc 是否已含 Stacio 区块（供部署状态判断）。
    public static func containsBlock(in zshrc: String) -> Bool {
        existingBlockRange(in: zshrc) != nil
    }

    /// 找到 Stacio 区块范围（按起止标记定位；找不到起标记或结束标记视为无效区块，返回 nil 以免误删用户内容）。
    /// 注意：`range(of:)` 的 NSRange 单位为 UTF-16，必须用 `String.Index(utf16Offset:)` 换算（marker 为 ASCII，落在字符边界安全）。
    static func existingBlockRange(in zshrc: String) -> Range<String.Index>? {
        let nsRange = (zshrc as NSString).range(of: blockStartMarker)
        guard nsRange.location != NSNotFound else {
            return nil
        }
        let start = String.Index(utf16Offset: nsRange.location, in: zshrc)
        let endMarkerSearch = zshrc[start...]
        guard let endMarkerRange = endMarkerSearch.range(of: blockEndMarker) else {
            return nil
        }
        let blockEnd = endMarkerRange.upperBound
        // 包含区块后的换行，避免残留空行；兼容 LF 与 CRLF（CRLF 时跳过 \r\n 两个字符）
        var finalEnd = blockEnd
        if blockEnd < zshrc.endIndex, zshrc[blockEnd] == "\n" {
            finalEnd = zshrc.index(after: blockEnd)
        } else if blockEnd < zshrc.endIndex, zshrc[blockEnd] == "\r",
                  zshrc.index(after: blockEnd) < zshrc.endIndex,
                  zshrc[zshrc.index(after: blockEnd)] == "\n" {
            finalEnd = zshrc.index(blockEnd, offsetBy: 2)
        }
        return start..<finalEnd
    }

    /// 主题/插件名白名单：仅允许文件名风格字符，防止注入 .zshrc。
    public static func sanitizedToken(_ value: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = value.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
        return sanitized.isEmpty ? fallback : sanitized
    }
}
