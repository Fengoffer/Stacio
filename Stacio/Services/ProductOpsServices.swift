import AppKit
import CryptoKit
import Foundation

public enum ProductOpsError: LocalizedError, Equatable {
    case missingAPIBaseURL
    case missingFeedbackProductAPIKey
    case invalidResponseStatus(Int)
    case invalidURL
    case invalidOfflineLicenseToken
    case invalidFeedbackReport([FeedbackReportValidationError])
    case rateLimited(retryAfter: TimeInterval?, requestID: String?)
    case offline
    case timeout
    case client(message: String, requestID: String?)
    case server(message: String, requestID: String?)
    case licenseIdentityMismatch
    case invalidSignedLicenseToken
    case licenseClaimsMismatch
    case licenseStorageUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIBaseURL:
            return "尚未配置 Stacio 服务地址。"
        case .missingFeedbackProductAPIKey:
            return "尚未配置反馈产品公钥。"
        case .invalidResponseStatus(let statusCode):
            return "服务返回异常状态：HTTP \(statusCode)。"
        case .invalidURL:
            return "Stacio 服务地址无效。"
        case .invalidOfflineLicenseToken:
            return "离线授权 token 无效或签名校验未通过。"
        case .invalidFeedbackReport(let errors):
            return "反馈内容校验失败：\(errors.map(\.displayName).joined(separator: "、"))。"
        case .rateLimited(let retryAfter, let requestID):
            let suffix = requestID.map { " 请求 ID：\($0)。" } ?? ""
            if let retryAfter {
                return "请求过于频繁，请 \(Int(retryAfter)) 秒后重试。\(suffix)"
            }
            return "请求过于频繁，请稍后重试。\(suffix)"
        case .offline:
            return "网络不可用，请连接网络后重试。"
        case .timeout:
            return "请求超时，请稍后重试。"
        case .client(let message, let requestID):
            let suffix = requestID.map { " 请求 ID：\($0)。" } ?? ""
            return message.isEmpty ? "请求未被服务接受。\(suffix)" : "\(message)\(suffix)"
        case .server(let message, let requestID):
            let suffix = requestID.map { " 请求 ID：\($0)。" } ?? ""
            return message.isEmpty ? "服务暂时不可用。\(suffix)" : "\(message)\(suffix)"
        case .licenseIdentityMismatch:
            return "授权信息与填写的用户名或邮箱不匹配。"
        case .invalidSignedLicenseToken:
            return "后台返回的 License 签名无效。"
        case .licenseClaimsMismatch:
            return "后台返回的 License 签名内容与授权信息不一致。"
        case .licenseStorageUnavailable(let message):
            return "License 安全存储不可用：\(message)"
        }
    }

    public static func classify(_ error: Error) -> ProductOpsError {
        if let productOpsError = error as? ProductOpsError {
            return productOpsError
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .offline
            case .timedOut:
                return .timeout
            default:
                break
            }
        }
        return .server(message: error.localizedDescription, requestID: nil)
    }

    public static func responseError(data: Data, response: HTTPURLResponse) -> ProductOpsError {
        let requestID = response.value(forHTTPHeaderField: "X-Request-ID")
            ?? response.value(forHTTPHeaderField: "x-request-id")
        if response.statusCode == 429 {
            return .rateLimited(
                retryAfter: retryAfter(from: response.value(forHTTPHeaderField: "Retry-After")),
                requestID: requestID
            )
        }
        let message = serverMessage(from: data)
            ?? ((500..<600).contains(response.statusCode)
                ? "服务暂时不可用。"
                : "服务返回异常状态：HTTP \(response.statusCode)。")
        if (400..<500).contains(response.statusCode) {
            return .client(message: message, requestID: requestID)
        }
        return .server(message: message, requestID: requestID)
    }

    private static func retryAfter(from value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return seconds
        }
        return nil
    }

    private static func serverMessage(from data: Data) -> String? {
        guard data.isEmpty == false else { return nil }
        if let envelope = try? JSONDecoder.productOps.decode(ProductOpsServerErrorEnvelope.self, from: data) {
            return envelope.message ?? envelope.error?.message
        }
        let plainText = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return plainText.hasPrefix("{") ? nil : (plainText.isEmpty ? nil : plainText)
    }
}

private struct ProductOpsServerErrorEnvelope: Decodable {
    var error: ProductOpsServerErrorValue?
    var message: String?
}

private enum ProductOpsServerErrorValue: Decodable {
    case text(String)
    case details(message: String?, code: String?)

    var message: String? {
        switch self {
        case .text(let value):
            return value
        case .details(let message, let code):
            return message ?? code
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .text(value)
            return
        }
        let details = try container.decode(Details.self)
        self = .details(message: details.message, code: details.code)
    }

    private struct Details: Decodable {
        var code: String?
        var message: String?
    }
}

public enum ProductOpsReleaseChannel: String, Codable, Equatable, CaseIterable {
    case stable
    case beta

    public var displayName: String {
        switch self {
        case .stable:
            return "Stable"
        case .beta:
            return "Beta"
        }
    }
}

public struct ProductOpsConfiguration: Equatable {
    public var apiBaseURL: URL?
    public var feedbackProductAPIKey: String
    public var productID: String
    public var updateChannel: ProductOpsReleaseChannel
    public var betaUpdatesEnabled: Bool
    public var stableAppcastURL: URL?
    public var betaAppcastURL: URL?
    public var sparklePublicEDKey: String
    public var licensePublicKeyBase64: String

    public init(
        apiBaseURL: URL? = URL(string: "https://ops.stacio.cn"),
        feedbackProductAPIKey: String = "",
        productID: String = "stacio",
        updateChannel: ProductOpsReleaseChannel = .stable,
        betaUpdatesEnabled: Bool = false,
        stableAppcastURL: URL? = URL(string: "https://ops.stacio.cn/updates/stacio/stable/appcast.xml"),
        betaAppcastURL: URL? = URL(string: "https://ops.stacio.cn/updates/stacio/beta/appcast.xml"),
        sparklePublicEDKey: String = "",
        licensePublicKeyBase64: String = ""
    ) {
        self.apiBaseURL = apiBaseURL
        self.feedbackProductAPIKey = feedbackProductAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.productID = productID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "stacio" : productID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.updateChannel = updateChannel
        self.betaUpdatesEnabled = betaUpdatesEnabled
        self.stableAppcastURL = stableAppcastURL
        self.betaAppcastURL = betaAppcastURL
        self.sparklePublicEDKey = sparklePublicEDKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.licensePublicKeyBase64 = licensePublicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var effectiveUpdateChannel: ProductOpsReleaseChannel {
        betaUpdatesEnabled ? updateChannel : .stable
    }

    public var effectiveAppcastURL: URL? {
        switch effectiveUpdateChannel {
        case .stable:
            return stableAppcastURL
        case .beta:
            return betaAppcastURL ?? stableAppcastURL
        }
    }
}

public final class ProductOpsConfigurationStore {
    public enum Key {
        public static let productID = "StacioProductOpsProductID"
        public static let apiBaseURL = "Stacio.ProductOps.apiBaseURL"
        public static let updateChannel = "Stacio.ProductOps.updateChannel"
        public static let betaUpdatesEnabled = "Stacio.ProductOps.betaUpdatesEnabled"
        public static let feedbackProductAPIKey = "Stacio.ProductOps.feedbackProductAPIKey"
        public static let stableAppcastURL = "Stacio.ProductOps.stableAppcastURL"
        public static let betaAppcastURL = "Stacio.ProductOps.betaAppcastURL"
        public static let sparklePublicEDKey = "Stacio.ProductOps.sparklePublicEDKey"
        public static let licensePublicKeyBase64 = "Stacio.ProductOps.licensePublicKeyBase64"
    }

    private enum BundleKey {
        static let apiBaseURL = "StacioProductOpsAPIBaseURL"
        static let productID = "StacioProductOpsProductID"
        static let updateChannel = "StacioProductOpsUpdateChannel"
        static let betaUpdatesEnabled = "StacioProductOpsBetaUpdatesEnabled"
        static let feedbackProductAPIKey = "StacioFeedbackProductAPIKey"
        static let stableAppcastURL = "SUFeedURL"
        static let betaAppcastURL = "StacioSparkleBetaAppcastURL"
        static let sparklePublicEDKey = "SUPublicEDKey"
        static let licensePublicKeyBase64 = "StacioLicensePublicEd25519Key"
    }

    private let defaults: UserDefaults
    private let environment: [String: String]
    private let bundleInfo: [String: Any]
    private let allowsDevelopmentOverrides: Bool

    public init(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleInfo: [String: Any]? = nil,
        allowsDevelopmentOverrides: Bool = false
    ) {
        self.defaults = defaults
        self.environment = environment
        self.bundleInfo = bundleInfo ?? Bundle.main.infoDictionary ?? [:]
        self.allowsDevelopmentOverrides = allowsDevelopmentOverrides
    }

