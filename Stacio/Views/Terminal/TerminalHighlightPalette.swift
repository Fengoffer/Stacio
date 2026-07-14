import AppKit

public enum TerminalHighlightSemanticRole: String, CaseIterable {
    case command
    case subcommand
    case dangerous
    case flag
    case path
    case environment
    case argument
    case operatorToken
    case string
    case number
    case variable
    case substitution
    case comment
    case glob
    case redirection
    case heredoc
    case error
    case warning
    case success
    case info
    case resource
    case time
    case git
    case permission
    case link
    case version
    case address
    case muted
    case prompt

    public var allowsMutedContrast: Bool {
        switch self {
        case .comment, .operatorToken, .muted:
            return true
        default:
            return false
        }
    }
}

public struct TerminalHighlightPalette {
    public let theme: TerminalColorTheme

    private let background: RGBColor
    private let foreground: RGBColor
    private let colorsByRole: [TerminalHighlightSemanticRole: RGBColor]

    public init(theme: TerminalColorTheme) {
        self.theme = theme
        self.background = RGBColor(hex: theme.backgroundHex) ?? .black
        self.foreground = RGBColor(hex: theme.foregroundHex) ?? .white

        var values: [TerminalHighlightSemanticRole: RGBColor] = [:]
        for role in TerminalHighlightSemanticRole.allCases {
            let candidates = Self.candidates(for: role, theme: theme)
            let minimum = role.allowsMutedContrast ? 3.0 : 4.5
            values[role] = Self.readableColor(
                candidates: candidates,
                foreground: RGBColor(hex: theme.foregroundHex) ?? .white,
                background: RGBColor(hex: theme.backgroundHex) ?? .black,
                minimumContrast: minimum
            )
        }
        self.colorsByRole = values
    }

    public func nsColor(for role: TerminalHighlightSemanticRole) -> NSColor {
        color(for: role).nsColor
    }

    public func sgrCode(
        for role: TerminalHighlightSemanticRole,
        bold: Bool = false,
        underline: Bool = false,
        includeBackground: Bool = false
    ) -> String {
        let backgroundOverride = includeBackground ? backgroundColor(for: role) : nil
        let color: RGBColor
        if let backgroundOverride {
            let minimum = role.allowsMutedContrast ? 3.0 : 4.5
            color = Self.readableColor(
                candidates: [self.color(for: role), foreground, .white, .black],
                foreground: foreground,
                background: backgroundOverride,
                minimumContrast: minimum
            )
        } else {
            color = self.color(for: role)
        }
        var parts: [String] = []
        if bold {
            parts.append("1")
        }
        if underline {
            parts.append("4")
        }
        parts.append("38;2;\(color.red);\(color.green);\(color.blue)")
        if let backgroundOverride {
            parts.append("48;2;\(backgroundOverride.red);\(backgroundOverride.green);\(backgroundOverride.blue)")
        }
        return parts.joined(separator: ";")
    }

    public func contrastRatio(for role: TerminalHighlightSemanticRole) -> Double {
        color(for: role).contrastRatio(with: background)
    }

    private func color(for role: TerminalHighlightSemanticRole) -> RGBColor {
        colorsByRole[role] ?? foreground
    }

    private func backgroundColor(for role: TerminalHighlightSemanticRole) -> RGBColor? {
        switch role {
        case .prompt:
            return RGBColor(red: 213, green: 236, blue: 255)
        default:
            return nil
        }
    }

    private static func candidates(for role: TerminalHighlightSemanticRole, theme: TerminalColorTheme) -> [RGBColor] {
        func ansi(_ index: Int) -> RGBColor? {
            guard theme.ansiColorHexes.indices.contains(index) else { return nil }
            return RGBColor(hex: theme.ansiColorHexes[index])
        }
        let fg = RGBColor(hex: theme.foregroundHex)
        let muted = ansi(8)

        let indexes: [Int]
        switch role {
        case .error, .dangerous:
            indexes = [9, 1, 15]
        case .warning, .flag, .redirection, .glob:
            indexes = [11, 3, 15]
        case .success:
            indexes = [10, 2, 15]
        case .info, .command, .link:
            indexes = [6, 14, 12, 4, 15]
        case .path, .subcommand, .resource, .heredoc:
            indexes = [6, 14, 12, 4, 15]
        case .number, .version, .git, .permission:
            indexes = [13, 5, 12, 15]
        case .address:
            indexes = [11, 3, 5, 13, 15]
        case .string:
            indexes = [10, 2, 14, 15]
        case .variable, .environment, .substitution:
            indexes = [14, 6, 10, 15]
        case .time:
            indexes = [6, 14, 12, 15]
        case .comment, .operatorToken, .muted:
            indexes = [8, 7, 15]
        case .argument:
            indexes = [7, 15, 14]
        case .prompt:
            indexes = [15, 14, 12, 7, 0]
        }
        return indexes.compactMap(ansi) + [muted, fg].compactMap { $0 }
    }

    private static func readableColor(
        candidates: [RGBColor],
        foreground: RGBColor,
        background: RGBColor,
        minimumContrast: Double
    ) -> RGBColor {
        for candidate in candidates where candidate.contrastRatio(with: background) >= minimumContrast {
            return candidate
        }
        for candidate in candidates {
            let mixed = candidate.mixed(with: foreground, amount: 0.45)
            if mixed.contrastRatio(with: background) >= minimumContrast {
                return mixed
            }
        }
        if foreground.contrastRatio(with: background) >= minimumContrast {
            return foreground
        }
        return background.isDark ? .white : .black
    }
}

private struct RGBColor: Equatable {
    let red: Int
    let green: Int
    let blue: Int

    static let black = RGBColor(red: 0, green: 0, blue: 0)
    static let white = RGBColor(red: 255, green: 255, blue: 255)

    init(red: Int, green: Int, blue: Int) {
        self.red = max(0, min(255, red))
        self.green = max(0, min(255, green))
        self.blue = max(0, min(255, blue))
    }

    init?(hex: String) {
        guard let normalized = TerminalThemeColor.normalizeHex(hex),
              let value = Int(String(normalized.dropFirst()), radix: 16)
        else {
            return nil
        }
        self.init(
            red: (value >> 16) & 0xFF,
            green: (value >> 8) & 0xFF,
            blue: value & 0xFF
        )
    }

    var nsColor: NSColor {
        NSColor(
            deviceRed: CGFloat(red) / 255.0,
            green: CGFloat(green) / 255.0,
            blue: CGFloat(blue) / 255.0,
            alpha: 1
        )
    }

    var isDark: Bool {
        relativeLuminance < 0.5
    }

    func mixed(with other: RGBColor, amount: Double) -> RGBColor {
        let clamped = max(0, min(1, amount))
        return RGBColor(
            red: Int(round(Double(red) * (1 - clamped) + Double(other.red) * clamped)),
            green: Int(round(Double(green) * (1 - clamped) + Double(other.green) * clamped)),
            blue: Int(round(Double(blue) * (1 - clamped) + Double(other.blue) * clamped))
        )
    }

    func contrastRatio(with other: RGBColor) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private var relativeLuminance: Double {
        func channel(_ value: Int) -> Double {
            let normalized = Double(value) / 255.0
            if normalized <= 0.03928 {
                return normalized / 12.92
            }
            return pow((normalized + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}
