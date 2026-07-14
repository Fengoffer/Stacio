import AppKit
import Foundation
import SwiftTerm

public enum TerminalThemeSourceFormat: String, Codable, Equatable {
    case portDesk
    case kitty
    case ghostty
    case alacritty
    case wezTerm
    case windowsTerminal
    case iterm2

    public var displayName: String {
        switch self {
        case .portDesk:
            return "Stacio"
        case .kitty:
            return "Kitty"
        case .ghostty:
            return "Ghostty"
        case .alacritty:
            return "Alacritty"
        case .wezTerm:
            return "WezTerm"
        case .windowsTerminal:
            return "Windows Terminal"
        case .iterm2:
            return "iTerm2"
        }
    }
}

public struct TerminalColorTheme: Codable, Equatable {
    public var id: String?
    public var name: String
    public var sourceFormat: TerminalThemeSourceFormat
    public var foregroundHex: String
    public var backgroundHex: String
    public var cursorHex: String?
    public var selectionBackgroundHex: String?
    public var ansiColorHexes: [String]

    public init(
        id: String? = nil,
        name: String,
        sourceFormat: TerminalThemeSourceFormat,
        foregroundHex: String,
        backgroundHex: String,
        cursorHex: String? = nil,
        selectionBackgroundHex: String? = nil,
        ansiColorHexes: [String]
    ) {
        self.id = id
        self.name = name
        self.sourceFormat = sourceFormat
        self.foregroundHex = TerminalThemeColor.normalizeHex(foregroundHex) ?? "#FFFFFF"
        self.backgroundHex = TerminalThemeColor.normalizeHex(backgroundHex) ?? "#000000"
        self.cursorHex = cursorHex.flatMap(TerminalThemeColor.normalizeHex)
        self.selectionBackgroundHex = selectionBackgroundHex.flatMap(TerminalThemeColor.normalizeHex)
        self.ansiColorHexes = TerminalColorTheme.normalizedAnsiColors(ansiColorHexes)
    }

    public static let portDeskDark = TerminalColorTheme(
        id: "stacio-dark",
        name: "Stacio Dark",
        sourceFormat: .portDesk,
        foregroundHex: "#F5F5F5",
        backgroundHex: "#000000",
        cursorHex: "#F5F5F5",
        selectionBackgroundHex: "#264F78",
        ansiColorHexes: [
            "#000000", "#C23621", "#25BC24", "#ADAD27",
            "#492EE1", "#D338D3", "#33BBC8", "#CBCCCD",
            "#818383", "#FC391F", "#31E722", "#EAEC23",
            "#5833FF", "#F935F8", "#14F0F0", "#E9EBEB"
        ]
    )

    public static let portDeskDefaultCustom = TerminalColorTheme(
        name: "Stacio Custom",
        sourceFormat: .portDesk,
        foregroundHex: portDeskDark.foregroundHex,
        backgroundHex: portDeskDark.backgroundHex,
        cursorHex: portDeskDark.cursorHex,
        selectionBackgroundHex: portDeskDark.selectionBackgroundHex,
        ansiColorHexes: portDeskDark.ansiColorHexes
    )

    public static let systemAdaptivePreview = TerminalColorTheme(
        id: "system-adaptive",
        name: "System Adaptive",
        sourceFormat: .portDesk,
        foregroundHex: "#1D1D1F",
        backgroundHex: "#FFFFFF",
        cursorHex: "#1D1D1F",
        selectionBackgroundHex: "#BBD7FF",
        ansiColorHexes: [
            "#1D1D1F", "#C9352B", "#1F7A38", "#8A6D00",
            "#0057B8", "#7C3AED", "#007A78", "#3C3C43",
            "#6E6E73", "#C9352B", "#1F7A38", "#B45309",
            "#0057B8", "#7C3AED", "#007A78", "#FFFFFF"
        ]
    )

    public static let solarizedDark = TerminalColorTheme(
        id: "solarized-dark",
        name: "Solarized Dark",
        sourceFormat: .portDesk,
        foregroundHex: "#839496",
        backgroundHex: "#002B36",
        cursorHex: "#93A1A1",
        selectionBackgroundHex: "#073642",
        ansiColorHexes: [
            "#073642", "#DC322F", "#859900", "#B58900",
            "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
            "#002B36", "#CB4B16", "#586E75", "#657B83",
            "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"
        ]
    )