    public func load() -> ProductOpsConfiguration {
        let rawBaseURL = developmentOverride("STACIO_PRODUCT_OPS_API_BASE_URL")
            ?? stringValue(for: Key.apiBaseURL)
            ?? stringValue(for: BundleKey.apiBaseURL)
            ?? "https://ops.stacio.cn"
        let rawProductID = developmentOverride("STACIO_PRODUCT_OPS_PRODUCT_ID")
            ?? stringValue(for: Key.productID)
            ?? stringValue(for: BundleKey.productID)
            ?? "stacio"
        let rawChannel = defaults.string(forKey: Key.updateChannel)
            ?? stringValue(for: Key.updateChannel)
            ?? stringValue(for: BundleKey.updateChannel)
        let rawStableAppcast = developmentOverride("STACIO_SPARKLE_STABLE_APPCAST_URL")
            ?? stringValue(for: Key.stableAppcastURL)
            ?? stringValue(for: BundleKey.stableAppcastURL)
            ?? "https://ops.stacio.cn/updates/stacio/stable/appcast.xml"
        let rawBetaAppcast = developmentOverride("STACIO_SPARKLE_BETA_APPCAST_URL")
            ?? stringValue(for: Key.betaAppcastURL)
            ?? stringValue(for: BundleKey.betaAppcastURL)
            ?? "https://ops.stacio.cn/updates/stacio/beta/appcast.xml"
        let betaEnabled = (defaults.object(forKey: Key.betaUpdatesEnabled) as? Bool)
            ?? boolValue(for: Key.betaUpdatesEnabled)
            ?? boolValue(for: BundleKey.betaUpdatesEnabled)
            ?? false

        return ProductOpsConfiguration(
            apiBaseURL: URL.stacioProductOpsURL(from: rawBaseURL),
            feedbackProductAPIKey: developmentOverride("STACIO_FEEDBACK_PRODUCT_API_KEY")
                ?? stringValue(for: Key.feedbackProductAPIKey)
                ?? stringValue(for: BundleKey.feedbackProductAPIKey)
                ?? "",
            productID: rawProductID,
            updateChannel: rawChannel.flatMap(ProductOpsReleaseChannel.init(rawValue:)) ?? .stable,
            betaUpdatesEnabled: betaEnabled,
            stableAppcastURL: URL.stacioProductOpsURL(from: rawStableAppcast),
            betaAppcastURL: URL.stacioProductOpsURL(from: rawBetaAppcast),
            sparklePublicEDKey: developmentOverride("STACIO_SPARKLE_PUBLIC_ED_KEY")
                ?? stringValue(for: Key.sparklePublicEDKey)
                ?? stringValue(for: BundleKey.sparklePublicEDKey)
                ?? "",
            licensePublicKeyBase64: developmentOverride("STACIO_LICENSE_PUBLIC_ED25519_KEY")
                ?? stringValue(for: Key.licensePublicKeyBase64)
                ?? stringValue(for: BundleKey.licensePublicKeyBase64)
                ?? ""
        )
    }

    public func save(_ configuration: ProductOpsConfiguration) {
        defaults.set(configuration.updateChannel.rawValue, forKey: Key.updateChannel)
        defaults.set(configuration.betaUpdatesEnabled, forKey: Key.betaUpdatesEnabled)
        defaults.removeObject(forKey: Key.apiBaseURL)
        defaults.removeObject(forKey: Key.productID)
        defaults.removeObject(forKey: Key.feedbackProductAPIKey)
        defaults.removeObject(forKey: Key.stableAppcastURL)
        defaults.removeObject(forKey: Key.betaAppcastURL)
        defaults.removeObject(forKey: Key.sparklePublicEDKey)
        defaults.removeObject(forKey: Key.licensePublicKeyBase64)
    }

    private func developmentOverride(_ key: String) -> String? {
        guard allowsDevelopmentOverrides else { return nil }
        return environment[key]
    }

    private func stringValue(for key: String) -> String? {
        bundleInfo[key] as? String
    }

    private func boolValue(for key: String) -> Bool? {
        if let value = bundleInfo[key] as? Bool {
            return value
        }
        if let value = bundleInfo[key] as? String {
            return boolValue(value)
        }
        return nil
    }

    private func boolValue(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}

private extension URL {
    static func stacioProductOpsURL(from value: String?) -> URL? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return URL(string: trimmed)
    }
}

public enum ProductOpsEndpointPolicy {
    public static func isAllowedAPIBaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              host.isEmpty == false
        else {
            return false
        }
        if scheme == "https" {
            return true
        }
        guard scheme == "http" else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    public static func validatedAPIBaseURL(_ url: URL?) throws -> URL {
        guard let url else {
            throw ProductOpsError.missingAPIBaseURL
        }
        guard isAllowedAPIBaseURL(url) else {
            throw ProductOpsError.invalidURL
        }
        return url
    }
}

public extension JSONEncoder {
    static var productOps: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var productOps: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = ProductOpsISO8601DateParser.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date: \(value)"
                )
            }
            return date
        }
        return decoder
    }
}

private enum ProductOpsISO8601DateParser {
    static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

public protocol ProductOpsHTTPClient: AnyObject {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class URLSessionProductOpsHTTPClient: ProductOpsHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProductOpsError.invalidURL
        }
        return (data, httpResponse)
    }
}

public struct ProductOpsRetryPolicy: Equatable {
    public var maxAttempts: Int
    public var delay: TimeInterval

    public init(maxAttempts: Int = 1, delay: TimeInterval = 0.25) {
        self.maxAttempts = max(1, maxAttempts)
        self.delay = max(0, delay)
    }

    public static func immediate(maxAttempts: Int) -> ProductOpsRetryPolicy {
        ProductOpsRetryPolicy(maxAttempts: maxAttempts, delay: 0)
    }

    public static let none = ProductOpsRetryPolicy(maxAttempts: 1, delay: 0)
}

public protocol FeedbackSubmitting: AnyObject {
    func submit(
        report: FeedbackReport,
        context: FeedbackDiagnosticContext,
        idempotencyKey: String
    ) async throws -> FeedbackSubmissionResult
}

public extension FeedbackSubmitting {
    func submit(
        report: FeedbackReport,
        context: FeedbackDiagnosticContext
    ) async throws -> FeedbackSubmissionResult {
        try await submit(
            report: report,
            context: context,
            idempotencyKey: UUID().uuidString
        )
    }
}

public final class AnonymousDeviceIdentifierStore {
    public static let shared = AnonymousDeviceIdentifierStore()
    public static let defaultsKey = "Stacio.ProductOps.anonymousDeviceID"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func deviceID() -> String {
        if let existing = defaults.string(forKey: Self.defaultsKey),
           existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: Self.defaultsKey)
        return generated
    }
}

public enum FeedbackType: String, Codable, Equatable, CaseIterable {
    case bug
    case feature
    case question
    case crash
    case updateIssue = "update_issue"
    case licenseIssue = "license_issue"
    case other

    public var displayName: String {
        switch self {
        case .bug:
            return "Bug"
        case .feature:
            return "功能建议"
        case .question:
            return "使用问题"
        case .crash:
            return "崩溃"
        case .updateIssue:
            return "更新问题"
        case .licenseIssue:
            return "License 问题"
        case .other:
            return "其他"
        }
    }
}

public enum FeedbackReportValidationError: Equatable {
    case missingTitle
    case missingDescription
    case titleTooLong
    case descriptionTooLong
    case invalidContactEmail

    public var displayName: String {
        switch self {
        case .missingTitle:
            return "标题不能为空"
        case .missingDescription:
            return "详细描述不能为空"
        case .titleTooLong:
            return "标题不能超过 240 个字符"
        case .descriptionTooLong:
            return "详细描述不能超过 50000 个字符"
        case .invalidContactEmail:
            return "联系邮箱格式不正确"
        }
    }
}

public struct FeedbackReport: Equatable {
    public static let maximumTitleLength = 240
    public static let maximumDescriptionLength = 50_000

    public var title: String
    public var type: FeedbackType
    public var description: String
    public var contact: String?
    public var includeDiagnostics: Bool

    public init(
        title: String,
        type: FeedbackType,
        description: String,
        contact: String?,
        includeDiagnostics: Bool = false
    ) {
        self.title = title
        self.type = type
        self.description = description
        self.contact = contact
        self.includeDiagnostics = includeDiagnostics
    }

    public var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var normalizedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var normalizedContact: String? {
        let cleaned = contact?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }

    public var validationErrors: [FeedbackReportValidationError] {
        var errors: [FeedbackReportValidationError] = []
        if normalizedTitle.isEmpty {
            errors.append(.missingTitle)
        }
        if normalizedDescription.isEmpty {
            errors.append(.missingDescription)
        }
        if normalizedTitle.count > Self.maximumTitleLength {
            errors.append(.titleTooLong)
        }
        if normalizedDescription.count > Self.maximumDescriptionLength {
            errors.append(.descriptionTooLong)
        }
        if let contact = normalizedContact,
           Self.emailRegex.firstMatch(in: contact, range: NSRange(location: 0, length: (contact as NSString).length)) == nil {
            errors.append(.invalidContactEmail)
        }
        return errors
    }

    private static let emailRegex = try! NSRegularExpression(
        pattern: #"^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$"#,
        options: [.caseInsensitive]
    )
}

