import AppKit
import StacioCoreBindings

public struct SessionTabIconDescriptor: Equatable {
    public let identifier: String
    public let accessibilityLabel: String
    public let shortLabel: String
    public let backgroundColor: NSColor
    public let foregroundColor: NSColor
    private let resourceIconID: String?

    public init(
        identifier: String,
        accessibilityLabel: String,
        shortLabel: String,
        backgroundColor: NSColor,
        foregroundColor: NSColor = .white,
        resourceIconID: String? = nil
    ) {
        self.identifier = identifier
        self.accessibilityLabel = accessibilityLabel
        self.shortLabel = shortLabel
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.resourceIconID = resourceIconID
    }

    public static let sshDefault = SessionTabIconDescriptor(
        identifier: "ssh-default",
        accessibilityLabel: "SSH",
        shortLabel: ">_",
        backgroundColor: NSColor(calibratedRed: 0.18, green: 0.22, blue: 0.29, alpha: 1)
    )

    public static func catalogIcon(id: String, accessibilityLabel: String? = nil) -> SessionTabIconDescriptor? {
        guard let definition = SessionIconCatalog.definition(id: id) else { return nil }
        return SessionTabIconDescriptor(
            identifier: definition.id,
            accessibilityLabel: accessibilityLabel ?? definition.displayName,
            shortLabel: "",
            backgroundColor: .clear,
            resourceIconID: definition.id
        )
    }

    public static func graphicsProtocol(_ protocolName: String) -> SessionTabIconDescriptor {
        let normalized = protocolName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch normalized {
        case "VNC":
            return SessionTabIconDescriptor(
                identifier: "vnc-default",
                accessibilityLabel: "VNC 远程桌面",
                shortLabel: "VNC",
                backgroundColor: NSColor(calibratedRed: 0.14, green: 0.48, blue: 0.34, alpha: 1)
            )
        default:
            let label = normalized.isEmpty ? "图形会话" : "\(normalized) 图形会话"
            return SessionTabIconDescriptor(
                identifier: "graphics-default",
                accessibilityLabel: label,
                shortLabel: normalized.isEmpty ? "GPU" : String(normalized.prefix(3)),
                backgroundColor: NSColor(calibratedRed: 0.31, green: 0.29, blue: 0.58, alpha: 1)
            )
        }
    }

    public static func operatingSystem(_ info: RemoteOperatingSystemInfo) -> SessionTabIconDescriptor {
        let tokens = ([info.id] + info.idLike + [info.name, info.prettyName, info.kernelName])
            .map(Self.normalizedToken)
            .filter { $0.isEmpty == false }

        if let match = firstMatch(in: tokens) {
            return match.descriptor(version: info.versionId, prettyName: info.prettyName)
        }
        return genericLinuxDescriptor(version: info.versionId, prettyName: info.prettyName)
    }

    public func image(size: NSSize = NSSize(width: 18, height: 18)) -> NSImage {
        if let resourceIconID,
           let image = SessionIconCatalog.image(for: resourceIconID, size: size) {
            image.accessibilityDescription = accessibilityLabel
            return image
        }
        let image = NSImage(size: size)
        image.isTemplate = false
        image.accessibilityDescription = accessibilityLabel
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.28, yRadius: rect.height * 0.28)
        backgroundColor.setFill()
        path.fill()

        NSColor.white.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 1
        path.stroke()