    public static let solarizedLight = TerminalColorTheme(
        id: "solarized-light",
        name: "Solarized Light",
        sourceFormat: .portDesk,
        foregroundHex: "#586E75",
        backgroundHex: "#FDF6E3",
        cursorHex: "#657B83",
        selectionBackgroundHex: "#EEE8D5",
        ansiColorHexes: [
            "#073642", "#DC322F", "#859900", "#B58900",
            "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
            "#002B36", "#CB4B16", "#586E75", "#657B83",
            "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"
        ]
    )

    public static let nordicOps = TerminalColorTheme(
        id: "nordic-ops",
        name: "Nordic Ops",
        sourceFormat: .portDesk,
        foregroundHex: "#D8DEE9",
        backgroundHex: "#2E3440",
        cursorHex: "#88C0D0",
        selectionBackgroundHex: "#434C5E",
        ansiColorHexes: [
            "#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B",
            "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
            "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B",
            "#5E81AC", "#B48EAD", "#8FBCBB", "#ECEFF4"
        ]
    )

    public static let graphite = TerminalColorTheme(
        id: "graphite",
        name: "Graphite",
        sourceFormat: .portDesk,
        foregroundHex: "#E6E8EB",
        backgroundHex: "#111316",
        cursorHex: "#F2B84B",
        selectionBackgroundHex: "#2C3138",
        ansiColorHexes: [
            "#111316", "#D75F5F", "#77B869", "#D9B66F",
            "#6EA6D7", "#B389D6", "#62B8B0", "#D8DEE9",
            "#5C6370", "#E06C75", "#98C379", "#E5C07B",
            "#61AFEF", "#C678DD", "#56B6C2", "#F2F4F8"
        ]
    )

    public static let emberTerminal = TerminalColorTheme(
        id: "ember-terminal",
        name: "Ember Terminal",
        sourceFormat: .portDesk,
        foregroundHex: "#F1E7D0",
        backgroundHex: "#1C1713",
        cursorHex: "#FFB86B",
        selectionBackgroundHex: "#3A2B20",
        ansiColorHexes: [
            "#1C1713", "#E06C62", "#8FB573", "#D6A657",
            "#7DA6C8", "#B58ACB", "#7BC4A8", "#E8DCC3",
            "#6E5F52", "#F0786F", "#A3C585", "#E7B868",
            "#8EB9D9", "#C49ADC", "#8FD8BB", "#FFF1D6"
        ]
    )

    public static let nightOwl = TerminalColorTheme(
        id: "night-owl",
        name: "Night Owl",
        sourceFormat: .portDesk,
        foregroundHex: "#D6DEEB",
        backgroundHex: "#011627",
        cursorHex: "#80A4C2",
        selectionBackgroundHex: "#1D3B53",
        ansiColorHexes: [
            "#011627", "#EF5350", "#22DA6E", "#C5E478",
            "#82AAFF", "#C792EA", "#21C7A8", "#FFFFFF",
            "#575656", "#EF5350", "#22DA6E", "#FFEB95",
            "#82AAFF", "#C792EA", "#7FDBCA", "#FFFFFF"
        ]
    )

    public static let kanagawaWave = TerminalColorTheme(
        id: "kanagawa-wave",
        name: "Kanagawa Wave",
        sourceFormat: .portDesk,
        foregroundHex: "#DCD7BA",
        backgroundHex: "#1F1F28",
        cursorHex: "#C8C093",
        selectionBackgroundHex: "#2D4F67",
        ansiColorHexes: [
            "#16161D", "#C34043", "#76946A", "#C0A36E",
            "#7E9CD8", "#957FB8", "#6A9589", "#C8C093",
            "#727169", "#E82424", "#98BB6C", "#E6C384",
            "#7FB4CA", "#938AA9", "#7AA89F", "#DCD7BA"
        ]
    )

    public static let catppuccinMocha = TerminalColorTheme(
        id: "catppuccin-mocha",
        name: "Catppuccin Mocha",
        sourceFormat: .portDesk,
        foregroundHex: "#CDD6F4",
        backgroundHex: "#1E1E2E",
        cursorHex: "#F5E0DC",
        selectionBackgroundHex: "#45475A",
        ansiColorHexes: [
            "#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF",
            "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
            "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF",
            "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8"
        ]
    )

