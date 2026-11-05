import XCTest
import Foundation
@testable import StacioApp

/// P4-6：官网动作、恢复官方 URL 与 origin 规则。
final class WebsiteActionTests: XCTestCase {

    private func makeAction(
        id: String, owner: String = "OpenAI", kind: WebsiteActionKind = .website,
        url: URL = URL(string: "https://platform.openai.com/")!, primary: Bool = true,
        promotional: Bool = false, source: WebsiteActionSource = .catalog
    ) -> WebsiteActionDescriptor {
        WebsiteActionDescriptor(
            actionID: id, owner: owner, kind: kind, title: "OpenAI",
            url: url, displayOrder: 1, isPrimary: primary, isPromotional: promotional,
            source: source, verifiedAt: Date(), supportLevel: .ga
        )
    }

    // MARK: - 校验规则

    func testSameOwnerKindSinglePrimary() throws {
        let actions = [
            makeAction(id: "a1", kind: .website),
            makeAction(id: "a2", kind: .billing, primary: false)
        ]
        try WebsiteActionResolver.validate(actions)
        // 同 owner+kind 两个 primary → 失败
        let dup = [
            makeAction(id: "a1", kind: .website),
            makeAction(id: "a2", kind: .website, primary: true)
        ]
        XCTAssertThrowsError(try WebsiteActionResolver.validate(dup)) { error in
            XCTAssertEqual(
                error as? WebsiteActionValidationError,
                .multiplePrimaryForOwnerAndKind(owner: "OpenAI", kind: .website)
            )
        }
    }

    func testSameOwnerSingleOverallPrimaryButton() throws {
        // Primary is owner-wide, not scoped to an action kind.
        let mixed = [
            makeAction(id: "a2", kind: .apiKey, primary: true),
            makeAction(id: "a3", kind: .billing, primary: true)
        ]
        XCTAssertThrowsError(try WebsiteActionResolver.validate(mixed)) { error in
            XCTAssertEqual(
                error as? WebsiteActionValidationError,
                .multiplePrimaryButtonForOwner(owner: "OpenAI")
            )
        }
    }

    func testPromotionalActionCannotBePrimary() {
        let promotional = makeAction(id: "promo", primary: true, promotional: true)

        XCTAssertThrowsError(try WebsiteActionResolver.validate([promotional])) { error in
            XCTAssertEqual(
                error as? WebsiteActionValidationError,
                .promotionalPrimary(actionID: "promo")
            )
        }
    }

    func testHTTPSEnforced() {
        let http = makeAction(id: "a1", url: URL(string: "http://platform.openai.com/")!)
        XCTAssertThrowsError(try WebsiteActionResolver.validate([http])) { error in
            XCTAssertEqual(error as? WebsiteActionValidationError, .nonHTTPS(actionID: "a1"))
        }
    }

    func testUserProvidedNeverOfficial() {
        let user = WebsiteActionDescriptor(
            actionID: "user-1", owner: "Me", kind: .website, title: "自定义",
            url: URL(string: "https://example.com/")!, displayOrder: 9, isPrimary: false,
            isPromotional: false, source: .userProvided, verifiedAt: Date(), supportLevel: .ga
        )
        XCTAssertThrowsError(try WebsiteActionResolver.validate([user])) { error in
            XCTAssertEqual(error as? WebsiteActionValidationError, .userProvidedMarkedOfficial(actionID: "user-1"))
        }
    }

    // MARK: - primary 缺失

    func testMissingPrimaryShowsUnverifiedNotAssembledURL() throws {
        let noPrimary = [makeAction(id: "a1", primary: false)]
        try WebsiteActionResolver.validate(noPrimary)
        XCTAssertNil(
            WebsiteActionResolver.primaryButton(owner: "OpenAI", actions: noPrimary),
            "缺少 primary 显示「官方入口未验证」不拼 URL"
        )
        let withPrimary = [makeAction(id: "a1", primary: true)]
        XCTAssertNotNil(WebsiteActionResolver.primaryButton(owner: "OpenAI", actions: withPrimary))
        let apiKeyPrimary = [makeAction(id: "a2", kind: .apiKey, primary: true)]
        XCTAssertEqual(
            WebsiteActionResolver.primaryButton(owner: "OpenAI", actions: apiKeyPrimary)?.actionID,
            "a2"
        )
    }

    // MARK: - 打开流程（不附加 secret/header/会话）

    func testOpenPlanShowsDomainAndAttachesNothing() {
        let action = makeAction(id: "a1", url: URL(string: "https://platform.openai.com/account/billing")!)
        let plan = WebsiteActionResolver.openPlan(for: action)
        XCTAssertEqual(plan.displayedDomain, "platform.openai.com", "显示域名")
        XCTAssertEqual(plan.url, URL(string: "https://platform.openai.com/account/billing")!)
        XCTAssertTrue(plan.attachedSecrets.isEmpty, "不附加任何 secret")
        XCTAssertTrue(plan.attachedHeaders.isEmpty, "不附加任何 header")
    }