        let fontSize: CGFloat = shortLabel.count > 2 ? 7.2 : 8.8
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: foregroundColor,
            .paragraphStyle: {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                return style
            }()
        ]
        let attributed = NSAttributedString(string: shortLabel, attributes: attributes)
        let textSize = attributed.size()
        let textRect = NSRect(
            x: 0,
            y: (size.height - textSize.height) / 2 - 0.4,
            width: size.width,
            height: textSize.height
        )
        attributed.draw(in: textRect)
        return image
    }

    private static func firstMatch(in tokens: [String]) -> OperatingSystemIconMatch? {
        let joined = tokens.joined(separator: " ")
        let exactMatches: [(Set<String>, OperatingSystemIconMatch)] = [
            (["ubuntu"], .ubuntu),
            (["debian"], .debian),
            (["centos", "centoslinux", "centosstream"], .centos),
            (["rhel", "redhat", "redhatenterpriselinux"], .redHat),
            (["rocky", "rockylinux"], .rocky),
            (["almalinux", "alma"], .alma),
            (["fedora"], .fedora),
            (["opensuse", "suse", "sles"], .suse),
            (["arch"], .arch),
            (["alpine"], .alpine),
            (["ol", "oracle", "oraclelinux"], .oracle),
            (["amzn", "amazon", "amazonlinux"], .amazon),
            (["kali"], .kali),
            (["deepin"], .deepin),
            (["uos"], .uos),
            (["kylin", "openkylin"], .kylin),
            (["openeuler"], .openEuler),
            (["anolis"], .anolis),
            (["darwin", "macos"], .macOS),
            (["windows", "mingw", "msys"], .windows),
            (["freebsd"], .freeBSD),
            (["linux"], .linux)
        ]
        return exactMatches.first { candidates, _ in
            tokens.contains { candidates.contains($0) }
        }?.1
        ?? fuzzyMatches.first { joined.contains($0.0) }?.1
    }

    private static let fuzzyMatches: [(String, OperatingSystemIconMatch)] = [
            ("redhat", .redHat),
            ("red hat", .redHat),
            ("rocky", .rocky),
            ("alma", .alma),
            ("oracle", .oracle),
            ("amazon", .amazon),
            ("opensuse", .suse),
            ("suse", .suse),
            ("open euler", .openEuler),
            ("openeuler", .openEuler),
            ("uniontech", .uos),
            ("kylin", .kylin),
            ("deepin", .deepin),
            ("centos", .centos),
            ("ubuntu", .ubuntu),
            ("debian", .debian),
            ("fedora", .fedora),
            ("alpine", .alpine),
            ("arch", .arch),
            ("kali", .kali),
            ("windows", .windows),
            ("darwin", .macOS),
            ("mac os", .macOS),
            ("freebsd", .freeBSD),
            ("linux", .linux)
        ]

    private static func genericLinuxDescriptor(version: String, prettyName: String) -> SessionTabIconDescriptor {
        let label = prettyName.isEmpty ? "Linux" : prettyName
        return SessionTabIconDescriptor(
            identifier: "linux",
            accessibilityLabel: version.isEmpty ? label : "\(label) \(version)",
            shortLabel: "LNX",
            backgroundColor: NSColor(calibratedRed: 0.13, green: 0.17, blue: 0.18, alpha: 1)
        )
    }

    private static func normalizedToken(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
    }
}

private enum OperatingSystemIconMatch {
    case ubuntu
    case debian
    case centos
    case redHat
    case rocky
    case alma
    case fedora
    case suse
    case arch
    case alpine
    case oracle
    case amazon
    case kali
    case deepin
    case uos
    case kylin
    case openEuler
    case anolis
    case macOS
    case windows
    case freeBSD
    case linux

    func descriptor(version: String, prettyName: String) -> SessionTabIconDescriptor {
        let base = baseDescriptor
        let name = prettyName.isEmpty ? base.accessibilityLabel : prettyName
        return SessionTabIconDescriptor(
            identifier: base.identifier,
            accessibilityLabel: version.isEmpty ? name : "\(name) \(version)",
            shortLabel: base.shortLabel,
            backgroundColor: base.backgroundColor,
            foregroundColor: base.foregroundColor
        )
    }

