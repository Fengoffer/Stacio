import Foundation

// MARK: - 官网动作（P4-6）

public enum WebsiteActionKind: String, Codable, CaseIterable, Equatable, Sendable {
    case apiKey
    case login
    case codingPlan
    case quota
    case billing
    case documentation
    case website
    case upgrade
}

public enum WebsiteActionSource: String, Codable, Equatable, Sendable {
    case catalog
    case userProvided
}

/// 官网动作 descriptor：稳定 actionID/owner/kind/title/HTTPS URL/displayOrder/
/// isPrimary/isPromotional/source/verifiedAt/supportLevel。
public struct WebsiteActionDescriptor: Codable, Equatable, Sendable {
    public let actionID: String
    public let owner: String
    public let kind: WebsiteActionKind
    public let title: String
    public let url: URL
    public let displayOrder: Int
    public let isPrimary: Bool
    public let isPromotional: Bool
    public let source: WebsiteActionSource
    public let verifiedAt: Date?
    public let supportLevel: CatalogSupportLevel

    public init(
        actionID: String, owner: String, kind: WebsiteActionKind, title: String,
        url: URL, displayOrder: Int, isPrimary: Bool, isPromotional: Bool,
        source: WebsiteActionSource, verifiedAt: Date?, supportLevel: CatalogSupportLevel
    ) {
        self.actionID = actionID
        self.owner = owner
        self.kind = kind
        self.title = title
        self.url = url
        self.displayOrder = displayOrder
        self.isPrimary = isPrimary
        self.isPromotional = isPromotional
        self.source = source
        self.verifiedAt = verifiedAt
        self.supportLevel = supportLevel
    }
}

public enum WebsiteActionValidationError: Error, Equatable {
    case nonHTTPS(actionID: String)
    case multiplePrimaryForOwnerAndKind(owner: String, kind: WebsiteActionKind)
    case multiplePrimaryButtonForOwner(owner: String)
    case promotionalPrimary(actionID: String)
    /// userProvided 动作永不标注官方（catalog 校验拒绝）。
    case userProvidedMarkedOfficial(actionID: String)
    case missingPrimaryOfficialEntry(owner: String)
}

/// 打开计划：显示域名后交 NSWorkspace 默认浏览器，不附加任何 secret/header/会话信息。
public struct OpenWebsiteActionPlan: Equatable, Sendable {
    public let displayedDomain: String
    public let url: URL
    public let attachedSecrets: [String]
    public let attachedHeaders: [String]

    public init(displayedDomain: String, url: URL) {
        self.displayedDomain = displayedDomain
        self.url = url
        self.attachedSecrets = []
        self.attachedHeaders = []
    }
}

/// mozhe 推广链接处理：只能作为次级「推广注册链接」，必须另提供无 aff 普通官网动作。
public struct MozhePromotionPlan: Equatable, Sendable {
    public let promotionalRegistrationLink: URL?
    public let plainOfficialActionURL: URL?
    /// 不得隐藏/重写/追加推广参数。
    public let affParameterPreserved: Bool

    public init(promotionalRegistrationLink: URL?, plainOfficialActionURL: URL?, affParameterPreserved: Bool) {
        self.promotionalRegistrationLink = promotionalRegistrationLink
        self.plainOfficialActionURL = plainOfficialActionURL
        self.affParameterPreserved = affParameterPreserved
    }
}

public enum WebsiteActionResolver {
    // MARK: - 校验（同一 owner+kind 最多一个 primary；同一 owner 最多一个整体主按钮）

    public static func validate(_ actions: [WebsiteActionDescriptor]) throws {
        for action in actions {
            guard action.url.scheme?.lowercased() == "https" else {
                throw WebsiteActionValidationError.nonHTTPS(actionID: action.actionID)
            }
            // userProvided 永不标注官方（catalog 来源才可带 verifiedAt/supportLevel 官方语义）
            if action.source == .userProvided, action.verifiedAt != nil {
                throw WebsiteActionValidationError.userProvidedMarkedOfficial(actionID: action.actionID)
            }
            if action.isPrimary, action.isPromotional {
                throw WebsiteActionValidationError.promotionalPrimary(actionID: action.actionID)
            }
        }
        // 同 owner+kind 最多一个 primary
        var primaryByOwnerKind: Set<String> = []
        for action in actions where action.isPrimary {
            let key = "\(action.owner)|\(action.kind.rawValue)"
            guard !primaryByOwnerKind.contains(key) else {
                throw WebsiteActionValidationError.multiplePrimaryForOwnerAndKind(owner: action.owner, kind: action.kind)
            }
            primaryByOwnerKind.insert(key)
        }
        // A primary action is the owner's single main button regardless of kind.
        var primaryButtons: Set<String> = []
        for action in actions where action.isPrimary {
            guard !primaryButtons.contains(action.owner) else {
                throw WebsiteActionValidationError.multiplePrimaryButtonForOwner(owner: action.owner)
            }
            primaryButtons.insert(action.owner)
        }
    }