public protocol FeedbackIdempotencyKeyStoring: AnyObject {
    func key(for report: FeedbackReport, context: FeedbackDiagnosticContext) -> String
    func clearKey(
        for report: FeedbackReport,
        context: FeedbackDiagnosticContext,
        matching idempotencyKey: String
    )
}

public extension FeedbackIdempotencyKeyStoring {
    func key(for report: FeedbackReport) -> String {
        key(for: report, context: FeedbackDiagnosticContext(appVersion: "", build: "", osVersion: "", deviceID: ""))
    }

    func clearKey(for report: FeedbackReport, matching idempotencyKey: String) {
        clearKey(
            for: report,
            context: FeedbackDiagnosticContext(appVersion: "", build: "", osVersion: "", deviceID: ""),
            matching: idempotencyKey
        )
    }
}

public final class FeedbackIdempotencyKeyStore: FeedbackIdempotencyKeyStoring {
    public static let defaultsKey = "Stacio.ProductOps.feedbackIdempotency"

    private struct Record: Codable {
        var fingerprint: String
        var idempotencyKey: String
        var createdAt: Date
    }

    private let defaults: UserDefaults
    private let maxAge: TimeInterval
    private let now: () -> Date

    public init(
        defaults: UserDefaults = .standard,
        maxAge: TimeInterval = 7 * 24 * 60 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.maxAge = max(0, maxAge)
        self.now = now
    }

    public func key(for report: FeedbackReport, context: FeedbackDiagnosticContext) -> String {
        let fingerprint = Self.fingerprint(for: report, context: context)
        let currentDate = now()
        if let existing = storedRecord(),
           existing.fingerprint == fingerprint {
            let age = currentDate.timeIntervalSince(existing.createdAt)
            if age >= 0, age <= maxAge {
                return existing.idempotencyKey
            }
        }

        let generated = UUID().uuidString
        let record = Record(
            fingerprint: fingerprint,
            idempotencyKey: generated,
            createdAt: currentDate
        )
        if let encoded = try? JSONEncoder.productOps.encode(record) {
            defaults.set(encoded, forKey: Self.defaultsKey)
        }
        return generated
    }

    public func clearKey(
        for report: FeedbackReport,
        context: FeedbackDiagnosticContext,
        matching idempotencyKey: String
    ) {
        guard let existing = storedRecord(),
              existing.fingerprint == Self.fingerprint(for: report, context: context),
              existing.idempotencyKey == idempotencyKey
        else {
            return
        }
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func storedRecord() -> Record? {
        guard let encoded = defaults.data(forKey: Self.defaultsKey) else {
            return nil
        }
        return try? JSONDecoder.productOps.decode(Record.self, from: encoded)
    }

    private static func fingerprint(for report: FeedbackReport, context: FeedbackDiagnosticContext) -> String {
        let diagnosticsFingerprint: String
        if report.includeDiagnostics {
            diagnosticsFingerprint = context.sanitizedDiagnostics
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "\u{0}")
        } else {
            diagnosticsFingerprint = ""
        }
        let canonical = [
            report.type.rawValue,
            report.normalizedTitle,
            report.normalizedDescription,
            report.normalizedContact ?? "",
            report.includeDiagnostics ? "1" : "0",
            context.appVersion,
            context.build,
            context.osVersion,
            context.deviceID,
            context.licenseStatus.rawValue,
            diagnosticsFingerprint
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct FeedbackDiagnosticContext: Codable, Equatable {
    public var appVersion: String
    public var build: String
    public var osVersion: String
    public var deviceID: String
    public var licenseStatus: LicenseStatus
    public var diagnostics: [String: String]

    public init(
        appVersion: String,
        build: String,
        osVersion: String,
        deviceID: String,
        licenseStatus: LicenseStatus = .inactive,
        diagnostics: [String: String] = [:]
    ) {
        self.appVersion = appVersion
        self.build = build
        self.osVersion = osVersion
        self.deviceID = deviceID
        self.licenseStatus = licenseStatus
        self.diagnostics = diagnostics
    }

    public static func current(
        configuration: ProductOpsConfiguration,
        deviceIDStore: AnonymousDeviceIdentifierStore = .shared,
        licenseService: LicenseService = LicenseService(),
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> FeedbackDiagnosticContext {
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? StacioAppMetadata.displayVersion
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "dev"
        return FeedbackDiagnosticContext(
            appVersion: appVersion,
            build: build,
            osVersion: processInfo.operatingSystemVersionString,
            deviceID: deviceIDStore.deviceID(),
            licenseStatus: licenseService.loadState().status,
            diagnostics: [
                "productID": configuration.productID,
                "configuredUpdateChannel": configuration.effectiveUpdateChannel.rawValue,
                "betaUpdatesEnabled": configuration.betaUpdatesEnabled ? "true" : "false"
            ]
        )
    }

    public var sanitizedDiagnostics: [String: String] {
        ProductOpsDiagnosticSanitizer.sanitized(diagnostics)
    }

    public var visibleSummary: String {
        var lines = [
            "App 版本：\(appVersion)",
            "Build：\(build)",
            "macOS：\(osVersion)",
            "匿名设备标识：\(deviceID)",
            "License 状态：\(licenseStatus.rawValue)"
        ]
        if sanitizedDiagnostics.isEmpty == false {
            let diagnosticsLine = sanitizedDiagnostics
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "；")
            lines.append("诊断上下文：\(diagnosticsLine)")
        }
        lines.append(Self.privacySummary)
        return lines.joined(separator: "\n")
    }

    public static let privacySummary = "不会包含密码、Token、完整 License Key、终端内容、远程文件内容、SSH 配置或用户文件。"
}

public enum ProductOpsDiagnosticSanitizer {
    private static let allowedKeys: Set<String> = [
        "productID",
        "configuredUpdateChannel",
        "betaUpdatesEnabled",
        "activeWindowCount"
    ]

    public static func sanitized(_ diagnostics: [String: String]) -> [String: String] {
        diagnostics.reduce(into: [:]) { partial, pair in
            guard allowedKeys.contains(pair.key) else { return }
            let value = redactSensitiveValue(pair.value)
            guard value.isEmpty == false,
                  isAllowedValue(value, forKey: pair.key)
            else { return }
            partial[pair.key] = value
        }
    }

    public static func redactSensitiveValue(_ value: String) -> String {
        let trimmed = String(value.prefix(1_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }
        let fullySensitivePatterns = [
            #"(?i)^basic\s+[A-Za-z0-9+/=]+$"#,
            #"(?i)^bearer\s+\S+$"#,
            #"^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$"#,
            #"(?i)^(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})$"#,
            #"(?s)^-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----.*$"#,
            #"\bSTACIO-[A-Z0-9\-]{8,}\b"#
        ]
        guard fullySensitivePatterns.contains(where: {
            trimmed.range(of: $0, options: [.regularExpression]) != nil
        }) == false else {
            return ""
        }

        var redacted = value
        let patterns = [
            #"(?i)(password|passwd|token|api[_-]?key|authorization|license[_ -]?key)\s*[:=]\s*\S+"#,
            #"(?i)bearer\s+[A-Za-z0-9._\-]+"#
        ]
        for pattern in patterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: "$1=[redacted]",
                options: [.regularExpression]
            )
        }
        return String(redacted.prefix(1_000)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAllowedValue(_ value: String, forKey key: String) -> Bool {
        switch key {
        case "productID":
            return value.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: [.regularExpression]) != nil
        case "configuredUpdateChannel":
            return ProductOpsReleaseChannel(rawValue: value.lowercased()) != nil
        case "betaUpdatesEnabled":
            return value == "true" || value == "false"
        case "activeWindowCount":
            return Int(value).map { $0 >= 0 && $0 <= 10_000 } ?? false
        default:
            return false
        }
    }
}

public struct FeedbackPayload: Codable, Equatable {
    public var productID: String
    public var title: String
    public var type: FeedbackType
    public var description: String
    public var contact: String?
    public var appVersion: String
    public var build: String
    public var osVersion: String
    public var deviceID: String
    public var licenseStatus: LicenseStatus
    public var diagnostics: [String: String]?
    public var privacySummary: String

    enum CodingKeys: String, CodingKey {
        case productID = "productId"
        case title
        case type
        case description
        case contact = "contactEmail"
        case appVersion
        case build = "buildNumber"
        case osVersion
        case deviceID = "anonymousDeviceId"
        case licenseStatus = "licenseState"
        case diagnostics = "diagnosticsSummary"
        case privacySummary
    }
}

public struct FeedbackSubmissionResult: Codable, Equatable {
    public var id: String?
    public var message: String?

    public init(id: String? = nil, message: String? = nil) {
        self.id = id
        self.message = message
    }
}

private struct FeedbackSubmissionEnvelope: Decodable {
    var ok: Bool
    var data: FeedbackSubmissionEnvelopeData?
    var message: String?
    var error: ProductOpsServerErrorValue?
}

private struct FeedbackSubmissionEnvelopeData: Decodable {
    var id: String?
}

public final class FeedbackSubmissionService {
    private let configuration: ProductOpsConfiguration
    private let httpClient: ProductOpsHTTPClient
    private let retryPolicy: ProductOpsRetryPolicy

    public init(
        configuration: ProductOpsConfiguration,
        httpClient: ProductOpsHTTPClient = URLSessionProductOpsHTTPClient(),
        retryPolicy: ProductOpsRetryPolicy = ProductOpsRetryPolicy(maxAttempts: 3)
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.retryPolicy = retryPolicy
    }

    public static func payload(
        report: FeedbackReport,
        context: FeedbackDiagnosticContext,
        configuration: ProductOpsConfiguration
    ) throws -> FeedbackPayload {
        guard report.validationErrors.isEmpty else {
            throw ProductOpsError.invalidFeedbackReport(report.validationErrors)
        }
        return FeedbackPayload(
            productID: configuration.productID,
            title: report.normalizedTitle,
            type: report.type,
            description: report.normalizedDescription,
            contact: report.normalizedContact,
            appVersion: context.appVersion,
            build: context.build,
            osVersion: context.osVersion,
            deviceID: context.deviceID,
            licenseStatus: context.licenseStatus,
            diagnostics: report.includeDiagnostics ? context.sanitizedDiagnostics : nil,
            privacySummary: FeedbackDiagnosticContext.privacySummary
        )
    }

    public static func makeRequest(
        report: FeedbackReport,
        context: FeedbackDiagnosticContext,
        configuration: ProductOpsConfiguration,
        idempotencyKey: String = UUID().uuidString
    ) throws -> URLRequest {
        let baseURL = try ProductOpsEndpointPolicy.validatedAPIBaseURL(configuration.apiBaseURL)
        guard configuration.feedbackProductAPIKey.isEmpty == false else {
            throw ProductOpsError.missingFeedbackProductAPIKey
        }
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("public")
            .appendingPathComponent("products")
            .appendingPathComponent(configuration.productID)
            .appendingPathComponent("feedback")
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.feedbackProductAPIKey, forHTTPHeaderField: "x-product-api-key")
        request.setValue(idempotencyKey, forHTTPHeaderField: "X-Idempotency-Key")
        request.httpBody = try JSONEncoder.productOps.encode(payload(
            report: report,
            context: context,
            configuration: configuration
        ))
        return request
    }

    public func submit(
        report: FeedbackReport,
        context: FeedbackDiagnosticContext
    ) async throws -> FeedbackSubmissionResult {
        try await submit(report: report, context: context, idempotencyKey: UUID().uuidString)
    }

    public func submit(
        report: FeedbackReport,
        context: FeedbackDiagnosticContext,
        idempotencyKey: String
    ) async throws -> FeedbackSubmissionResult {
        let request = try Self.makeRequest(
            report: report,
            context: context,
            configuration: configuration,
            idempotencyKey: idempotencyKey
        )
        var lastError: Error?
        for attempt in 1...retryPolicy.maxAttempts {
            do {
                let (data, response) = try await httpClient.data(for: request)
                guard (200..<300).contains(response.statusCode) else {
                    throw ProductOpsError.responseError(data: data, response: response)
                }
                if data.isEmpty {
                    return FeedbackSubmissionResult(message: "ok")
                }
                let requestID = response.value(forHTTPHeaderField: "X-Request-ID")
                    ?? response.value(forHTTPHeaderField: "x-request-id")
                if let envelope = try? JSONDecoder.productOps.decode(FeedbackSubmissionEnvelope.self, from: data) {
                    guard envelope.ok else {
                        throw ProductOpsError.client(
                            message: envelope.message ?? envelope.error?.message ?? "反馈未被服务接受。",
                            requestID: requestID
                        )
                    }
                    return FeedbackSubmissionResult(id: envelope.data?.id, message: envelope.message)
                }
                if let result = try? JSONDecoder.productOps.decode(FeedbackSubmissionResult.self, from: data),
                   result.id?.isEmpty == false || result.message?.isEmpty == false {
                    return result
                }
                throw ProductOpsError.client(message: "反馈服务返回了无法识别的响应。", requestID: requestID)
            } catch {
                lastError = error
                let classified = ProductOpsError.classify(error)
                guard attempt < retryPolicy.maxAttempts, classified.isRetryable else {
                    throw classified
                }
                if retryPolicy.delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(retryPolicy.delay * 1_000_000_000))
                }
            }
        }
        throw ProductOpsError.classify(lastError ?? URLError(.unknown))
    }
}