    private var baseDescriptor: SessionTabIconDescriptor {
        switch self {
        case .ubuntu:
            return .init(identifier: "ubuntu", accessibilityLabel: "Ubuntu", shortLabel: "U", backgroundColor: NSColor(calibratedRed: 0.86, green: 0.22, blue: 0.07, alpha: 1))
        case .debian:
            return .init(identifier: "debian", accessibilityLabel: "Debian", shortLabel: "D", backgroundColor: NSColor(calibratedRed: 0.66, green: 0.04, blue: 0.23, alpha: 1))
        case .centos:
            return .init(identifier: "centos", accessibilityLabel: "CentOS", shortLabel: "C", backgroundColor: NSColor(calibratedRed: 0.56, green: 0.28, blue: 0.66, alpha: 1))
        case .redHat:
            return .init(identifier: "redhat", accessibilityLabel: "Red Hat", shortLabel: "RH", backgroundColor: NSColor(calibratedRed: 0.80, green: 0.06, blue: 0.08, alpha: 1))
        case .rocky:
            return .init(identifier: "rocky", accessibilityLabel: "Rocky Linux", shortLabel: "R", backgroundColor: NSColor(calibratedRed: 0.05, green: 0.51, blue: 0.31, alpha: 1))
        case .alma:
            return .init(identifier: "almalinux", accessibilityLabel: "AlmaLinux", shortLabel: "A", backgroundColor: NSColor(calibratedRed: 0.16, green: 0.45, blue: 0.73, alpha: 1))
        case .fedora:
            return .init(identifier: "fedora", accessibilityLabel: "Fedora", shortLabel: "F", backgroundColor: NSColor(calibratedRed: 0.16, green: 0.38, blue: 0.70, alpha: 1))
        case .suse:
            return .init(identifier: "suse", accessibilityLabel: "SUSE", shortLabel: "S", backgroundColor: NSColor(calibratedRed: 0.07, green: 0.66, blue: 0.38, alpha: 1))
        case .arch:
            return .init(identifier: "arch", accessibilityLabel: "Arch Linux", shortLabel: "A", backgroundColor: NSColor(calibratedRed: 0.08, green: 0.54, blue: 0.78, alpha: 1))
        case .alpine:
            return .init(identifier: "alpine", accessibilityLabel: "Alpine Linux", shortLabel: "AL", backgroundColor: NSColor(calibratedRed: 0.05, green: 0.30, blue: 0.54, alpha: 1))
        case .oracle:
            return .init(identifier: "oracle", accessibilityLabel: "Oracle Linux", shortLabel: "O", backgroundColor: NSColor(calibratedRed: 0.74, green: 0.08, blue: 0.08, alpha: 1))
        case .amazon:
            return .init(identifier: "amazon", accessibilityLabel: "Amazon Linux", shortLabel: "AM", backgroundColor: NSColor(calibratedRed: 0.15, green: 0.30, blue: 0.55, alpha: 1))
        case .kali:
            return .init(identifier: "kali", accessibilityLabel: "Kali Linux", shortLabel: "K", backgroundColor: NSColor(calibratedRed: 0.08, green: 0.25, blue: 0.48, alpha: 1))
        case .deepin:
            return .init(identifier: "deepin", accessibilityLabel: "Deepin", shortLabel: "DE", backgroundColor: NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.82, alpha: 1))
        case .uos:
            return .init(identifier: "uos", accessibilityLabel: "UOS", shortLabel: "UOS", backgroundColor: NSColor(calibratedRed: 0.18, green: 0.35, blue: 0.68, alpha: 1))
        case .kylin:
            return .init(identifier: "kylin", accessibilityLabel: "Kylin", shortLabel: "KY", backgroundColor: NSColor(calibratedRed: 0.76, green: 0.09, blue: 0.20, alpha: 1))
        case .openEuler:
            return .init(identifier: "openeuler", accessibilityLabel: "openEuler", shortLabel: "OE", backgroundColor: NSColor(calibratedRed: 0.24, green: 0.32, blue: 0.86, alpha: 1))
        case .anolis:
            return .init(identifier: "anolis", accessibilityLabel: "Anolis OS", shortLabel: "AN", backgroundColor: NSColor(calibratedRed: 0.04, green: 0.54, blue: 0.42, alpha: 1))
        case .macOS:
            return .init(identifier: "macos", accessibilityLabel: "macOS", shortLabel: "mac", backgroundColor: NSColor(calibratedRed: 0.20, green: 0.25, blue: 0.32, alpha: 1))
        case .windows:
            return .init(identifier: "windows", accessibilityLabel: "Windows", shortLabel: "WIN", backgroundColor: NSColor(calibratedRed: 0.00, green: 0.47, blue: 0.84, alpha: 1))
        case .freeBSD:
            return .init(identifier: "freebsd", accessibilityLabel: "FreeBSD", shortLabel: "BSD", backgroundColor: NSColor(calibratedRed: 0.70, green: 0.08, blue: 0.10, alpha: 1))
        case .linux:
            return .init(identifier: "linux", accessibilityLabel: "Linux", shortLabel: "LNX", backgroundColor: NSColor(calibratedRed: 0.13, green: 0.17, blue: 0.18, alpha: 1))
        }
    }
}