    public static let cobalt2 = TerminalColorTheme(
        id: "cobalt2",
        name: "Cobalt2",
        sourceFormat: .portDesk,
        foregroundHex: "#FFFFFF",
        backgroundHex: "#122637",
        cursorHex: "#FFC600",
        selectionBackgroundHex: "#214D65",
        ansiColorHexes: [
            "#000000", "#FF0000", "#37DD21", "#F0CC09",
            "#1460D2", "#FF005D", "#00BBBB", "#BBBBBB",
            "#545454", "#F40D17", "#3BCF1D", "#ECC809",
            "#5555FF", "#FF55FF", "#6AE3FA", "#FFFFFF"
        ]
    )

    public static let rosePine = TerminalColorTheme(
        id: "rose-pine",
        name: "Rose Pine",
        sourceFormat: .portDesk,
        foregroundHex: "#E0DEF4",
        backgroundHex: "#191724",
        cursorHex: "#C4A7E7",
        selectionBackgroundHex: "#403D52",
        ansiColorHexes: [
            "#26233A", "#EB6F92", "#31748F", "#F6C177",
            "#9CCFD8", "#C4A7E7", "#EBBCBA", "#E0DEF4",
            "#6E6A86", "#EB6F92", "#31748F", "#F6C177",
            "#9CCFD8", "#C4A7E7", "#EBBCBA", "#E0DEF4"
        ]
    )

    public static let flexokiDark = TerminalColorTheme(
        id: "flexoki-dark",
        name: "Flexoki Dark",
        sourceFormat: .portDesk,
        foregroundHex: "#CECDC3",
        backgroundHex: "#100F0F",
        cursorHex: "#DAD8CE",
        selectionBackgroundHex: "#343331",
        ansiColorHexes: [
            "#100F0F", "#AF3029", "#66800B", "#AD8301",
            "#205EA6", "#A02F6F", "#24837B", "#CECDC3",
            "#575653", "#D14D41", "#879A39", "#D0A215",
            "#4385BE", "#CE5D97", "#3AA99F", "#FFFCF0"
        ]
    )

    public static let hackerGreen = TerminalColorTheme(
        id: "hacker-green",
        name: "Hacker Green",
        sourceFormat: .portDesk,
        foregroundHex: "#00FF66",
        backgroundHex: "#050305",
        cursorHex: "#39FF14",
        selectionBackgroundHex: "#113B21",
        ansiColorHexes: [
            "#050305", "#FF4D4D", "#00FF66", "#C8FF5A",
            "#40BFFF", "#FF4DF3", "#00E5B0", "#D7FFD7",
            "#3A4A3A", "#FF6B6B", "#64FF8F", "#E0FF70",
            "#64C8FF", "#FF75F6", "#46FFD0", "#FFFFFF"
        ]
    )

    public static let cyberpunk = TerminalColorTheme(
        id: "cyberpunk",
        name: "Cyberpunk",
        sourceFormat: .portDesk,
        foregroundHex: "#F8F8F2",
        backgroundHex: "#16002B",
        cursorHex: "#00F5FF",
        selectionBackgroundHex: "#3D176A",
        ansiColorHexes: [
            "#16002B", "#FF2A6D", "#05FFA1", "#F9F002",
            "#00C2FF", "#D300C5", "#00F5FF", "#F8F8F2",
            "#5D3A7A", "#FF5C8A", "#4DFFB8", "#FFF56A",
            "#62D8FF", "#FF6BE7", "#60FFF5", "#FFFFFF"
        ]
    )

    public static let tokyoNight = TerminalColorTheme(
        id: "tokyo-night",
        name: "Tokyo Night",
        sourceFormat: .portDesk,
        foregroundHex: "#C0CAF5",
        backgroundHex: "#1A1B26",
        cursorHex: "#C0CAF5",
        selectionBackgroundHex: "#33467C",
        ansiColorHexes: [
            "#15161E", "#F7768E", "#9ECE6A", "#E0AF68",
            "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
            "#414868", "#F7768E", "#9ECE6A", "#E0AF68",
            "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5"
        ]
    )

