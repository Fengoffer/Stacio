import Foundation
import StacioCoreBindings

public enum TerminalCommandOperatingSystem: String, CaseIterable, Codable, Equatable, Hashable {
    case generic
    case macOS
    case ubuntuDebian
    case centOSRHEL
    case fedora
    case archLinux
    case alpine
    case openSUSE
    case freeBSD
    case openEuler
    case unionTechUOS
    case deepin
    case kylin
    case anolis
    case openCloudOS
    case alibabaCloudLinux
    case tencentOS
    case windows
    case unknown

    public var displayName: String {
        switch self {
        case .generic: return "通用"
        case .macOS: return "macOS"
        case .ubuntuDebian: return "Ubuntu / Debian"
        case .centOSRHEL: return "CentOS / RHEL / Rocky / Alma"
        case .fedora: return "Fedora"
        case .archLinux: return "Arch Linux / Manjaro"
        case .alpine: return "Alpine"
        case .openSUSE: return "SUSE / openSUSE"
        case .freeBSD: return "BSD（FreeBSD / OpenBSD / NetBSD）"
        case .openEuler: return "openEuler / EulerOS"
        case .unionTechUOS: return "统信 UOS"
        case .deepin: return "Deepin 深度"
        case .kylin: return "银河麒麟 / 中标麒麟"
        case .anolis: return "龙蜥 Anolis OS"
        case .openCloudOS: return "OpenCloudOS"
        case .alibabaCloudLinux: return "Alibaba Cloud Linux"
        case .tencentOS: return "TencentOS Server"
        case .windows: return "Windows / PowerShell（OpenSSH）"
        case .unknown: return "未识别"
        }
    }

    public static func classify(_ info: RemoteOperatingSystemInfo?) -> Self {
        guard let info else { return .unknown }
        let primaryValues = [info.id, info.name, info.prettyName].joined(separator: " ").lowercased()
        if let operatingSystem = classify(text: primaryValues) {
            return operatingSystem
        }
        return classify(text: info.idLike.joined(separator: " ").lowercased()) ?? .unknown
    }

    public static func identityText(_ info: RemoteOperatingSystemInfo?) -> String {
        guard let info else { return "" }
        return [
            info.id,
            info.idLike.joined(separator: " "),
            info.name,
            info.prettyName,
            info.kernelName
        ].joined(separator: " ").lowercased()
    }

    private static func classify(text: String) -> Self? {
        let tokens = Set(text.split { $0.isLetter == false && $0.isNumber == false }.map(String.init))
        if tokens.contains(where: { ["macos", "macosx", "darwin", "osx"].contains($0) }) {
            return .macOS
        }
        if tokens.contains(where: { ["windows", "win32", "mingw", "msys", "cygwin", "powershell"].contains($0) }) {
            return .windows
        }
        if tokens.contains("alpine") { return .alpine }
        if tokens.contains(where: { ["arch", "archlinux", "manjaro"].contains($0) }) { return .archLinux }
        if tokens.contains(where: { ["opensuse", "suse", "sles"].contains($0) }) { return .openSUSE }
        if tokens.contains(where: { ["freebsd", "openbsd", "netbsd", "dragonfly"].contains($0) }) { return .freeBSD }
        if tokens.contains(where: { ["openeuler", "euleros"].contains($0) }) { return .openEuler }
        if tokens.contains(where: { ["uniontech", "uniontechos", "uos"].contains($0) }) { return .unionTechUOS }
        if tokens.contains("deepin") { return .deepin }
        if tokens.contains(where: { ["kylin", "neokylin", "ubuntukylin"].contains($0) }) { return .kylin }
        if tokens.contains(where: { ["anolis", "openanolis"].contains($0) }) { return .anolis }
        if tokens.contains("opencloudos") { return .openCloudOS }
        if tokens.contains(where: { ["alinux", "alibabacloudlinux"].contains($0) }) { return .alibabaCloudLinux }
        if tokens.contains(where: { ["tencentos", "tlinux"].contains($0) }) { return .tencentOS }
        if ["ubuntu", "debian", "linuxmint", "pop"].contains(where: tokens.contains) {
            return .ubuntuDebian
        }
        if ["centos", "rhel", "rocky", "alma", "almalinux", "ol"].contains(where: tokens.contains)
            || text.contains("red hat") || text.contains("oracle linux") {
            return .centOSRHEL
        }
        if tokens.contains("fedora") { return .fedora }
        return nil
    }