extension FeedbackSubmissionService: FeedbackSubmitting {}

private extension ProductOpsError {
    var isRetryable: Bool {
        switch self {
        case .offline, .timeout, .server:
            return true
        default:
            return false
        }
    }
}

public struct UpdateInfo: Codable, Equatable {
    public var version: String
    public var build: String
    public var channel: ProductOpsReleaseChannel
    public var releaseNotes: String
    public var artifactURL: URL?
    public var publishedAt: Date?
    public var minSupportedVersion: String?
    public var packageSize: Int64?

    public init(
        version: String,
        build: String,
        channel: ProductOpsReleaseChannel,
        releaseNotes: String,
        artifactURL: URL?,
        publishedAt: Date?,
        minSupportedVersion: String?,
        packageSize: Int64? = nil
    ) {
        self.version = version
        self.build = build
        self.channel = channel
        self.releaseNotes = releaseNotes
        self.artifactURL = artifactURL
        self.publishedAt = publishedAt
        self.minSupportedVersion = minSupportedVersion
        self.packageSize = packageSize
    }
}

public enum UpdateCheckStatus: Equatable {
    case upToDate
    case updateAvailable(UpdateInfo)
    case appcastUnavailable(String)
    case noVersionInAppcast
    case signatureFailure(String)
    case downloadFailure(String)
}

public protocol UpdateChecking: AnyObject {
    func checkForUpdates() async throws -> UpdateCheckStatus
}

public enum UpdateVersionComparator {
    public static func isUpdate(
        _ update: UpdateInfo,
        newerThanVersion currentVersion: String,
        build currentBuild: String
    ) -> Bool {
        let versionComparison = compareVersions(update.version, currentVersion)
        if versionComparison != .orderedSame {
            return versionComparison == .orderedDescending
        }
        return compareBuilds(update.build, currentBuild) == .orderedDescending
    }

    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsVersion = parsedVersion(lhs)
        let rhsVersion = parsedVersion(rhs)
        let count = max(lhsVersion.numericParts.count, rhsVersion.numericParts.count)
        for index in 0..<count {
            let lhsValue = index < lhsVersion.numericParts.count ? lhsVersion.numericParts[index] : 0
            let rhsValue = index < rhsVersion.numericParts.count ? rhsVersion.numericParts[index] : 0
            if lhsValue < rhsValue {
                return .orderedAscending
            }
            if lhsValue > rhsValue {
                return .orderedDescending
            }
        }
        return comparePrerelease(lhsVersion.prereleaseParts, rhsVersion.prereleaseParts)
    }

    private static func compareBuilds(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let lhsInt = Int(lhs), let rhsInt = Int(rhs) {
            if lhsInt < rhsInt {
                return .orderedAscending
            }
            if lhsInt > rhsInt {
                return .orderedDescending
            }
            return .orderedSame
        }
        return lhs.localizedStandardCompare(rhs)
    }

    private static func parsedVersion(_ value: String) -> ParsedVersion {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Stacio-", with: "", options: [.anchored, .caseInsensitive])
            .replacingOccurrences(of: "v", with: "", options: [.anchored, .caseInsensitive])
        let components = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numericParts = String(components.first ?? "")
            .split(separator: ".")
            .map { part in
                let digits = part.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
        let prereleaseParts = components.count > 1
            ? components[1].split(separator: ".").map(String.init)
            : []
        return ParsedVersion(numericParts: numericParts, prereleaseParts: prereleaseParts)
    }

    private static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        if lhs.isEmpty, rhs.isEmpty {
            return .orderedSame
        }
        if lhs.isEmpty {
            return .orderedDescending
        }
        if rhs.isEmpty {
            return .orderedAscending
        }
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            guard index < lhs.count else { return .orderedAscending }
            guard index < rhs.count else { return .orderedDescending }
            let lhsPart = lhs[index]
            let rhsPart = rhs[index]
            if let lhsNumber = Int(lhsPart), let rhsNumber = Int(rhsPart) {
                if lhsNumber < rhsNumber { return .orderedAscending }
                if lhsNumber > rhsNumber { return .orderedDescending }
                continue
            }
            if Int(lhsPart) != nil { return .orderedAscending }
            if Int(rhsPart) != nil { return .orderedDescending }
            let comparison = lhsPart.caseInsensitiveCompare(rhsPart)
            if comparison != .orderedSame {
                return comparison
            }
        }
        return .orderedSame
    }

    private struct ParsedVersion {
        var numericParts: [Int]
        var prereleaseParts: [String]
    }
}

public struct SparkleUpdateConfiguration: Equatable {
    public var feedURL: URL?
    public var publicEDKey: String
    public var automaticallyChecksForUpdates: Bool
    public var automaticallyDownloadsUpdates: Bool

    public init(configuration: ProductOpsConfiguration) {
        self.feedURL = configuration.effectiveAppcastURL
        self.publicEDKey = configuration.sparklePublicEDKey
        self.automaticallyChecksForUpdates = false
        self.automaticallyDownloadsUpdates = false
    }
}