    public static let gruvboxDark = TerminalColorTheme(
        id: "gruvbox-dark",
        name: "Gruvbox Dark",
        sourceFormat: .portDesk,
        foregroundHex: "#EBDBB2",
        backgroundHex: "#282828",
        cursorHex: "#EBDBB2",
        selectionBackgroundHex: "#504945",
        ansiColorHexes: [
            "#282828", "#CC241D", "#98971A", "#D79921",
            "#458588", "#B16286", "#689D6A", "#A89984",
            "#928374", "#FB4934", "#B8BB26", "#FABD2F",
            "#83A598", "#D3869B", "#8EC07C", "#EBDBB2"
        ]
    )

    public static let builtInThemes: [TerminalColorTheme] = [
        portDeskDark,
        solarizedDark,
        solarizedLight,
        nordicOps,
        graphite,
        emberTerminal,
        nightOwl,
        kanagawaWave,
        catppuccinMocha,
        cobalt2,
        rosePine,
        flexokiDark,
        hackerGreen,
        cyberpunk,
        tokyoNight,
        gruvboxDark
    ]

    public static func builtInTheme(id: String?) -> TerminalColorTheme? {
        guard let id else { return nil }
        return builtInThemes.first { $0.id == id }
    }

    public static func resolvedBuiltInTheme(id: String?) -> TerminalColorTheme {
        builtInTheme(id: id) ?? portDeskDark
    }

    public var foregroundColor: NSColor { TerminalThemeColor.nsColor(from: foregroundHex) ?? .white }
    public var backgroundColor: NSColor { TerminalThemeColor.nsColor(from: backgroundHex) ?? .black }
    public var cursorColor: NSColor? { cursorHex.flatMap(TerminalThemeColor.nsColor(from:)) }
    public var selectionBackgroundColor: NSColor? { selectionBackgroundHex.flatMap(TerminalThemeColor.nsColor(from:)) }

    public func ansiColor(at index: Int, fallback: NSColor) -> NSColor {
        guard ansiColorHexes.indices.contains(index) else {
            return fallback
        }
        return TerminalThemeColor.nsColor(from: ansiColorHexes[index]) ?? fallback
    }

    public var swiftTermAnsiColors: [SwiftTerm.Color] {
        ansiColorHexes.map { TerminalThemeColor.swiftTermColor(from: $0) ?? SwiftTerm.Color(red: 0, green: 0, blue: 0) }
    }

    private static func normalizedAnsiColors(_ colors: [String]) -> [String] {
        var normalized = colors.compactMap(TerminalThemeColor.normalizeHex)
        if normalized.count > 16 {
            normalized = Array(normalized.prefix(16))
        }
        let fallback = portDeskAnsiFallback
        while normalized.count < 16 {
            normalized.append(fallback[normalized.count])
        }
        return normalized
    }

    private static let portDeskAnsiFallback = [
        "#000000", "#C23621", "#25BC24", "#ADAD27",
        "#492EE1", "#D338D3", "#33BBC8", "#CBCCCD",
        "#818383", "#FC391F", "#31E722", "#EAEC23",
        "#5833FF", "#F935F8", "#14F0F0", "#E9EBEB"
    ]
}

public enum TerminalThemeImportError: Error, LocalizedError, Equatable {
    case unsupportedFormat
    case invalidData
    case missingRequiredColors

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "不支持的终端主题格式"
        case .invalidData:
            return "主题文件内容无法解析"
        case .missingRequiredColors:
            return "主题缺少前景色、背景色或 ANSI 调色板"
        }
    }
}

public enum TerminalThemeExporter {
    public static func exportStacioTheme(_ theme: TerminalColorTheme) throws -> Data {
        let portDeskTheme = TerminalColorTheme(
            name: theme.name,
            sourceFormat: .portDesk,
            foregroundHex: theme.foregroundHex,
            backgroundHex: theme.backgroundHex,
            cursorHex: theme.cursorHex,
            selectionBackgroundHex: theme.selectionBackgroundHex,
            ansiColorHexes: theme.ansiColorHexes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(portDeskTheme)
    }
}

public enum TerminalThemeImporter {
    public static func importTheme(
        data: Data,
        suggestedName: String?,
        fileExtension: String?
    ) throws -> TerminalColorTheme {
        let normalizedExtension = fileExtension?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if normalizedExtension == "staciotheme" {
            return try importStacioJSON(data: data, suggestedName: suggestedName)
        }

        if normalizedExtension == "itermcolors" {
            return try importITerm2(data: data, suggestedName: suggestedName)
        }

        if normalizedExtension == "json" {
            if let theme = try? importStacioJSON(data: data, suggestedName: suggestedName) {
                return theme
            }
            return try importWindowsTerminalJSON(data: data, suggestedName: suggestedName)
        }

        guard let source = String(data: data, encoding: .utf8) else {
            throw TerminalThemeImportError.invalidData
        }
        if looksLikeAlacrittyOrWezTerm(source) {
            let format: TerminalThemeSourceFormat = looksLikeWezTerm(source) ? .wezTerm : .alacritty
            return try importTomlLike(source, suggestedName: suggestedName, sourceFormat: format)
        }
        return try importKeyValueTheme(source, suggestedName: suggestedName, preferredFormat: normalizedExtension)
    }