    public func accepts(_ command: TerminalFavoriteCommand, operatingSystemIdentity: String = "") -> Bool {
        guard command.enabled else { return false }
        if command.operatingSystems.contains(.generic) { return true }
        if self != .unknown, command.operatingSystems.contains(self) { return true }
        let identity = operatingSystemIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identity.isEmpty == false else { return false }
        return command.customOperatingSystems.contains { customName in
            identity.range(of: customName, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

public struct TerminalFavoriteCommand: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var command: String
    public var details: String
    public var tags: [String]
    public var operatingSystems: Set<TerminalCommandOperatingSystem>
    public var customOperatingSystems: Set<String>
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        command: String,
        details: String = "",
        tags: [String] = [],
        operatingSystems: Set<TerminalCommandOperatingSystem> = [.generic],
        customOperatingSystems: Set<String> = [],
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        self.details = details.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.customOperatingSystems = Self.normalizedCustomOperatingSystems(customOperatingSystems)
        self.operatingSystems = operatingSystems.isEmpty && self.customOperatingSystems.isEmpty ? [.generic] : operatingSystems
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case command
        case details
        case tags
        case operatingSystems
        case customOperatingSystems
        case enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            command: try container.decode(String.self, forKey: .command),
            details: try container.decodeIfPresent(String.self, forKey: .details) ?? "",
            tags: try container.decodeIfPresent([String].self, forKey: .tags) ?? [],
            operatingSystems: try container.decodeIfPresent(Set<TerminalCommandOperatingSystem>.self, forKey: .operatingSystems) ?? [.generic],
            customOperatingSystems: try container.decodeIfPresent(Set<String>.self, forKey: .customOperatingSystems) ?? [],
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(command, forKey: .command)
        try container.encode(details, forKey: .details)
        try container.encode(tags, forKey: .tags)
        try container.encode(operatingSystems, forKey: .operatingSystems)
        try container.encode(customOperatingSystems, forKey: .customOperatingSystems)
        try container.encode(enabled, forKey: .enabled)
    }

    /// Favorite commands are inserted into a terminal input buffer and must not
    /// contain control characters that could submit or alter subsequent input.
    public var isSafeForInsertion: Bool {
        command.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }

    public var displayDetail: String {
        let parts = [details, tags.joined(separator: " / "), operatingSystemDisplayNames.joined(separator: ", ")]
            .filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    public var operatingSystemDisplayNames: [String] {
        (operatingSystems.map(\.displayName) + customOperatingSystems).sorted()
    }

    private static func normalizedCustomOperatingSystems(_ values: Set<String>) -> Set<String> {
        var normalized: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false,
                  normalized.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) == false else { continue }
            normalized.append(trimmed)
        }
        return Set(normalized)
    }
}

public final class TerminalFavoriteCommandStore {
    public static let didChangeNotification = Notification.Name("Stacio.TerminalFavoriteCommandStore.didChange")
    public static let shared = TerminalFavoriteCommandStore()

    private static let storageKey = "Stacio.TerminalFavoriteCommands.v1"
    private static let legacyStorageKeys = [
        "Stacio.Settings.terminalFavoriteCommands",
        "Stacio.Settings.favoriteCommands"
    ]

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private var values: [TerminalFavoriteCommand]

    public init(defaults: UserDefaults = .standard, migrateLegacyHistory: [String] = []) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([TerminalFavoriteCommand].self, from: data) {
            self.values = Self.deduplicated(stored)
        } else {
            var migrated: [TerminalFavoriteCommand] = []
            for key in Self.legacyStorageKeys {
                if let data = defaults.data(forKey: key),
                   let stored = try? JSONDecoder().decode([TerminalFavoriteCommand].self, from: data) {
                    migrated.append(contentsOf: stored)
                } else if let strings = defaults.stringArray(forKey: key) {
                    migrated.append(contentsOf: strings.compactMap { value in
                        let command = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard command.isEmpty == false else { return nil }
                        return TerminalFavoriteCommand(name: command, command: command, details: "从旧常用命令迁移")
                    })
                }
            }
            migrated.append(contentsOf: migrateLegacyHistory.compactMap { value in
                let command = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard command.isEmpty == false else { return nil }
                return TerminalFavoriteCommand(name: command, command: command, details: "从历史命令添加")
            })
            self.values = Self.deduplicated(migrated)
            persist()
        }
    }

    public var commands: [TerminalFavoriteCommand] { values }

    @discardableResult
    public func add(_ command: TerminalFavoriteCommand) -> TerminalFavoriteCommand? {
        guard command.name.isEmpty == false, command.command.isEmpty == false,
              command.isSafeForInsertion,
              values.contains(where: { $0.command.caseInsensitiveCompare(command.command) == .orderedSame }) == false else { return nil }
        values.append(command)
        persistAndNotify()
        return command
    }

    @discardableResult
    public func addFromHistory(_ command: String, name: String? = nil) -> TerminalFavoriteCommand? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let resolvedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = resolvedName.flatMap { $0.isEmpty ? nil : $0 } ?? trimmed
        return add(TerminalFavoriteCommand(name: displayName, command: trimmed, details: "从历史命令添加"))
    }

    @discardableResult
    public func update(_ command: TerminalFavoriteCommand) -> Bool {
        guard command.name.isEmpty == false,
              command.command.isEmpty == false,
              command.isSafeForInsertion,
              let index = values.firstIndex(where: { $0.id == command.id })
        else { return false }
        guard values.enumerated().allSatisfy({ $0.offset == index || $0.element.command.caseInsensitiveCompare(command.command) != .orderedSame }) else { return false }
        values[index] = command
        persistAndNotify()
        return true
    }

    @discardableResult
    public func remove(id: UUID) -> Bool {
        let oldCount = values.count
        values.removeAll { $0.id == id }
        guard values.count != oldCount else { return false }
        persistAndNotify()
        return true
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool, id: UUID) -> Bool {
        guard let index = values.firstIndex(where: { $0.id == id }) else { return false }
        values[index].enabled = enabled
        persistAndNotify()
        return true
    }

    private func persistAndNotify() {
        persist()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func persist() {
        guard let data = try? encoder.encode(values) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func deduplicated(_ commands: [TerminalFavoriteCommand]) -> [TerminalFavoriteCommand] {
        var seen = Set<String>()
        return commands.filter {
            $0.isSafeForInsertion && seen.insert($0.command.lowercased()).inserted
        }
    }
}
