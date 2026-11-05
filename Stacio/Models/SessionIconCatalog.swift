import AppKit
import Foundation
import StacioCoreBindings

enum SessionIconGroup: String, CaseIterable {
    case operatingSystem
    case cloudPlatform

    var displayName: String {
        switch self {
        case .operatingSystem:
            return "操作系统"
        case .cloudPlatform:
            return "云平台"
        }
    }
}

struct SessionIconDefinition: Equatable {
    let id: String
    let displayName: String
    let group: SessionIconGroup
    let resourceName: String
    let searchAliases: [String]
}

enum SessionIconCatalog {
    static let all: [SessionIconDefinition] = [
        icon("linux-generic", "Linux", .operatingSystem, "linux-generic.svg", ["linux", "通用"]),
        icon("ubuntu", "Ubuntu", .operatingSystem, "ubuntu.svg", ["ubuntu"]),
        icon("ubuntu-alt", "Ubuntu（备选）", .operatingSystem, "ubuntu-alt.svg", ["ubuntu", "alternate"]),
        icon("centos", "CentOS", .operatingSystem, "centos.svg", ["centos"]),
        icon("centos-alt", "CentOS（备选）", .operatingSystem, "centos-alt.svg", ["centos", "alternate"]),
        icon("debian", "Debian", .operatingSystem, "debian.svg", ["debian"]),
        icon("fedora", "Fedora", .operatingSystem, "fedora.svg", ["fedora"]),
        icon("redhat", "Red Hat", .operatingSystem, "redhat.svg", ["red hat", "redhat", "rhel"]),
        icon("oracle-linux", "Oracle Linux", .operatingSystem, "oracle-linux.svg", ["oracle", "ol"]),
        icon("arch-linux", "Arch Linux", .operatingSystem, "arch-linux.svg", ["arch"]),
        icon("opensuse", "openSUSE", .operatingSystem, "opensuse.svg", ["opensuse", "suse", "sles"]),
        icon("kali-linux", "Kali Linux", .operatingSystem, "kali-linux.svg", ["kali"]),
        icon("kylin", "中标麒麟", .operatingSystem, "kylin.svg", ["kylin", "麒麟", "openkylin"]),
        icon("open-euler", "openEuler", .operatingSystem, "open-euler.svg", ["openeuler", "欧拉"]),
        icon("uos", "统信 UOS", .operatingSystem, "uos.svg", ["uos", "uniontech", "统信"]),
        icon("anolis", "龙蜥 Anolis OS", .operatingSystem, "anolis.svg", ["anolis", "龙蜥"]),
        icon("harmonyos", "鸿蒙", .operatingSystem, "harmonyos.svg", ["harmonyos", "harmony", "鸿蒙"]),
        icon("fnos", "飞牛 fnOS", .operatingSystem, "fnos.svg", ["fnos", "飞牛"]),
        icon("amazon-cloud", "亚马逊云", .cloudPlatform, "amazon-cloud.svg", ["amazon", "aws", "亚马逊"]),
        icon("volcengine", "火山引擎", .cloudPlatform, "volcengine.svg", ["volcengine", "volcano", "火山"]),
        icon("tencent-cloud", "腾讯云", .cloudPlatform, "tencent-cloud.svg", ["tencent", "腾讯"]),
        icon("aliyun", "阿里云", .cloudPlatform, "aliyun.svg", ["alibaba", "alibaba cloud", "aliyun", "阿里"]),
        icon("raincloud", "雨云", .cloudPlatform, "raincloud.png", ["raincloud", "雨云"])
    ]

    static var operatingSystems: [SessionIconDefinition] {
        all.filter { $0.group == .operatingSystem }
    }

    static var cloudPlatforms: [SessionIconDefinition] {
        all.filter { $0.group == .cloudPlatform }
    }