    private static func importStacioJSON(data: Data, suggestedName: String?) throws -> TerminalColorTheme {
        do {
            let decoded = try JSONDecoder().decode(TerminalColorTheme.self, from: data)
            return TerminalColorTheme(
                name: suggestedName.nilIfBlank ?? decoded.name,
                sourceFormat: .portDesk,
                foregroundHex: decoded.foregroundHex,
                backgroundHex: decoded.backgroundHex,
                cursorHex: decoded.cursorHex,
                selectionBackgroundHex: decoded.selectionBackgroundHex,
                ansiColorHexes: decoded.ansiColorHexes
            )
        } catch {
            throw TerminalThemeImportError.invalidData
        }
    }

    private static func importWindowsTerminalJSON(data: Data, suggestedName: String?) throws -> TerminalColorTheme {
        let object = try JSONSerialization.jsonObject(with: data)
        let scheme: [String: Any]
        if let dictionary = object as? [String: Any],
           let schemes = dictionary["schemes"] as? [[String: Any]],
           let first = schemes.first {
            scheme = first
        } else if let dictionary = object as? [String: Any] {
            scheme = dictionary
        } else {
            throw TerminalThemeImportError.invalidData
        }

        let ansiKeys = [
            "black", "red", "green", "yellow", "blue", "purple", "cyan", "white",
            "brightBlack", "brightRed", "brightGreen", "brightYellow",
            "brightBlue", "brightPurple", "brightCyan", "brightWhite"
        ]
        let ansiColors = ansiKeys.compactMap { stringValue(scheme[$0]).flatMap(TerminalThemeColor.normalizeHex) }
        guard let foreground = stringValue(scheme["foreground"]).flatMap(TerminalThemeColor.normalizeHex),
              let background = stringValue(scheme["background"]).flatMap(TerminalThemeColor.normalizeHex),
              ansiColors.count == 16
        else {
            throw TerminalThemeImportError.missingRequiredColors
        }

        return TerminalColorTheme(
            name: suggestedName.nilIfBlank ?? stringValue(scheme["name"]).nilIfBlank ?? "Windows Terminal Theme",
            sourceFormat: .windowsTerminal,
            foregroundHex: foreground,
            backgroundHex: background,
            cursorHex: stringValue(scheme["cursorColor"]),
            selectionBackgroundHex: stringValue(scheme["selectionBackground"]),
            ansiColorHexes: ansiColors
        )
    }

    private static func importITerm2(data: Data, suggestedName: String?) throws -> TerminalColorTheme {
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw TerminalThemeImportError.invalidData
        }

        var ansiColors: [String] = []
        for index in 0..<16 {
            guard let color = plist["Ansi \(index) Color"].flatMap(plistColorHex) else {
                ansiColors.append(TerminalColorTheme.portDeskDark.ansiColorHexes[index])
                continue
            }
            ansiColors.append(color)
        }

        guard let foreground = plist["Foreground Color"].flatMap(plistColorHex),
              let background = plist["Background Color"].flatMap(plistColorHex)
        else {
            throw TerminalThemeImportError.missingRequiredColors
        }

        return TerminalColorTheme(
            name: suggestedName.nilIfBlank ?? "iTerm2 Theme",
            sourceFormat: .iterm2,
            foregroundHex: foreground,
            backgroundHex: background,
            cursorHex: plist["Cursor Color"].flatMap(plistColorHex),
            selectionBackgroundHex: plist["Selection Color"].flatMap(plistColorHex),
            ansiColorHexes: ansiColors
        )
    }