public final class UpdateCheckService {
    private let configuration: ProductOpsConfiguration
    private let currentVersion: String
    private let currentBuild: String
    private let httpClient: ProductOpsHTTPClient

    public init(
        configuration: ProductOpsConfiguration,
        currentVersion: String,
        currentBuild: String,
        httpClient: ProductOpsHTTPClient = URLSessionProductOpsHTTPClient()
    ) {
        self.configuration = configuration
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.httpClient = httpClient
    }

    public convenience init(
        configuration: ProductOpsConfiguration,
        bundle: Bundle = .main,
        httpClient: ProductOpsHTTPClient = URLSessionProductOpsHTTPClient()
    ) {
        self.init(
            configuration: configuration,
            currentVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? StacioAppMetadata.displayVersion,
            currentBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev",
            httpClient: httpClient
        )
    }

    public func checkForUpdates() async throws -> UpdateCheckStatus {
        let request = try makeRequest()
        let (data, response) = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw ProductOpsError.responseError(data: data, response: response)
        }
        guard data.isEmpty == false else {
            return .noVersionInAppcast
        }
        let update = try JSONDecoder.productOps.decode(UpdateInfo.self, from: data)
        if UpdateVersionComparator.isUpdate(
            update,
            newerThanVersion: currentVersion,
            build: currentBuild
        ) {
            return .updateAvailable(update)
        }
        return .upToDate
    }

    public func makeRequest() throws -> URLRequest {
        let baseURL = try ProductOpsEndpointPolicy.validatedAPIBaseURL(configuration.apiBaseURL)
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("public")
            .appendingPathComponent("products")
            .appendingPathComponent(configuration.productID)
            .appendingPathComponent("updates")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ProductOpsError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "channel", value: configuration.effectiveUpdateChannel.rawValue),
            URLQueryItem(name: "version", value: currentVersion),
            URLQueryItem(name: "build", value: currentBuild)
        ]
        guard let requestURL = components.url else {
            throw ProductOpsError.invalidURL
        }
        var request = URLRequest(url: requestURL, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

extension UpdateCheckService: UpdateChecking {}

@MainActor
public protocol ProductOpsURLOpening: AnyObject {
    func open(_ url: URL)
}

@MainActor
public final class WorkspaceProductOpsURLOpener: ProductOpsURLOpening {
    public init() {}

    public func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

public enum LicenseStatus: String, Codable, Equatable {
    case inactive
    case trial
    case active
    case offlineActive
    case offlineGrace
    case expired
    case suspended
    case revoked
    case networkUnavailable
    case invalid

    public var displayName: String {
        switch self {
        case .inactive:
            return "未激活"
        case .trial:
            return "试用有效"
        case .active:
            return "在线授权有效"
        case .offlineActive:
            return "离线授权有效"
        case .offlineGrace:
            return "离线宽限期"
        case .expired:
            return "已过期"
        case .suspended:
            return "已暂停"
        case .revoked:
            return "已撤销"
        case .networkUnavailable:
            return "网络不可用"
        case .invalid:
            return "授权无效"
        }
    }
}

public struct DeviceIdentifierHasher {
    public static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct OfflineLicenseToken: Codable, Equatable {
    public var productID: String
    public var username: String
    public var email: String
    public var plan: String
    public var permissions: [String]
    public var issuedAt: Date
    public var expiresAt: Date
    public var signedLicenseToken: String
    public var signatureKeyID: String
    public var signature: String

    public init(
        productID: String = "stacio",
        username: String,
        email: String,
        plan: String,
        permissions: [String] = [],
        issuedAt: Date,
        expiresAt: Date,
        signedLicenseToken: String = "",
        signatureKeyID: String,
        signature: String
    ) {
        self.productID = productID
        self.username = username
        self.email = email
        self.plan = plan
        self.permissions = permissions
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.signedLicenseToken = signedLicenseToken
        self.signatureKeyID = signatureKeyID
        self.signature = signature
    }

    public func signedPayload() throws -> Data {
        var copy = self
        copy.signature = ""
        return try JSONEncoder.productOps.encode(copy)
    }
}

public struct LicenseState: Codable, Equatable {
    public var username: String
    public var email: String
    public var signedLicenseToken: String
    public var plan: String
    public var permissions: [String]
    public var expiresAt: Date?
    public var graceUntil: Date?
    public var status: LicenseStatus
    public var lastValidatedAt: Date?
    public var offlineToken: OfflineLicenseToken?

    public init(
        username: String = "",
        email: String = "",
        signedLicenseToken: String = "",
        plan: String = "",
        permissions: [String] = [],
        expiresAt: Date? = nil,
        graceUntil: Date? = nil,
        status: LicenseStatus = .inactive,
        lastValidatedAt: Date? = nil,
        offlineToken: OfflineLicenseToken? = nil
    ) {
        self.username = username
        self.email = email
        self.signedLicenseToken = signedLicenseToken
        self.plan = plan
        self.permissions = permissions
        self.expiresAt = expiresAt
        self.graceUntil = graceUntil
        self.status = status
        self.lastValidatedAt = lastValidatedAt
        self.offlineToken = offlineToken
    }
}

public protocol LicenseStateStoring: AnyObject {
    func load() throws -> LicenseState?
    func save(_ state: LicenseState) throws
}

public final class UserDefaultsLicenseStateStore: LicenseStateStoring {
    public static let defaultsKey = "Stacio.License.state.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() throws -> LicenseState? {
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            return nil
        }
        return try JSONDecoder.productOps.decode(LicenseState.self, from: data)
    }

    public func save(_ state: LicenseState) throws {
        let data = try JSONEncoder.productOps.encode(state)
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

public final class KeychainLicenseStateStore: LicenseStateStoring {
    public static let credentialID = "product-ops-license-state"
    public static let account = "stacio-license"
    public static let legacyDefaultsKey = UserDefaultsLicenseStateStore.defaultsKey

    private let credentialStore: KeychainCredentialStore
    private let defaults: UserDefaults

    public init(
        credentialStore: KeychainCredentialStore = KeychainCredentialStore(),
        defaults: UserDefaults = .standard
    ) {
        self.credentialStore = credentialStore
        self.defaults = defaults
    }

    public func load() throws -> LicenseState? {
        do {
            let secret = try credentialStore.readSecret(id: Self.credentialID, account: Self.account)
            guard let data = secret.data(using: .utf8) else {
                throw ProductOpsError.licenseStorageUnavailable("License 状态编码无效。")
            }
            return try JSONDecoder.productOps.decode(LicenseState.self, from: data)
        } catch KeychainCredentialError.notFound {
            return try migrateLegacyDefaultsStateIfNeeded()
        } catch let error as ProductOpsError {
            throw error
        } catch {
            throw ProductOpsError.licenseStorageUnavailable(error.localizedDescription)
        }
    }

    public func save(_ state: LicenseState) throws {
        do {
            let data = try JSONEncoder.productOps.encode(state)
            guard let secret = String(data: data, encoding: .utf8) else {
                throw ProductOpsError.licenseStorageUnavailable("License 状态编码无效。")
            }
            try credentialStore.save(KeychainCredential(
                id: Self.credentialID,
                account: Self.account,
                secret: secret
            ))
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
        } catch let error as ProductOpsError {
            throw error
        } catch {
            throw ProductOpsError.licenseStorageUnavailable(error.localizedDescription)
        }
    }

    private func migrateLegacyDefaultsStateIfNeeded() throws -> LicenseState? {
        guard let data = defaults.data(forKey: Self.legacyDefaultsKey) else {
            return nil
        }
        let state = try JSONDecoder.productOps.decode(LicenseState.self, from: data)
        try save(state)
        return state
    }
}

extension KeychainLicenseStateStore: LegacyLicenseStateMigrating {
    public func loadLegacyLicenseState() throws -> LicenseState? {
        try load()
    }

    public func deleteLegacyLicenseState() throws {
        do {
            try credentialStore.delete(id: Self.credentialID, account: Self.account)
        } catch KeychainCredentialError.notFound {
            // The legacy UserDefaults migration may be the only stored source.
        }
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
    }
}

public protocol OfflineLicenseTokenVerifying {
    func validate(_ token: OfflineLicenseToken) -> Bool
}

public struct Ed25519OfflineLicenseTokenVerifier: OfflineLicenseTokenVerifying {
    public var publicKeyBase64: String
    public var expectedProductID: String

    public init(publicKeyBase64: String, expectedProductID: String = "stacio") {
        self.publicKeyBase64 = publicKeyBase64
        self.expectedProductID = expectedProductID
    }

    public func validate(_ token: OfflineLicenseToken) -> Bool {
        guard token.productID == expectedProductID,
              let publicKeyData = Ed25519PublicKeyMaterial.rawRepresentation(from: publicKeyBase64),
              let signatureData = Data(base64Encoded: token.signature),
              let payload = try? token.signedPayload()
        else {
            return false
        }
        do {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
            return publicKey.isValidSignature(signatureData, for: payload)
        } catch {
            return false
        }
    }
}

public struct PublicKeyOfflineLicenseTokenVerifier: OfflineLicenseTokenVerifying {
    public var publicKeyBase64: String
    public var expectedProductID: String

    public init(publicKeyBase64: String = "", expectedProductID: String = "stacio") {
        self.publicKeyBase64 = publicKeyBase64
        self.expectedProductID = expectedProductID
    }

    public func validate(_ token: OfflineLicenseToken) -> Bool {
        Ed25519OfflineLicenseTokenVerifier(
            publicKeyBase64: publicKeyBase64,
            expectedProductID: expectedProductID
        )
        .validate(token)
    }
}

public struct SignedLicenseClaims: Codable, Equatable {
    public var licenseID: String
    public var productID: String
    public var email: String
    public var username: String
    public var plan: String
    public var entitlements: [String]
    public var expiresAt: Date
    public var offlineGraceSeconds: TimeInterval
    public var issuedAt: Date

    public init(
        licenseID: String,
        productID: String,
        email: String,
        username: String,
        plan: String,
        entitlements: [String],
        expiresAt: Date,
        offlineGraceSeconds: TimeInterval,
        issuedAt: Date
    ) {
        self.licenseID = licenseID
        self.productID = productID
        self.email = email
        self.username = username
        self.plan = plan
        self.entitlements = entitlements
        self.expiresAt = expiresAt
        self.offlineGraceSeconds = offlineGraceSeconds
        self.issuedAt = issuedAt
    }

    enum CodingKeys: String, CodingKey {
        case licenseID = "licenseId"
        case productID = "productId"
        case email
        case username
        case plan
        case entitlements
        case expiresAt
        case offlineGraceSeconds
        case issuedAt
    }
}

public protocol SignedLicenseTokenVerifying {
    func verifiedClaims(from token: String) throws -> SignedLicenseClaims
}

public struct Ed25519SignedLicenseTokenVerifier: SignedLicenseTokenVerifying {
    public var publicKeyBase64: String
    public var expectedProductID: String

    public init(publicKeyBase64: String, expectedProductID: String = "stacio") {
        self.publicKeyBase64 = publicKeyBase64
        self.expectedProductID = expectedProductID
    }

    public func verifiedClaims(from token: String) throws -> SignedLicenseClaims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "v1",
              let publicKeyData = Ed25519PublicKeyMaterial.rawRepresentation(from: publicKeyBase64),
              let payloadData = Data(productOpsBase64URL: String(parts[1])),
              let signatureData = Data(productOpsBase64URL: String(parts[2]))
        else {
            throw ProductOpsError.invalidSignedLicenseToken
        }
        do {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
            guard publicKey.isValidSignature(signatureData, for: Data(parts[1].utf8)) else {
                throw ProductOpsError.invalidSignedLicenseToken
            }
            let claims = try JSONDecoder.productOps.decode(SignedLicenseClaims.self, from: payloadData)
            guard claims.productID == expectedProductID else {
                throw ProductOpsError.licenseClaimsMismatch
            }
            return claims
        } catch let error as ProductOpsError {
            throw error
        } catch {
            throw ProductOpsError.invalidSignedLicenseToken
        }
    }
}

private enum Ed25519PublicKeyMaterial {
    private static let subjectPublicKeyInfoPrefix = Data([
        0x30, 0x2A,
        0x30, 0x05,
        0x06, 0x03, 0x2B, 0x65, 0x70,
        0x03, 0x21, 0x00
    ])

    static func rawRepresentation(from configuredBase64: String) -> Data? {
        let value = configuredBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else {
            return nil
        }
        if value.contains("-----BEGIN PUBLIC KEY-----") {
            return rawRepresentation(fromPEM: value)
        }
        guard let decoded = Data(base64Encoded: value) else {
            return nil
        }
        if decoded.count == 32 {
            return decoded
        }
        if let pem = String(data: decoded, encoding: .utf8),
           pem.contains("-----BEGIN PUBLIC KEY-----") {
            return rawRepresentation(fromPEM: pem)
        }
        return rawRepresentation(fromSubjectPublicKeyInfo: decoded)
    }

    private static func rawRepresentation(fromPEM pem: String) -> Data? {
        let body = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let der = Data(base64Encoded: body) else {
            return nil
        }
        return rawRepresentation(fromSubjectPublicKeyInfo: der)
    }

    private static func rawRepresentation(fromSubjectPublicKeyInfo der: Data) -> Data? {
        guard der.count == subjectPublicKeyInfoPrefix.count + 32,
              der.prefix(subjectPublicKeyInfoPrefix.count) == subjectPublicKeyInfoPrefix
        else {
            return nil
        }
        return Data(der.suffix(32))
    }
}

private extension Data {
    init?(productOpsBase64URL value: String) {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: normalized)
    }
}

public struct LicenseValidationRequest: Codable, Equatable {
    public var licenseKey: String
    public var username: String
    public var email: String
    public var appVersion: String
    public var buildNumber: String
    public var anonymousDeviceID: String
    public var deviceIDHash: String

    public init(
        licenseKey: String = "",
        username: String,
        email: String,
        appVersion: String = "",
        buildNumber: String = "",
        anonymousDeviceID: String
    ) {
        self.licenseKey = licenseKey
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.anonymousDeviceID = anonymousDeviceID
        self.deviceIDHash = DeviceIdentifierHasher.hash(anonymousDeviceID)
    }

    enum CodingKeys: String, CodingKey {
        case licenseKey
        case username
        case email
        case appVersion
        case buildNumber
        case machineFingerprintHash
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case deviceIDHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        licenseKey = try container.decode(String.self, forKey: .licenseKey)
        username = try container.decode(String.self, forKey: .username)
        email = try container.decode(String.self, forKey: .email)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        buildNumber = try container.decode(String.self, forKey: .buildNumber)
        if let hash = try container.decodeIfPresent(String.self, forKey: .machineFingerprintHash) {
            deviceIDHash = hash
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            deviceIDHash = try legacy.decode(String.self, forKey: .deviceIDHash)
        }
        anonymousDeviceID = ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(licenseKey, forKey: .licenseKey)
        try container.encode(username, forKey: .username)
        try container.encode(email, forKey: .email)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(buildNumber, forKey: .buildNumber)
        try container.encode(deviceIDHash, forKey: .machineFingerprintHash)
    }
}

public struct LicenseValidationResponse: Codable, Equatable {
    public var username: String
    public var email: String
    public var signedLicenseToken: String
    public var plan: String
    public var permissions: [String]
    public var expiresAt: Date?
    public var offlineGraceUntil: Date?
    public var offlineGraceSeconds: TimeInterval?
    public var status: LicenseStatus

    public init(
        username: String,
        email: String,
        signedLicenseToken: String = "",
        plan: String,
        permissions: [String] = [],
        expiresAt: Date?,
        offlineGraceUntil: Date? = nil,
        offlineGraceSeconds: TimeInterval? = nil,
        status: LicenseStatus
    ) {
        self.username = username
        self.email = email
        self.signedLicenseToken = signedLicenseToken
        self.plan = plan
        self.permissions = permissions
        self.expiresAt = expiresAt
        self.offlineGraceUntil = offlineGraceUntil
        self.offlineGraceSeconds = offlineGraceSeconds
        self.status = status
    }
}

private struct LicenseValidationEnvelope: Decodable {
    var ok: Bool
    var data: LicenseValidationEnvelopeData?
    var error: LicenseValidationEnvelopeError?
}

private struct LicenseValidationEnvelopeData: Decodable {
    var valid: Bool
    var reason: String?
    var status: LicenseStatus?
    var plan: String?
    var entitlements: [String]?
    var expiresAt: Date?
    var offlineGraceSeconds: TimeInterval?
    var signedLicenseToken: String?
}

private struct LicenseValidationEnvelopeError: Decodable {
    var code: String?
    var message: String?
}

public protocol LicenseOnlineValidating: AnyObject {
    func validate(_ requestBody: LicenseValidationRequest) async throws -> LicenseValidationResponse
}

public final class LicenseOnlineValidationService {
    private let configuration: ProductOpsConfiguration
    private let httpClient: ProductOpsHTTPClient

    public init(
        configuration: ProductOpsConfiguration,
        httpClient: ProductOpsHTTPClient = URLSessionProductOpsHTTPClient()
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
    }

    public static func makeRequest(
        configuration: ProductOpsConfiguration,
        requestBody: LicenseValidationRequest
    ) throws -> URLRequest {
        let baseURL = try ProductOpsEndpointPolicy.validatedAPIBaseURL(configuration.apiBaseURL)
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("public")
            .appendingPathComponent("products")
            .appendingPathComponent(configuration.productID)
            .appendingPathComponent("licenses")
            .appendingPathComponent("validate")
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder.productOps.encode(requestBody)
        return request
    }

    public func validate(_ requestBody: LicenseValidationRequest) async throws -> LicenseValidationResponse {
        let request = try Self.makeRequest(configuration: configuration, requestBody: requestBody)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProductOpsError.classify(error)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ProductOpsError.responseError(data: data, response: response)
        }
        if let envelope = try? JSONDecoder.productOps.decode(LicenseValidationEnvelope.self, from: data) {
            guard envelope.ok, let payload = envelope.data else {
                throw ProductOpsError.server(
                    message: envelope.error?.message ?? "License 服务返回无效响应。",
                    requestID: response.value(forHTTPHeaderField: "X-Request-ID")
                )
            }
            if payload.valid == false {
                return LicenseValidationResponse(
                    username: requestBody.username,
                    email: requestBody.email,
                    plan: "",
                    expiresAt: nil,
                    status: payload.status ?? Self.terminalStatus(for: payload.reason)
                )
            }
            return LicenseValidationResponse(
                username: requestBody.username,
                email: requestBody.email,
                signedLicenseToken: payload.signedLicenseToken ?? "",
                plan: payload.plan ?? "",
                permissions: payload.entitlements ?? [],
                expiresAt: payload.expiresAt,
                offlineGraceSeconds: payload.offlineGraceSeconds,
                status: payload.status ?? .invalid
            )
        }
        do {
            return try JSONDecoder.productOps.decode(LicenseValidationResponse.self, from: data)
        } catch {
            throw ProductOpsError.server(
                message: "License 服务返回了无法识别的响应。",
                requestID: response.value(forHTTPHeaderField: "X-Request-ID")
                    ?? response.value(forHTTPHeaderField: "x-request-id")
            )
        }
    }

    private static func terminalStatus(for reason: String?) -> LicenseStatus {
        let normalized = reason?.lowercased() ?? ""
        if normalized.contains("revok") { return .revoked }
        if normalized.contains("suspend") || normalized.contains("pause") { return .suspended }
        if normalized.contains("expir") { return .expired }
        return .invalid
    }
}