    // MARK: - restoreOfficialURL

    func testRestoreOfficialURLOnlyWithSuggestedURL() {
        XCTAssertTrue(WebsiteActionResolver.canRestoreOfficialURL(descriptor: makeAction(id: "a1")))
        XCTAssertFalse(WebsiteActionResolver.canRestoreOfficialURL(descriptor: nil))
        // origin 变化 → NeedsCredential（Base URL 与官网 URL 独立）
        let base = URL(string: "https://api.openai.com/v1")!
        let official = URL(string: "https://platform.openai.com/")!
        XCTAssertFalse(WebsiteActionResolver.originMatches(baseURL: base, officialURL: official))
        XCTAssertTrue(WebsiteActionResolver.requiresOriginConfirmation(baseURL: base, officialURL: official))
        // 失败保持原 URL
        XCTAssertEqual(WebsiteActionResolver.restoreOutcome(succeeded: false, currentBaseURL: "https://old.example.com"), "https://old.example.com")
    }

    // MARK: - mozhe 推广链接规则

    func testMozhePromotionOnlyAsSecondaryWithPlainOfficialAction() {
        let actions = BundledRuntimeCatalog.shared.websiteActions(
            ownerCatalogID: "provider.mozheapi"
        ).compactMap(\.descriptor)
        let catalogPromotion = actions.first(where: \.isPromotional)
        let catalogPrimary = actions.first { $0.isPrimary && !$0.isPromotional }
        let plan = WebsiteActionResolver.mozhePromotionPlan(actions: actions)

        XCTAssertEqual(plan.promotionalRegistrationLink, catalogPromotion?.url)
        XCTAssertEqual(plan.plainOfficialActionURL, catalogPrimary?.url)
        XCTAssertNotNil(plan.plainOfficialActionURL, "必须另提供无 aff 普通官网动作")
        XCTAssertFalse(
            plan.plainOfficialActionURL!.absoluteString.contains("aff="),
            "普通官网动作不带 aff 参数"
        )
        XCTAssertTrue(plan.affParameterPreserved, "不得隐藏/重写/追加推广参数")
    }

    // MARK: - origin 规范化与 Authorization 转发

    func testOriginNormalization() throws {
        // 小写 scheme + IDNA ASCII host + canonical port 省略
        XCTAssertEqual(
            try XCTUnwrap(WebsiteActionResolver.normalizedOrigin(url: URL(string: "HTTPS://API.Example.COM:443/v1")!)),
            "https://api.example.com"
        )
        XCTAssertEqual(
            try XCTUnwrap(WebsiteActionResolver.normalizedOrigin(url: URL(string: "http://example.com:80/")!)),
            "http://example.com"
        )
        // 非默认端口保留
        XCTAssertEqual(
            try XCTUnwrap(WebsiteActionResolver.normalizedOrigin(url: URL(string: "https://example.com:8443/")!)),
            "https://example.com:8443"
        )
    }

    func testAuthorizationNotForwardedAcrossOrigin() {
        let from = URL(string: "https://api.example.com/v1")!
        let sameOrigin = URL(string: "https://api.example.com/v1/chat")!
        XCTAssertTrue(WebsiteActionResolver.shouldForwardAuthorization(from: from, to: sameOrigin))

        let differentHost = URL(string: "https://cdn.example.com/")!
        XCTAssertFalse(WebsiteActionResolver.shouldForwardAuthorization(from: from, to: differentHost))
        let differentPort = URL(string: "https://api.example.com:8443/")!
        XCTAssertFalse(WebsiteActionResolver.shouldForwardAuthorization(from: from, to: differentPort))
        let differentScheme = URL(string: "http://api.example.com/")!
        XCTAssertFalse(WebsiteActionResolver.shouldForwardAuthorization(from: from, to: differentScheme))
    }

    func testFirstKeySendToCustomBaseURLRequiresOriginConfirmation() {
        // 自定义 Base URL（非官方 origin）→ 发 Key 前必须确认
        let official = URL(string: "https://api.openai.com/")!
        let custom = URL(string: "https://my-proxy.example.com/v1")!
        XCTAssertTrue(WebsiteActionResolver.requiresOriginConfirmation(baseURL: custom, officialURL: official))
        XCTAssertFalse(WebsiteActionResolver.requiresOriginConfirmation(baseURL: official, officialURL: official))
    }

    // MARK: - Base URL 与官网 URL 独立

    func testBaseURLAndOfficialURLIndependent() {
        // 两者独立：改了 Base URL 不影响官网动作可用性
        let action = makeAction(id: "a1", url: URL(string: "https://platform.openai.com/")!)
        XCTAssertTrue(WebsiteActionResolver.canRestoreOfficialURL(descriptor: action))
        XCTAssertEqual(
            WebsiteActionResolver.originMatches(
                baseURL: URL(string: "https://api.openai.com/v1")!,
                officialURL: URL(string: "https://platform.openai.com/")!
            ),
            false,
            "Base URL 与官网 URL 独立（不同 origin 仍各自有效）"
        )
    }
}