    private static func importKeyValueTheme(
        _ source: String,
        suggestedName: String?,
        preferredFormat: String?
    ) throws -> TerminalColorTheme {
        let pairs = parseKeyValueLines(source)
        let sourceFormat: TerminalThemeSourceFormat = preferredFormat == "ghostty" || pairs.keys.contains("palette")
            ? .ghostty
            : .kitty
        let palette = paletteFromKeyValuePairs(pairs)
        guard let foreground = value(for: ["foreground"], in: pairs),
              let background = value(for: ["background"], in: pairs),
              palette.count == 16
        else {
            throw TerminalThemeImportError.missingRequiredColors
        }

        return TerminalColorTheme(
            name: suggestedName.nilIfBlank ?? sourceFormat.defaultThemeName,
            sourceFormat: sourceFormat,
            foregroundHex: foreground,
            backgroundHex: background,
            cursorHex: value(for: ["cursor", "cursor-color"], in: pairs),
            selectionBackgroundHex: value(for: ["selection_background", "selection-background"], in: pairs),
            ansiColorHexes: palette
        )
    }

    private static func importTomlLike(
        _ source: String,
        suggestedName: String?,
        sourceFormat: TerminalThemeSourceFormat
    ) throws -> TerminalColorTheme {
        let values = parseTomlLike(source)
        let palette = tomlPalette(from: values)
        guard let foreground = values["colors.primary.foreground"] ?? values["colors.foreground"],
              let background = values["colors.primary.background"] ?? values["colors.background"],
              palette.count == 16
        else {
            throw TerminalThemeImportError.missingRequiredColors
        }

        return TerminalColorTheme(
            name: suggestedName.nilIfBlank ?? sourceFormat.defaultThemeName,
            sourceFormat: sourceFormat,
            foregroundHex: foreground,
            backgroundHex: background,
            cursorHex: values["colors.cursor.cursor"] ?? values["colors.cursor_color"] ?? values["colors.cursor_bg"],
            selectionBackgroundHex: values["colors.selection.background"] ?? values["colors.selection_background"] ?? values["colors.selection_bg"],
            ansiColorHexes: palette
        )
    }

    private static func looksLikeAlacrittyOrWezTerm(_ source: String) -> Bool {
        source.contains("[colors.primary]")
            || source.contains("[colors.normal]")
            || source.contains("[colors]")
    }

    private static func looksLikeWezTerm(_ source: String) -> Bool {
        source.contains("color_schemes")
            || source.contains("ansi = [")
            || source.contains("brights = [")
            || source.contains("cursor_bg")
            || source.contains("selection_bg")
    }