extension LicenseOnlineValidationService: LicenseOnlineValidating {}

public final class LicenseService {
    public static let defaultOfflineGracePeriod: TimeInterval = 14 * 24 * 60 * 60

    private let store: LicenseStateStoring
    private let verifier: OfflineLicenseTokenVerifying
    private let signedTokenVerifier: SignedLicenseTokenVerifying
    private let gracePeriod: TimeInterval

    public init(
        store: LicenseStateStoring = LicenseKeychainStore(),
        verifier: OfflineLicenseTokenVerifying = PublicKeyOfflineLicenseTokenVerifier(
            publicKeyBase64: ProductOpsConfigurationStore().load().licensePublicKeyBase64
        ),
        signedTokenVerifier: SignedLicenseTokenVerifying = Ed25519SignedLicenseTokenVerifier(
            publicKeyBase64: ProductOpsConfigurationStore().load().licensePublicKeyBase64,
            expectedProductID: ProductOpsConfigurationStore().load().productID
        ),
        gracePeriod: TimeInterval = LicenseService.defaultOfflineGracePeriod
    ) {
        self.store = store
        self.verifier = verifier
        self.signedTokenVerifier = signedTokenVerifier
        self.gracePeriod = gracePeriod
    }

    public func loadState(now: Date = Date()) -> LicenseState {
        do {
            return try loadStateOrThrow(now: now)
        } catch {
            return LicenseState(status: .invalid)
        }
    }