    /// 缺少 primary 时显示「官方入口未验证」，不拼 URL。
    public static func primaryButton(owner: String, actions: [WebsiteActionDescriptor]) -> WebsiteActionDescriptor? {
        actions
            .filter { $0.owner == owner && $0.isPrimary && !$0.isPromotional }
            .sorted {
                if $0.displayOrder != $1.displayOrder { return $0.displayOrder < $1.displayOrder }
                return $0.actionID < $1.actionID
            }
            .first
    }

    // MARK: - 打开流程

    /// 显示域名后交 NSWorkspace 默认浏览器；不附加任何 secret/header/会话信息。
    public static func openPlan(for descriptor: WebsiteActionDescriptor) -> OpenWebsiteActionPlan {
        OpenWebsiteActionPlan(displayedDomain: descriptor.url.host ?? "", url: descriptor.url)
    }

    // MARK: - restoreOfficialURL

    /// 仅在 descriptor 有 suggested URL 时可用。
    public static func canRestoreOfficialURL(descriptor: WebsiteActionDescriptor?) -> Bool {
        guard let descriptor else { return false }
        return descriptor.url.scheme?.lowercased() == "https" && !descriptor.url.absoluteString.isEmpty
    }

    /// restore 失败保持原 URL（调用方在失败时不改动当前 Base URL）。
    public static func restoreOutcome(succeeded: Bool, currentBaseURL: String) -> String {
        succeeded ? currentBaseURL : currentBaseURL
    }

    /// origin 变化进入 NeedsCredential：Base URL 与官网 URL 的 origin 不一致 → 需要重新确认。
    public static func originMatches(baseURL: URL, officialURL: URL) -> Bool {
        normalizedOrigin(url: baseURL) == normalizedOrigin(url: officialURL)
    }

    // MARK: - mozhe 推广链接规则

    /// 推广链接只能作为次级「推广注册链接」；必须另提供无 aff 普通官网动作；
    /// 不得隐藏/重写/追加推广参数。
    public static func mozhePromotionPlan(
        actions: [WebsiteActionDescriptor]
    ) -> MozhePromotionPlan {
        let owner = "provider.mozheapi"
        let ownerActions = actions.filter { $0.owner == owner }
        let promotionalAction = ownerActions
            .filter(\.isPromotional)
            .sorted {
                if $0.displayOrder != $1.displayOrder { return $0.displayOrder < $1.displayOrder }
                return $0.actionID < $1.actionID
            }
            .first
        let promotionalURL = promotionalAction?.url
        let affPreserved = promotionalURL.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
        }?.contains {
            $0.name == "aff" && ($0.value?.isEmpty == false)
        } == true
        return MozhePromotionPlan(
            promotionalRegistrationLink: promotionalURL,
            plainOfficialActionURL: primaryButton(owner: owner, actions: ownerActions)?.url,
            affParameterPreserved: affPreserved
        )
    }

    // MARK: - origin 规范化

    /// 小写 scheme / IDNA ASCII host / canonical port（默认端口省略）。
    public static func normalizedOrigin(url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return nil
        }
        let canonicalPort: String
        if let port = url.port {
            let isDefault = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
            canonicalPort = isDefault ? "" : ":\(port)"
        } else {
            canonicalPort = ""
        }
        return "\(scheme)://\(host)\(canonicalPort)"
    }

    /// 重定向到不同 host/port/protocol 时不转发 Authorization（同 origin 才转发）。
    public static func shouldForwardAuthorization(from: URL, to: URL) -> Bool {
        normalizedOrigin(url: from) == normalizedOrigin(url: to)
    }

    /// 首次向自定义 Base URL 发 Key 前确认规范化 origin。
    public static func requiresOriginConfirmation(baseURL: URL, officialURL: URL) -> Bool {
        !originMatches(baseURL: baseURL, officialURL: officialURL)
    }
}