    static func definition(id: String?) -> SessionIconDefinition? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return nil
        }
        return all.first { $0.id == id }
    }

    static func matching(_ query: String) -> [SessionIconDefinition] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.filter { definition in
            definition.displayName.localizedCaseInsensitiveContains(needle)
                || definition.searchAliases.contains {
                    $0.localizedCaseInsensitiveContains(needle)
                }
        }
    }

    static func image(for id: String, size: NSSize) -> NSImage? {
        if let image = image(for: id, size: size, bundle: .main) {
            return image
        }
        #if DEBUG
        return image(for: id, size: size, bundle: .module)
        #else
        return nil
        #endif
    }

    static func image(for id: String, size: NSSize, bundle: Bundle) -> NSImage? {
        guard let definition = definition(id: id) else { return nil }
        let components = definition.resourceName.split(separator: ".", maxSplits: 1).map(String.init)
        let basename = components[0]
        let fileExtension = components.count > 1 ? components[1] : nil
        guard let url = bundle.url(
            forResource: basename,
            withExtension: fileExtension,
            subdirectory: "SessionIcons"
        ) ?? bundle.url(forResource: basename, withExtension: fileExtension),
              let image = NSImage(contentsOf: url)
        else { return nil }

        image.size = size
        image.isTemplate = false
        image.accessibilityDescription = definition.displayName
        return image
    }

    static func iconID(for info: RemoteOperatingSystemInfo) -> String? {
        let tokens = ([info.id] + info.idLike + [info.name, info.prettyName])
            .map(normalizedToken)
            .filter { !$0.isEmpty }

        let mappings: [(Set<String>, String)] = [
            (["ubuntu"], "ubuntu"),
            (["debian"], "debian"),
            (["centos", "centoslinux", "centosstream"], "centos"),
            (["rhel", "redhat", "redhatenterpriselinux"], "redhat"),
            (["fedora"], "fedora"),
            (["opensuse", "suse", "sles"], "opensuse"),
            (["arch", "archlinux"], "arch-linux"),
            (["ol", "oracle", "oraclelinux"], "oracle-linux"),
            (["kali", "kalilinux"], "kali-linux"),
            (["uos", "uniontech"], "uos"),
            (["kylin", "openkylin", "neokylin"], "kylin"),
            (["openeuler"], "open-euler"),
            (["anolis", "anolisos"], "anolis"),
            (["harmonyos", "openharmony"], "harmonyos"),
            (["fnos"], "fnos")
        ]
        if let exact = mappings.first(where: { candidates, _ in
            tokens.contains { candidates.contains($0) }
        }) {
            return exact.1
        }

        let joined = tokens.joined(separator: " ")
        if let fuzzy = mappings.first(where: { candidates, _ in
            candidates.contains { joined.contains($0) }
        }) {
            return fuzzy.1
        }
        if normalizedToken(info.kernelName).contains("linux") {
            return "linux-generic"
        }
        return nil
    }

    private static func icon(
        _ id: String,
        _ displayName: String,
        _ group: SessionIconGroup,
        _ resourceName: String,
        _ aliases: [String]
    ) -> SessionIconDefinition {
        SessionIconDefinition(
            id: id,
            displayName: displayName,
            group: group,
            resourceName: resourceName,
            searchAliases: aliases
        )
    }

    private static func normalizedToken(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
    }
}

enum SessionIconConfigCodec {
    private static let key = "sessionIconID"

    static func iconID(from configJSON: String?) -> String? {
        guard let object = object(from: configJSON),
              let iconID = object[key] as? String,
              SessionIconCatalog.definition(id: iconID) != nil
        else { return nil }
        return iconID
    }

    static func updatingIconID(_ iconID: String?, in configJSON: String?) throws -> String? {
        var object = object(from: configJSON) ?? [:]
        if let definition = SessionIconCatalog.definition(id: iconID) {
            object[key] = definition.id
        } else {
            object.removeValue(forKey: key)
        }
        guard !object.isEmpty else { return nil }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)
    }

    private static func object(from configJSON: String?) -> [String: Any]? {
        guard let configJSON,
              let data = configJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}