    public func loadStateOrThrow(now: Date = Date()) throws -> LicenseState {
        let stored = try store.load() ?? LicenseState()
        return evaluate(state: stored, now: now)
    }

    public func evaluate(state: LicenseState, now: Date = Date()) -> LicenseState {
        var evaluated = state
        var verifiedClaims: SignedLicenseClaims?

        if [.revoked, .suspended, .invalid, .expired].contains(state.status) {
            return state
        }

        if let token = state.offlineToken {
            guard verifier.validate(token) else {
                evaluated.status = .invalid
                evaluated.graceUntil = nil
                return evaluated
            }
            guard token.expiresAt > now else {
                evaluated.status = .expired
                evaluated.graceUntil = nil
                return evaluated
            }
            evaluated.username = token.username
            evaluated.email = token.email
            evaluated.plan = token.plan
            evaluated.permissions = token.permissions
            evaluated.signedLicenseToken = token.signedLicenseToken
            evaluated.expiresAt = token.expiresAt
            evaluated.graceUntil = nil
            evaluated.status = .offlineActive
            return evaluated
        }

        if state.signedLicenseToken.isEmpty {
            switch state.status {
            case .inactive, .networkUnavailable:
                return state
            case .active, .trial, .offlineActive, .offlineGrace:
                evaluated.status = .invalid
                evaluated.graceUntil = nil
                return evaluated
            case .expired, .suspended, .revoked, .invalid:
                return state
            }
        } else {
            guard let claims = try? signedTokenVerifier.verifiedClaims(from: state.signedLicenseToken),
                  claims.username.caseInsensitiveCompare(state.username) == .orderedSame,
                  claims.email.caseInsensitiveCompare(state.email) == .orderedSame,
                  claims.plan == state.plan,
                  Set(claims.entitlements) == Set(state.permissions),
                  state.expiresAt.map({ abs($0.timeIntervalSince(claims.expiresAt)) < 1 }) ?? false
            else {
                evaluated.status = .invalid
                evaluated.graceUntil = nil
                return evaluated
            }
            verifiedClaims = claims
            evaluated.graceUntil = min(
                claims.expiresAt,
                claims.issuedAt.addingTimeInterval(max(0, claims.offlineGraceSeconds))
            )
        }

        if state.status == .inactive {
            return evaluated
        }

        if let expiresAt = state.expiresAt, expiresAt <= now {
            evaluated.status = .expired
            evaluated.graceUntil = nil
            return evaluated
        }

        if state.status == .offlineGrace || state.status == .networkUnavailable {
            let effectiveGraceUntil = verifiedClaims.map {
                min(
                    $0.expiresAt,
                    $0.issuedAt.addingTimeInterval(max(0, $0.offlineGraceSeconds))
                )
            } ?? state.lastValidatedAt?.addingTimeInterval(gracePeriod)
            guard let effectiveGraceUntil else {
                evaluated.status = state.status == .networkUnavailable ? .networkUnavailable : .expired
                return evaluated
            }
            evaluated.graceUntil = effectiveGraceUntil
            evaluated.status = now < effectiveGraceUntil ? .offlineGrace : .expired
            if evaluated.status == .expired {
                evaluated.graceUntil = nil
            }
            return evaluated
        }

        if state.status == .offlineActive {
            let effectiveGraceUntil = verifiedClaims.map {
                min(
                    $0.expiresAt,
                    $0.issuedAt.addingTimeInterval(max(0, $0.offlineGraceSeconds))
                )
            } ?? state.lastValidatedAt?.addingTimeInterval(gracePeriod)
            guard let effectiveGraceUntil, now < effectiveGraceUntil else {
                evaluated.status = .expired
                evaluated.graceUntil = nil
                return evaluated
            }
            evaluated.status = .offlineActive
            evaluated.graceUntil = effectiveGraceUntil
            return evaluated
        }

        if let expiresAt = state.expiresAt, expiresAt > now {
            evaluated.status = state.status == .trial ? .trial : .active
            return evaluated
        }

        if state.status == .networkUnavailable {
            evaluated.status = .networkUnavailable
        } else {
            evaluated.status = state.expiresAt == nil ? .inactive : .expired
        }
        return evaluated
    }

    @discardableResult
    public func state(applyingOfflineToken token: OfflineLicenseToken, now: Date = Date()) throws -> LicenseState {
        let state = try validatedOfflineState(token: token, now: now)
        try store.save(state)
        return state
    }

    @discardableResult
    public func state(
        applyingOfflineToken token: OfflineLicenseToken,
        expectedUsername: String,
        expectedEmail: String,
        now: Date = Date()
    ) throws -> LicenseState {
        try validateOfflineIdentity(
            username: token.username,
            email: token.email,
            expectedUsername: expectedUsername,
            expectedEmail: expectedEmail
        )
        let state = try validatedOfflineState(token: token, now: now)
        try store.save(state)
        return state
    }

    @discardableResult
    public func state(
        applyingOfflineToken token: OfflineLicenseToken,
        expectedUsername: String,
        expectedEmail: String,
        activationStore: LicenseActivationRecordStoring,
        now: Date = Date()
    ) throws -> LicenseState {
        try validateOfflineIdentity(
            username: token.username,
            email: token.email,
            expectedUsername: expectedUsername,
            expectedEmail: expectedEmail
        )
        let state = try validatedOfflineState(token: token, now: now)
        try persistOfflineState(state, preservingActivationIn: activationStore)
        return state
    }

    @discardableResult
    public func state(
        applyingOfflineSignedToken signedLicenseToken: String,
        expectedUsername: String,
        expectedEmail: String,
        now: Date = Date()
    ) throws -> LicenseState {
        let state = try validatedOfflineSignedState(
            signedLicenseToken: signedLicenseToken,
            expectedUsername: expectedUsername,
            expectedEmail: expectedEmail,
            now: now
        )
        try store.save(state)
        return evaluate(state: state, now: now)
    }