    private static func parseKeyValueLines(_ source: String) -> [String: [String]] {
        var pairs: [String: [String]] = [:]
        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false, line.hasPrefix("#") == false else { continue }
            let parts: [String]
            if line.contains("=") {
                parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            } else {
                parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            }
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = stripInlineComment(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            pairs[key, default: []].append(value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
        }
        return pairs
    }

    private static func parseTomlLike(_ source: String) -> [String: String] {
        var section = ""
        var values: [String: String] = [:]
        var arrayKey: String?
        var arrayValues: [String] = []
        for rawLine in source.components(separatedBy: .newlines) {
            let line = stripInlineComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false else { continue }
            if let key = arrayKey {
                arrayValues.append(line)
                if line.contains("]") {
                    values[key] = arrayValues.joined(separator: " ")
                    arrayKey = nil
                    arrayValues = []
                }
                continue
            }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let qualifiedKey = section.isEmpty ? key : "\(section).\(key)"
            let rawValue = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if rawValue.hasPrefix("["), rawValue.contains("]") == false {
                arrayKey = qualifiedKey
                arrayValues = [rawValue]
                continue
            }
            let value = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            values[qualifiedKey] = value
        }
        return values
    }

    private static func tomlPalette(from values: [String: String]) -> [String] {
        let namedPalette = ansiNames.compactMap { values["colors.normal.\($0)"] }
            + ansiNames.compactMap { values["colors.bright.\($0)"] }
        if namedPalette.count == 16 {
            return namedPalette
        }

        let ansi = hexArray(values["colors.ansi"])
        let brights = hexArray(values["colors.brights"])
        if ansi.count + brights.count == 16 {
            return ansi + brights
        }
        return namedPalette
    }

    private static func hexArray(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .components(separatedBy: CharacterSet(charactersIn: "[],"))
            .compactMap { TerminalThemeColor.normalizeHex($0) }
    }

    private static func paletteFromKeyValuePairs(_ pairs: [String: [String]]) -> [String] {
        var colors: [String?] = Array(repeating: nil, count: 16)
        for index in 0..<16 {
            colors[index] = value(for: ["color\(index)"], in: pairs)
        }
        for value in pairs["palette"] ?? [] {
            let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let index = Int(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  index >= 0,
                  index < 16
            else { continue }
            colors[index] = TerminalThemeColor.normalizeHex(parts[1])
        }
        return colors.compactMap { $0 }
    }

    private static func value(for keys: [String], in pairs: [String: [String]]) -> String? {
        for key in keys {
            if let value = pairs[key]?.last.flatMap(TerminalThemeColor.normalizeHex) {
                return value
            }
        }
        return nil
    }

    private static func plistColorHex(_ value: Any) -> String? {
        guard let dictionary = value as? [String: Any] else { return nil }
        let red = component(dictionary["Red Component"])
        let green = component(dictionary["Green Component"])
        let blue = component(dictionary["Blue Component"])
        return TerminalThemeColor.hex(red: red, green: green, blue: blue)
    }

    private static func component(_ value: Any?) -> CGFloat {
        switch value {
        case let value as CGFloat:
            return value
        case let value as Double:
            return CGFloat(value)
        case let value as Float:
            return CGFloat(value)
        case let value as Int:
            return CGFloat(value)
        default:
            return 0
        }
    }

    private static func stripInlineComment(_ value: String) -> String {
        guard let index = value.firstIndex(of: "#") else {
            return value
        }
        let after = value[index...]
        let hexToken = after
            .dropFirst()
            .prefix { $0.isHexDigit }
        if hexToken.count == 3 || hexToken.count == 6 || hexToken.count == 8 {
            return value
        }
        let before = value[..<index]
        return String(before)
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static let ansiNames = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
}

public enum TerminalThemeColor {
    public static func normalizeHex(_ value: String) -> String? {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if hex.hasPrefix("0x") {
            hex.removeFirst(2)
        }
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard hex.count == 3 || hex.count == 6,
              hex.allSatisfy(\.isHexDigit)
        else {
            return nil
        }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        return "#\(hex.uppercased())"
    }

    public static func nsColor(from hex: String) -> NSColor? {
        guard let components = rgbComponents(hex) else {
            return nil
        }
        return NSColor(
            deviceRed: CGFloat(components.red) / 255.0,
            green: CGFloat(components.green) / 255.0,
            blue: CGFloat(components.blue) / 255.0,
            alpha: 1
        )
    }

    public static func swiftTermColor(from hex: String) -> SwiftTerm.Color? {
        guard let components = rgbComponents(hex) else {
            return nil
        }
        return SwiftTerm.Color(
            red: UInt16(components.red) * 257,
            green: UInt16(components.green) * 257,
            blue: UInt16(components.blue) * 257
        )
    }

    public static func hex(red: CGFloat, green: CGFloat, blue: CGFloat) -> String {
        let r = max(0, min(255, Int(round(red * 255))))
        let g = max(0, min(255, Int(round(green * 255))))
        let b = max(0, min(255, Int(round(blue * 255))))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func rgbComponents(_ hex: String) -> (red: Int, green: Int, blue: Int)? {
        guard let normalized = normalizeHex(hex) else { return nil }
        let raw = String(normalized.dropFirst())
        guard let value = Int(raw, radix: 16) else { return nil }
        return (
            red: (value >> 16) & 0xFF,
            green: (value >> 8) & 0xFF,
            blue: value & 0xFF
        )
    }
}

extension NSColor {
    public var portDeskHexString: String? {
        guard let color = usingColorSpace(.deviceRGB) else {
            return nil
        }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return TerminalThemeColor.hex(red: red, green: green, blue: blue)
    }
}

private extension TerminalThemeSourceFormat {
    var defaultThemeName: String {
        switch self {
        case .portDesk:
            return "Stacio Theme"
        case .kitty:
            return "Kitty Theme"
        case .ghostty:
            return "Ghostty Theme"
        case .alacritty:
            return "Alacritty Theme"
        case .wezTerm:
            return "WezTerm Theme"
        case .windowsTerminal:
            return "Windows Terminal Theme"
        case .iterm2:
            return "iTerm2 Theme"
        }
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false
        else {
            return nil
        }
        return value
    }
}