    @discardableResult
    public func state(
        applyingOfflineSignedToken signedLicenseToken: String,
        expectedUsername: String,
        expectedEmail: String,
        activationStore: LicenseActivationRecordStoring,
        now: Date = Date()
    ) throws -> LicenseState {
        let state = try validatedOfflineSignedState(
            signedLicenseToken: signedLicenseToken,
            expectedUsername: expectedUsername,
            expectedEmail: expectedEmail,
            now: now
        )
        try persistOfflineState(state, preservingActivationIn: activationStore)
        return evaluate(state: state, now: now)
    }

    private func validatedOfflineSignedState(
        signedLicenseToken: String,
        expectedUsername: String,
        expectedEmail: String,
        now: Date
    ) throws -> LicenseState {
        let token = signedLicenseToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.isEmpty == false else {
            throw ProductOpsError.invalidOfflineLicenseToken
        }
        let claims = try signedTokenVerifier.verifiedClaims(from: token)
        let username = expectedUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = expectedEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard username.isEmpty == false,
              email.isEmpty == false,
              claims.username.caseInsensitiveCompare(username) == .orderedSame,
              claims.email.caseInsensitiveCompare(email) == .orderedSame
        else {
            throw ProductOpsError.licenseIdentityMismatch
        }
        let graceUntil = claims.issuedAt.addingTimeInterval(max(0, claims.offlineGraceSeconds))
        guard claims.expiresAt > now,
              graceUntil > now
        else {
            throw ProductOpsError.invalidOfflineLicenseToken
        }
        let state = LicenseState(
            username: claims.username,
            email: claims.email,
            signedLicenseToken: token,
            plan: claims.plan,
            permissions: claims.entitlements,
            expiresAt: claims.expiresAt,
            graceUntil: graceUntil,
            status: .offlineActive,
            lastValidatedAt: nil,
            offlineToken: nil
        )
        return state
    }

    @discardableResult
    public func state(applyingOnlineValidation response: LicenseValidationResponse, now: Date = Date()) throws -> LicenseState {
        let state = try validatedOnlineState(response: response, expected: nil, now: now)
        try saveManualValidationStateIfAppropriate(state, expected: nil, now: now)
        return state
    }

    @discardableResult
    public func state(
        applyingOnlineValidation response: LicenseValidationResponse,
        expected request: LicenseValidationRequest,
        now: Date = Date()
    ) throws -> LicenseState {
        let state = try validatedOnlineState(response: response, expected: request, now: now)
        try saveManualValidationStateIfAppropriate(state, expected: request, now: now)
        return state
    }

    @discardableResult
    public func state(
        applyingOnlineValidation response: LicenseValidationResponse,
        expected request: LicenseValidationRequest,
        activationStore: LicenseActivationRecordStoring,
        now: Date = Date()
    ) throws -> LicenseState {
        let state = try validatedOnlineState(response: response, expected: request, now: now)
        guard state.status == .active || state.status == .trial else {
            try saveManualValidationStateIfAppropriate(
                state,
                expected: request,
                activationStore: activationStore,
                now: now
            )
            return state
        }

        let previousActivation = try activationStore.loadActivationRecord()
        try activationStore.saveActivationRecord(LicenseActivationRecord(
            licenseKey: request.licenseKey,
            username: request.username,
            email: request.email
        ))
        do {
            try saveManualValidationStateIfAppropriate(
                state,
                expected: request,
                activationStore: activationStore,
                now: now
            )
        } catch {
            try restoreActivationRecord(previousActivation, in: activationStore)
            throw error
        }
        return state
    }

    @discardableResult
    public func state(
        applyingRevalidation response: LicenseValidationResponse,
        expected request: LicenseValidationRequest,
        now: Date = Date()
    ) throws -> LicenseState {
        let state = try validatedOnlineState(response: response, expected: request, now: now)
        try store.save(state)
        return state
    }

    @discardableResult
    public func stateForNetworkUnavailable(now: Date = Date()) throws -> LicenseState {
        guard let stored = try store.load() else {
            let unavailable = LicenseState(status: .networkUnavailable)
            try store.save(unavailable)
            return unavailable
        }
        if [.revoked, .suspended, .invalid, .expired].contains(stored.status) {
            return stored
        }
        if stored.signedLicenseToken.isEmpty, stored.offlineToken == nil {
            var unavailable = stored
            unavailable.status = .networkUnavailable
            try store.save(unavailable)
            return unavailable
        }
        var unavailableCandidate = stored
        unavailableCandidate.status = .networkUnavailable
        let evaluated = evaluate(state: unavailableCandidate, now: now)
        try store.save(evaluated)
        return evaluated
    }

    private func validatedOfflineState(token: OfflineLicenseToken, now: Date) throws -> LicenseState {
        guard verifier.validate(token), token.expiresAt > now else {
            throw ProductOpsError.invalidOfflineLicenseToken
        }
        return LicenseState(
            username: token.username,
            email: token.email,
            signedLicenseToken: token.signedLicenseToken,
            plan: token.plan,
            permissions: token.permissions,
            expiresAt: token.expiresAt,
            graceUntil: nil,
            status: .offlineActive,
            lastValidatedAt: now,
            offlineToken: token
        )
    }

    private func validateOfflineIdentity(
        username: String,
        email: String,
        expectedUsername: String,
        expectedEmail: String
    ) throws {
        let normalizedUsername = expectedUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmail = expectedEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedUsername.isEmpty == false,
              normalizedEmail.isEmpty == false,
              username.caseInsensitiveCompare(normalizedUsername) == .orderedSame,
              email.caseInsensitiveCompare(normalizedEmail) == .orderedSame
        else {
            throw ProductOpsError.licenseIdentityMismatch
        }
    }

    private func persistOfflineState(
        _ state: LicenseState,
        preservingActivationIn activationStore: LicenseActivationRecordStoring
    ) throws {
        _ = activationStore
        do {
            try store.save(state)
        } catch let persistenceError {
            throw persistenceError
        }
    }

    private func restoreActivationRecord(
        _ record: LicenseActivationRecord?,
        in activationStore: LicenseActivationRecordStoring
    ) throws {
        if let record {
            try activationStore.saveActivationRecord(record)
        } else {
            try activationStore.deleteActivationRecord()
        }
    }

    private func saveManualValidationStateIfAppropriate(
        _ state: LicenseState,
        expected request: LicenseValidationRequest?,
        activationStore: LicenseActivationRecordStoring? = nil,
        now: Date
    ) throws {
        let isTerminal = [.revoked, .suspended, .invalid, .expired].contains(state.status)
        if isTerminal,
           let existing = try store.load()
        {
            let evaluatedExisting = evaluate(state: existing, now: now)
            if [.active, .trial, .offlineActive, .offlineGrace].contains(evaluatedExisting.status) {
                guard let request,
                      let resolvedActivationStore = activationStore ?? (store as? LicenseActivationRecordStoring),
                      let activation = try resolvedActivationStore.loadActivationRecord(),
                      activation.licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        == request.licenseKey.trimmingCharacters(in: .whitespacesAndNewlines),
                      activation.username.caseInsensitiveCompare(request.username) == .orderedSame,
                      activation.email.caseInsensitiveCompare(request.email) == .orderedSame
                else {
                    return
                }
            }
        }
        try store.save(state)
    }

    private func validatedOnlineState(
        response: LicenseValidationResponse,
        expected request: LicenseValidationRequest?,
        now: Date
    ) throws -> LicenseState {
        if let request {
            guard response.username.caseInsensitiveCompare(request.username) == .orderedSame,
                  response.email.caseInsensitiveCompare(request.email) == .orderedSame
            else {
                throw ProductOpsError.licenseIdentityMismatch
            }
        }

        if [.revoked, .suspended, .invalid, .expired].contains(response.status) {
            return LicenseState(
                username: response.username,
                email: response.email,
                plan: response.plan,
                permissions: [],
                expiresAt: response.expiresAt,
                graceUntil: nil,
                status: response.status,
                lastValidatedAt: now,
                offlineToken: nil
            )
        }

        guard response.status == .active || response.status == .trial else {
            throw ProductOpsError.licenseClaimsMismatch
        }
        let claims = try signedTokenVerifier.verifiedClaims(from: response.signedLicenseToken)
        let expectedUsername = request?.username ?? response.username
        let expectedEmail = request?.email ?? response.email
        guard claims.username.caseInsensitiveCompare(expectedUsername) == .orderedSame,
              claims.email.caseInsensitiveCompare(expectedEmail) == .orderedSame,
              claims.plan == response.plan,
              Set(claims.entitlements) == Set(response.permissions),
              response.expiresAt.map({ abs($0.timeIntervalSince(claims.expiresAt)) < 1 }) ?? false,
              response.offlineGraceSeconds.map({ abs($0 - claims.offlineGraceSeconds) < 1 }) ?? true,
              claims.expiresAt > now
        else {
            throw ProductOpsError.licenseClaimsMismatch
        }
        let graceUntil = claims.issuedAt.addingTimeInterval(max(0, claims.offlineGraceSeconds))
        return LicenseState(
            username: claims.username,
            email: claims.email,
            signedLicenseToken: response.signedLicenseToken,
            plan: claims.plan,
            permissions: claims.entitlements,
            expiresAt: claims.expiresAt,
            graceUntil: graceUntil,
            status: response.status,
            lastValidatedAt: now,
            offlineToken: nil
        )
    }
}
