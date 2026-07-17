import AppKit
import Sparkle

@MainActor
protocol WorkbenchWindowShowing: AnyObject {
    func showWindow(_ sender: Any?)
    func openSavedSession(id: String)
    func toggleDeviceDashboardFromMenu(_ sender: Any?)
    func prepareForApplicationTermination() -> Bool
}

extension WorkbenchWindowController: WorkbenchWindowShowing {
    func prepareForApplicationTermination() -> Bool {
        workspaceViewController.closeAllTerminals()
    }
}

@MainActor
public protocol RunningTunnelReporting {
    var runningTunnelCount: Int { get }
}

public enum StacioAppMetadata {
    public static let applicationName = "Stacio"
    public static let bundleIdentifier = "com.stacio.Stacio"
    private static let fallbackDisplayVersion = "Stacio-0.13.3"
    public static var displayVersion: String { displayVersion(in: .main) }
    public static let websiteURL = "https://www.stacio.cn/"
    public static let repositoryURL = "https://github.com/Fengoffer/Stacio"
    public static let giteeRepositoryURL = "https://gitee.com/fengoffer/Stacio"
    public static let supportedURLSchemes = Set(["stacio", "stacio"])

    public static func displayVersion(in bundle: Bundle) -> String {
        guard bundle.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String == bundleIdentifier,
              let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return fallbackDisplayVersion
        }
        let trimmed = shortVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackDisplayVersion : "Stacio-\(trimmed)"
    }
}

@MainActor
public protocol AboutPanelPresenting: AnyObject {
    func showAboutPanel(content: StacioAboutContent)
}

@MainActor
public protocol RunningTunnelTerminationConfirming {
    func confirmTerminationWithRunningTunnels(count: Int, parentWindow: NSWindow?) -> Bool
}

@MainActor
public protocol SparkleUpdateChecking: AnyObject {
    func checkForUpdates(_ sender: Any?)
    func checkForUpdateInformation(_ sender: Any?)
    func checkForUpdateInformation(
        _ sender: Any?,
        statusHandler: @escaping (SparkleManualUpdateCheckState) -> Void
    )
}

public extension SparkleUpdateChecking {
    func checkForUpdateInformation(_ sender: Any?) {
        checkForUpdates(sender)
    }

    func checkForUpdateInformation(
        _ sender: Any?,
        statusHandler: @escaping (SparkleManualUpdateCheckState) -> Void
    ) {
        statusHandler(.checking)
        checkForUpdateInformation(sender)
    }
}

public struct SparkleUpdatePromptInfo: Equatable {
    public var version: String
    public var build: String
    public var releaseNotes: String
    public var packageSize: UInt64?

    public init(
        version: String,
        build: String,
        releaseNotes: String = "",
        packageSize: UInt64? = nil
    ) {
        self.version = version
        self.build = build
        self.releaseNotes = releaseNotes
        self.packageSize = packageSize
    }

    public func isNewerThanCurrentVersion(_ currentVersion: String, build currentBuild: String) -> Bool {
        let update = UpdateInfo(
            version: version,
            build: build,
            channel: .stable,
            releaseNotes: "",
            artifactURL: nil,
            publishedAt: nil,
            minSupportedVersion: nil
        )
        return UpdateVersionComparator.isUpdate(update, newerThanVersion: currentVersion, build: currentBuild)
    }
}

public enum SparkleManualUpdateCheckState: Equatable {
    case checking
    case upToDate
    case available(SparkleUpdatePromptInfo)
    case failed(String)
}

public enum SparkleUpdateCheckOrigin: Equatable {
    case launch
    case manual
}

public final class SparkleUpdateSuppressionStore {
    public static let defaultsKey = "Stacio.ProductOps.updateSuppression"

    private enum Kind: String, Codable {
        case skipped
        case remindLater
    }

    private struct Payload: Codable {
        var version: String
        var build: String
        var kind: Kind
        var remindAfter: Date?
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func skip(_ update: SparkleUpdatePromptInfo) {
        save(Payload(
            version: update.version,
            build: update.build,
            kind: .skipped,
            remindAfter: nil
        ))
    }

    public func remindLater(_ update: SparkleUpdatePromptInfo, until: Date) {
        save(Payload(
            version: update.version,
            build: update.build,
            kind: .remindLater,
            remindAfter: until
        ))
    }

    public func clearSuppression(for update: SparkleUpdatePromptInfo) {
        guard let payload = load(), matches(payload, update) else {
            return
        }
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    public func shouldSuppress(
        _ update: SparkleUpdatePromptInfo,
        origin: SparkleUpdateCheckOrigin,
        now: Date
    ) -> Bool {
        guard origin == .launch,
              let payload = load(),
              matches(payload, update)
        else {
            return false
        }
        switch payload.kind {
        case .skipped:
            return true
        case .remindLater:
            guard let remindAfter = payload.remindAfter,
                  remindAfter > now else {
                defaults.removeObject(forKey: Self.defaultsKey)
                return false
            }
            return true
        }
    }

    private func save(_ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload) else {
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private func load() -> Payload? {
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private func matches(_ payload: Payload, _ update: SparkleUpdatePromptInfo) -> Bool {
        payload.version == update.version && payload.build == update.build
    }
}

public enum SparkleUpdateButtonState: Equatable {
    case hidden
    case available(SparkleUpdatePromptInfo)
    case downloading(progress: Double?)
    case extracting(progress: Double?)
    case installing
    case failed(String)

    public var isVisible: Bool {
        switch self {
        case .hidden:
            return false
        case .available, .downloading, .extracting, .installing, .failed:
            return true
        }
    }

    public var title: String {
        switch self {
        case .hidden:
            return ""
        case .available:
            return "更新"
        case .downloading(let progress):
            return "正在下载\(Self.percentSuffix(progress))"
        case .extracting(let progress):
            return "正在解压\(Self.percentSuffix(progress))"
        case .installing:
            return "正在安装"
        case .failed:
            return "更新失败"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .hidden:
            return "无可用更新"
        case .available(let info):
            return "发现 Stacio 更新 \(info.version) Build \(info.build)"
        case .downloading(let progress):
            return "正在下载 Stacio 更新\(Self.percentSuffix(progress))"
        case .extracting(let progress):
            return "正在解压 Stacio 更新\(Self.percentSuffix(progress))"
        case .installing:
            return "正在安装 Stacio 更新"
        case .failed(let message):
            return "Stacio 更新失败：\(message)"
        }
    }

    private static func percentSuffix(_ progress: Double?) -> String {
        guard let progress else {
            return "…"
        }
        let percent = min(100, max(0, Int((progress * 100).rounded())))
        return " \(percent)%"
    }
}

@MainActor
public protocol SparkleUpdateButtonControlling: SparkleUpdateChecking {
    var buttonState: SparkleUpdateButtonState { get }
    var onButtonStateChanged: ((SparkleUpdateButtonState) -> Void)? { get set }

    func probeForAvailableUpdate()
    func installAvailableUpdateFromPrompt()
}

@MainActor
public protocol SparkleUpdateTerminationProtecting: AnyObject {
    func prepareForApplicationTermination() -> Bool
}

@MainActor
public protocol SparkleUpdateActionHandling: AnyObject {
    func downloadUpdate(_ update: SparkleUpdatePromptInfo)
    func remindLater(_ update: SparkleUpdatePromptInfo)
    func skip(_ update: SparkleUpdatePromptInfo)
}

public enum SparkleAvailableUpdateChoice: Equatable {
    case download
    case later
    case skip
}

private enum SparkleUpdateMessage {
    static let informationOnly = "该更新只包含说明，无法在应用内安装。"
    static let emptyAppcast = "Appcast 未包含当前更新通道的可用版本。"
    static let noCompatibleVersion = "Appcast 中没有适用于当前设备的可安装版本。"
    static let systemTooOld = "当前 macOS 版本过低，无法安装可用更新。"
    static let systemTooNew = "当前 macOS 版本过高，无法安装可用更新。"
    static let hardwareUnsupported = "当前 Mac 的硬件架构不支持可用更新。"
    static let installedWithoutRelaunchTitle = "更新已安装"
    static let installedWithoutRelaunchBody = "Stacio 已完成更新，但未能自动重新启动。请手动重新打开应用。"
}

@MainActor
public protocol SparkleUpdateConfirmationPresenting: AnyObject {
    func chooseAvailableUpdate(_ update: SparkleUpdatePromptInfo) -> SparkleAvailableUpdateChoice
    func confirmInstallAndRelaunch(_ update: SparkleUpdatePromptInfo) -> Bool
    func confirmRetryTerminatingApplication() -> Bool
    func showInstallCompletedWithoutRelaunch()
}

@MainActor
public final class AppKitSparkleUpdateConfirmationPresenter: SparkleUpdateConfirmationPresenting {
    public init() {}

    public func chooseAvailableUpdate(_ update: SparkleUpdatePromptInfo) -> SparkleAvailableUpdateChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现 Stacio \(update.version) (Build \(update.build))"
        alert.informativeText = Self.detailsText(update)
        alert.addButton(withTitle: L10n.ProductOps.updateDownload)
        alert.addButton(withTitle: L10n.ProductOps.updateLater)
        alert.addButton(withTitle: L10n.ProductOps.updateSkipVersion)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .download
        case .alertSecondButtonReturn:
            return .later
        default:
            return .skip
        }
    }

    public func confirmInstallAndRelaunch(_ update: SparkleUpdatePromptInfo) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.ProductOps.updateInstallConfirmTitle
        alert.informativeText = L10n.ProductOps.updateInstallConfirmMessage(
            version: update.version,
            build: update.build
        )
        alert.addButton(withTitle: L10n.ProductOps.updateInstallAndRelaunch)
        alert.addButton(withTitle: L10n.ProductOps.updateLater)
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func confirmRetryTerminatingApplication() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.ProductOps.updateTerminationRetryTitle
        alert.informativeText = L10n.ProductOps.updateTerminationRetryMessage
        alert.addButton(withTitle: L10n.ProductOps.updateTerminationRetry)
        alert.addButton(withTitle: L10n.ProductOps.updateLater)
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func showInstallCompletedWithoutRelaunch() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = SparkleUpdateMessage.installedWithoutRelaunchTitle
        alert.informativeText = SparkleUpdateMessage.installedWithoutRelaunchBody
        alert.addButton(withTitle: L10n.Common.ok)
        alert.runModal()
    }

    private static func detailsText(_ update: SparkleUpdatePromptInfo) -> String {
        var lines: [String] = []
        if let packageSize = update.packageSize {
            let clampedSize = Int64(min(packageSize, UInt64(Int64.max)))
            lines.append("安装包大小：\(ByteCountFormatter.string(fromByteCount: clampedSize, countStyle: .file))")
        }
        let notes = update.releaseNotes.isEmpty
            ? L10n.ProductOps.updateReleaseNotesUnavailable
            : update.releaseNotes.stacioPlainReleaseNotesForDisplay()
        lines.append(notes)
        return lines.joined(separator: "\n\n")
    }
}

@MainActor
protocol SparkleUpdaterDriving: AnyObject {
    var sessionInProgress: Bool { get }
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var sendsSystemProfile: Bool { get set }

    func start() throws
    func checkForUpdateInformation()
    func checkForUpdates()
}

extension SPUUpdater: SparkleUpdaterDriving {}

typealias SparkleUpdaterFactory = (
    _ bundle: Bundle,
    _ userDriver: StacioSparkleUserDriver,
    _ delegate: SparkleUpdateController
) -> any SparkleUpdaterDriving

public struct InstalledUpdateReleaseNotesPayload: Codable, Equatable {
    public var version: String
    public var build: String
    public var releaseNotes: String

    public init(version: String, build: String, releaseNotes: String) {
        self.version = version
        self.build = build
        self.releaseNotes = releaseNotes
    }
}

public final class InstalledUpdateReleaseNotesStore {
    public static let defaultsKey = "Stacio.ProductOps.pendingInstalledUpdateReleaseNotes"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func savePendingNotes(version: String, build: String, releaseNotes: String) {
        let trimmedNotes = releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedNotes.isEmpty == false else {
            return
        }
        let payload = InstalledUpdateReleaseNotesPayload(
            version: version,
            build: build,
            releaseNotes: trimmedNotes
        )
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    public func pendingNotesMatchingCurrentBundle(bundle: Bundle = .main) -> InstalledUpdateReleaseNotesPayload? {
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return pendingNotesMatching(version: shortVersion, build: build)
    }

    public func pendingNotesMatching(version shortVersion: String?, build: String?) -> InstalledUpdateReleaseNotesPayload? {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let payload = try? JSONDecoder().decode(InstalledUpdateReleaseNotesPayload.self, from: data)
        else {
            return nil
        }
        guard payload.version == shortVersion, payload.build == build else {
            return nil
        }
        return payload
    }

    public func markPresented() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    public func clearPendingNotes() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

@MainActor
public protocol InstalledUpdateReleaseNotesPresenting: AnyObject {
    func showInstalledUpdateReleaseNotes(version: String, releaseNotes: String)
}

@MainActor
public final class AppKitInstalledUpdateReleaseNotesPresenter: InstalledUpdateReleaseNotesPresenting {
    public init() {}

    public func showInstalledUpdateReleaseNotes(version: String, releaseNotes: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Stacio 已更新到 \(version)"
        alert.informativeText = releaseNotes.stacioPlainReleaseNotesForDisplay()
        alert.addButton(withTitle: L10n.Common.ok)
        alert.runModal()
    }
}

extension String {
    func stacioPlainReleaseNotesForDisplay() -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "<[^>]+>", options: .regularExpression) != nil,
              let data = trimmed.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              )
        else {
            return trimmed
        }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class StacioSparkleUserDriver: NSObject, SPUUserDriver {
    weak var controller: SparkleUpdateController?

    private var expectedDownloadLength: UInt64 = 0
    private var downloadedLength: UInt64 = 0

    init(controller: SparkleUpdateController? = nil) {
        self.controller = controller
        super.init()
    }

    func resetProgress() {
        expectedDownloadLength = 0
        downloadedLength = 0
    }

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: false,
            automaticUpdateDownloading: NSNumber(value: false),
            sendSystemProfile: false
        ))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        controller?.handleUserInitiatedUpdateCheckStarted()
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        controller?.preparePendingInstalledReleaseNotes(from: appcastItem)
        guard appcastItem.isInformationOnlyUpdate == false else {
            reply(controller?.handleInformationOnlyUpdate() ?? .dismiss)
            return
        }
        guard let controller else {
            reply(.dismiss)
            return
        }
        let update = controller.promptInfo(from: appcastItem)
        reply(controller.resolveAvailableUpdateChoice(update, state: state))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        controller?.cachePendingInstalledReleaseNotes(from: downloadData)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        controller?.cacheReleaseNotesFallbackAfterDownloadFailure()
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        controller?.handleNoUpdateAvailable(error: error)
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        controller?.handleUpdaterError(error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        resetProgress()
        controller?.publish(.downloading(progress: nil))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedDownloadLength = expectedContentLength
        controller?.publish(.downloading(progress: downloadProgress))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        downloadedLength += length
        controller?.publish(.downloading(progress: downloadProgress))
    }

    func showDownloadDidStartExtractingUpdate() {
        controller?.publish(.extracting(progress: nil))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        controller?.publish(.extracting(progress: progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let controller,
              controller.confirmInstallAndRelaunch() else {
            reply(.skip)
            return
        }
        controller.publish(.installing)
        reply(.install)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        controller?.handleInstallingUpdate(
            applicationTerminated: applicationTerminated,
            retryTerminatingApplication: retryTerminatingApplication
        )
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        controller?.handleUpdateInstalledAndRelaunched(relaunched)
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        resetProgress()
        // Sparkle invokes this on successful completion too; committed notes must survive relaunch.
    }

    private var downloadProgress: Double? {
        guard expectedDownloadLength > 0 else {
            return nil
        }
        return min(1, max(0, Double(downloadedLength) / Double(expectedDownloadLength)))
    }
}

@MainActor
public final class SparkleUpdateController: NSObject, SparkleUpdateButtonControlling, SparkleUpdateActionHandling, SparkleUpdateTerminationProtecting, SPUUpdaterDelegate {
    public static let shared = SparkleUpdateController()

    private let configurationStore: ProductOpsConfigurationStore
    private let releaseNotesStore: InstalledUpdateReleaseNotesStore
    private let suppressionStore: SparkleUpdateSuppressionStore
    private let confirmationPresenter: SparkleUpdateConfirmationPresenting
    private let nowProvider: () -> Date
    private let bundle: Bundle
    private let updaterFactory: SparkleUpdaterFactory
    private lazy var userDriver = StacioSparkleUserDriver(controller: self)
    private lazy var updater: any SparkleUpdaterDriving = updaterFactory(bundle, userDriver, self)
    private var hasStartedUpdater = false
    private var hasPerformedLaunchUpdateProbe = false
    private var activeUpdateCheck: ActiveUpdateCheck = .none
    private var pendingReleaseNotesItem: SUAppcastItem?
    private var pendingReleaseNotesText: String?
    private var hasCommittedPendingReleaseNotes = false
    private var manualStatusHandler: ((SparkleManualUpdateCheckState) -> Void)?
    private var latestUpdateInfo: SparkleUpdatePromptInfo?
    private var preconfirmedDownloadInfo: SparkleUpdatePromptInfo?
    private var pendingManualDiscoveredUpdate: SparkleUpdatePromptInfo?
    private var pendingInformationOnlyPromptDismissal = false
    private var pendingTerminationRetry: (() -> Void)?
    private var lastUpdaterStartError: Error?

    public private(set) var buttonState: SparkleUpdateButtonState = .hidden
    public var onButtonStateChanged: ((SparkleUpdateButtonState) -> Void)?

    public init(
        configurationStore: ProductOpsConfigurationStore = ProductOpsConfigurationStore(),
        releaseNotesStore: InstalledUpdateReleaseNotesStore = InstalledUpdateReleaseNotesStore(),
        suppressionStore: SparkleUpdateSuppressionStore = SparkleUpdateSuppressionStore(),
        confirmationPresenter: SparkleUpdateConfirmationPresenting? = nil,
        nowProvider: @escaping () -> Date = Date.init,
        bundle: Bundle = .main
    ) {
        self.configurationStore = configurationStore
        self.releaseNotesStore = releaseNotesStore
        self.suppressionStore = suppressionStore
        self.confirmationPresenter = confirmationPresenter ?? AppKitSparkleUpdateConfirmationPresenter()
        self.nowProvider = nowProvider
        self.bundle = bundle
        self.updaterFactory = { bundle, userDriver, delegate in
            SPUUpdater(
                hostBundle: bundle,
                applicationBundle: bundle,
                userDriver: userDriver,
                delegate: delegate
            )
        }
        super.init()
    }

    init(
        configurationStore: ProductOpsConfigurationStore,
        releaseNotesStore: InstalledUpdateReleaseNotesStore,
        bundle: Bundle = .main,
        updaterFactory: @escaping SparkleUpdaterFactory,
        suppressionStore: SparkleUpdateSuppressionStore = SparkleUpdateSuppressionStore(),
        confirmationPresenter: SparkleUpdateConfirmationPresenting? = nil,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.configurationStore = configurationStore
        self.releaseNotesStore = releaseNotesStore
        self.suppressionStore = suppressionStore
        self.confirmationPresenter = confirmationPresenter ?? AppKitSparkleUpdateConfirmationPresenter()
        self.nowProvider = nowProvider
        self.bundle = bundle
        self.updaterFactory = updaterFactory
        super.init()
    }

    public func checkForUpdates(_ sender: Any?) {
        checkForUpdateInformation(sender)
    }

    public func checkForUpdateInformation(_ sender: Any?) {
        beginManualUpdateCheck(statusHandler: nil)
    }

    public func checkForUpdateInformation(
        _ sender: Any?,
        statusHandler: @escaping (SparkleManualUpdateCheckState) -> Void
    ) {
        beginManualUpdateCheck(statusHandler: statusHandler)
    }

    private func beginManualUpdateCheck(
        statusHandler: ((SparkleManualUpdateCheckState) -> Void)?
    ) {
        statusHandler?(.checking)
        guard canBeginUpdateCheck(showErrors: false) else {
            if let lastUpdaterStartError {
                statusHandler?(.failed(lastUpdaterStartError.localizedDescription))
            } else {
                statusHandler?(.failed("更新检查正在进行，请稍后重试。"))
            }
            return
        }
        pendingManualDiscoveredUpdate = nil
        pendingInformationOnlyPromptDismissal = false
        manualStatusHandler = statusHandler
        activeUpdateCheck = .manualProbe
        updater.checkForUpdates()
    }

    public func probeForAvailableUpdate() {
        guard hasPerformedLaunchUpdateProbe == false else {
            return
        }
        guard canBeginUpdateCheck(showErrors: false) else {
            return
        }
        hasPerformedLaunchUpdateProbe = true
        activeUpdateCheck = .launchProbe
        updater.checkForUpdateInformation()
    }

    public func installAvailableUpdateFromPrompt() {
        _ = beginInstallAvailableUpdateFromPrompt()
    }

    @discardableResult
    private func beginInstallAvailableUpdateFromPrompt() -> Bool {
        if let retryTerminatingApplication = pendingTerminationRetry {
            guard confirmationPresenter.confirmRetryTerminatingApplication() else {
                publish(.failed(L10n.ProductOps.updateTerminationPaused))
                return false
            }
            pendingTerminationRetry = nil
            activeUpdateCheck = .manualInstall
            publish(.installing)
            retryTerminatingApplication()
            return true
        }
        guard canBeginUpdateCheck(showErrors: true) else {
            return false
        }
        pendingManualDiscoveredUpdate = nil
        pendingInformationOnlyPromptDismissal = false
        activeUpdateCheck = .manualInstall
        userDriver.resetProgress()
        publish(.downloading(progress: nil))
        updater.checkForUpdates()
        return true
    }

    public func downloadUpdate(_ update: SparkleUpdatePromptInfo) {
        suppressionStore.clearSuppression(for: update)
        latestUpdateInfo = update
        preconfirmedDownloadInfo = update
        if beginInstallAvailableUpdateFromPrompt() == false {
            preconfirmedDownloadInfo = nil
        }
    }

    public func remindLater(_ update: SparkleUpdatePromptInfo) {
        suppressionStore.remindLater(
            update,
            until: nowProvider().addingTimeInterval(Self.remindLaterInterval)
        )
        latestUpdateInfo = update
        publish(.hidden)
    }

    public func skip(_ update: SparkleUpdatePromptInfo) {
        suppressionStore.skip(update)
        latestUpdateInfo = update
        publish(.hidden)
    }

    func publish(_ state: SparkleUpdateButtonState) {
        buttonState = state
        onButtonStateChanged?(state)
    }

    fileprivate func handleUserInitiatedUpdateCheckStarted() {
        if activeUpdateCheck == .manualProbe {
            publish(.hidden)
        } else {
            publish(.downloading(progress: nil))
        }
    }

    public func prepareForApplicationTermination() -> Bool {
        switch buttonState {
        case .downloading, .extracting:
            return false
        case .hidden, .available, .installing, .failed:
            return true
        }
    }

    fileprivate func preparePendingInstalledReleaseNotes(from item: SUAppcastItem) {
        pendingReleaseNotesItem = item
        pendingReleaseNotesText = item.itemDescription
        hasCommittedPendingReleaseNotes = false
    }

    fileprivate func cachePendingInstalledReleaseNotes(from downloadData: SPUDownloadData) {
        guard pendingReleaseNotesItem != nil,
              let releaseNotes = String(data: downloadData.data, encoding: .utf8) else {
            return
        }
        pendingReleaseNotesText = releaseNotes
    }

    fileprivate func cacheReleaseNotesFallbackAfterDownloadFailure() {
        guard pendingReleaseNotesText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            return
        }
        pendingReleaseNotesText = L10n.ProductOps.updateReleaseNotesUnavailable
    }

    fileprivate func commitPendingInstalledReleaseNotes(from item: SUAppcastItem) {
        let releaseNotes = [pendingReleaseNotesText, item.itemDescription]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.isEmpty == false }
            ?? L10n.ProductOps.updateReleaseNotesUnavailable
        pendingReleaseNotesItem = item
        releaseNotesStore.savePendingNotes(
            version: item.displayVersionString,
            build: item.versionString,
            releaseNotes: releaseNotes
        )
        hasCommittedPendingReleaseNotes = true
    }

    fileprivate func promptInfo(from item: SUAppcastItem) -> SparkleUpdatePromptInfo {
        SparkleUpdatePromptInfo(
            version: item.displayVersionString,
            build: item.versionString,
            releaseNotes: item.itemDescription ?? pendingReleaseNotesText ?? "",
            packageSize: item.contentLength > 0 ? item.contentLength : nil
        )
    }

    fileprivate func resolveAvailableUpdateChoice(
        _ update: SparkleUpdatePromptInfo,
        state: SPUUserUpdateState
    ) -> SPUUserUpdateChoice {
        resolveAvailableUpdateChoice(update, stage: state.stage)
    }

    func resolveAvailableUpdateChoiceForTesting(
        _ update: SparkleUpdatePromptInfo,
        stage: SPUUserUpdateStage
    ) -> SPUUserUpdateChoice {
        resolveAvailableUpdateChoice(update, stage: stage)
    }

    private func resolveAvailableUpdateChoice(
        _ update: SparkleUpdatePromptInfo,
        stage: SPUUserUpdateStage
    ) -> SPUUserUpdateChoice {
        latestUpdateInfo = update
        if let pendingManualDiscoveredUpdate,
           pendingManualDiscoveredUpdate.version == update.version,
           pendingManualDiscoveredUpdate.build == update.build {
            self.pendingManualDiscoveredUpdate = nil
            discardPendingInstalledReleaseNotes(clearCommittedNotes: false)
            publish(.hidden)
            return .dismiss
        }
        if preconfirmedDownloadInfo == update {
            preconfirmedDownloadInfo = nil
            suppressionStore.clearSuppression(for: update)
            publish(.downloading(progress: stage == .downloaded ? 1 : nil))
            return .install
        }
        switch confirmationPresenter.chooseAvailableUpdate(update) {
        case .download:
            suppressionStore.clearSuppression(for: update)
            publish(.downloading(progress: stage == .downloaded ? 1 : nil))
            return .install
        case .later:
            remindLater(update)
            return .dismiss
        case .skip:
            skip(update)
            return .skip
        }
    }

    fileprivate func confirmInstallAndRelaunch() -> Bool {
        guard let update = latestUpdateInfo else {
            return false
        }
        guard confirmationPresenter.confirmInstallAndRelaunch(update) else {
            remindLater(update)
            return false
        }
        return true
    }

    fileprivate func handleInstallingUpdate(
        applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        guard applicationTerminated == false else {
            pendingTerminationRetry = nil
            publish(.installing)
            return
        }
        guard confirmationPresenter.confirmRetryTerminatingApplication() else {
            pendingTerminationRetry = retryTerminatingApplication
            activeUpdateCheck = .none
            publish(.failed(L10n.ProductOps.updateTerminationPaused))
            return
        }
        pendingTerminationRetry = nil
        publish(.installing)
        retryTerminatingApplication()
    }

    fileprivate func discardPendingInstalledReleaseNotes(clearCommittedNotes: Bool = true) {
        pendingReleaseNotesItem = nil
        pendingReleaseNotesText = nil
        if clearCommittedNotes, hasCommittedPendingReleaseNotes {
            releaseNotesStore.clearPendingNotes()
        }
        hasCommittedPendingReleaseNotes = false
    }

    fileprivate func handleInformationOnlyUpdate() -> SPUUserUpdateChoice {
        discardPendingInstalledReleaseNotes()
        if pendingInformationOnlyPromptDismissal {
            pendingInformationOnlyPromptDismissal = false
            publish(.hidden)
        } else {
            publish(.failed(SparkleUpdateMessage.informationOnly))
        }
        return .dismiss
    }

    func handleInformationOnlyUpdateForTesting() -> SPUUserUpdateChoice {
        handleInformationOnlyUpdate()
    }

    fileprivate func handleNoUpdateAvailable(error: Error) {
        let check = activeUpdateCheck
        guard check != .none else {
            return
        }
        activeUpdateCheck = .none
        pendingManualDiscoveredUpdate = nil
        pendingInformationOnlyPromptDismissal = false
        pendingTerminationRetry = nil
        preconfirmedDownloadInfo = nil
        discardPendingInstalledReleaseNotes(clearCommittedNotes: false)
        let outcome = noUpdateOutcome(from: error)
        switch check {
        case .none:
            break
        case .launchProbe:
            publish(.hidden)
        case .manualProbe:
            publish(.hidden)
            let handler = manualStatusHandler
            manualStatusHandler = nil
            switch outcome {
            case .upToDate:
                handler?(.upToDate)
            case .failed(let message):
                handler?(.failed(message))
            }
        case .manualInstall:
            switch outcome {
            case .upToDate:
                publish(.hidden)
            case .failed(let message):
                publish(.failed(message))
            }
        }
    }

    private func noUpdateOutcome(from error: Error) -> NoUpdateOutcome {
        let nsError = error as NSError
        guard nsError.domain == SUSparkleErrorDomain,
              nsError.code == Self.sparkleNoUpdateErrorCode,
              let reasonNumber = nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber,
              let reason = SPUNoUpdateFoundReason(rawValue: reasonNumber.int32Value)
        else {
            return .failed(error.localizedDescription)
        }
        let hasLatestItem = nsError.userInfo[SPULatestAppcastItemFoundKey] != nil
        switch reason {
        case .onLatestVersion:
            return hasLatestItem ? .upToDate : .failed(SparkleUpdateMessage.emptyAppcast)
        case .onNewerThanLatestVersion:
            return .upToDate
        case .systemIsTooOld:
            return .failed(noUpdateFailureMessage(SparkleUpdateMessage.systemTooOld, error: nsError))
        case .systemIsTooNew:
            return .failed(noUpdateFailureMessage(SparkleUpdateMessage.systemTooNew, error: nsError))
        case .hardwareDoesNotSupportARM64:
            return .failed(noUpdateFailureMessage(SparkleUpdateMessage.hardwareUnsupported, error: nsError))
        case .unknown:
            let message = hasLatestItem
                ? SparkleUpdateMessage.noCompatibleVersion
                : SparkleUpdateMessage.emptyAppcast
            return .failed(noUpdateFailureMessage(message, error: nsError))
        @unknown default:
            return .failed(noUpdateFailureMessage(SparkleUpdateMessage.noCompatibleVersion, error: nsError))
        }
    }

    private func noUpdateFailureMessage(_ message: String, error: NSError) -> String {
        guard let suggestion = error.localizedRecoverySuggestion?.trimmingCharacters(in: .whitespacesAndNewlines),
              suggestion.isEmpty == false else {
            return message
        }
        return "\(message)\n\(suggestion)"
    }

    fileprivate func handleUpdateInstalledAndRelaunched(_ relaunched: Bool) {
        activeUpdateCheck = .none
        pendingManualDiscoveredUpdate = nil
        pendingInformationOnlyPromptDismissal = false
        pendingTerminationRetry = nil
        preconfirmedDownloadInfo = nil
        discardPendingInstalledReleaseNotes(clearCommittedNotes: false)
        if relaunched == false {
            confirmationPresenter.showInstallCompletedWithoutRelaunch()
        }
        publish(.hidden)
    }

    func handleUpdaterError(_ error: Error) {
        let check = activeUpdateCheck
        activeUpdateCheck = .none
        pendingManualDiscoveredUpdate = nil
        pendingInformationOnlyPromptDismissal = false
        pendingTerminationRetry = nil
        switch check {
        case .none:
            if case .failed = buttonState {
                return
            }
            publish(.hidden)
        case .launchProbe:
            publish(.hidden)
        case .manualProbe:
            discardPendingInstalledReleaseNotes(clearCommittedNotes: false)
            publish(.hidden)
            let handler = manualStatusHandler
            manualStatusHandler = nil
            handler?(.failed(error.localizedDescription))
        case .manualInstall:
            preconfirmedDownloadInfo = nil
            discardPendingInstalledReleaseNotes()
            publish(.failed(error.localizedDescription))
        }
    }

    private func startUpdaterIfNeeded(showErrors: Bool) -> Bool {
        lastUpdaterStartError = nil
        if hasStartedUpdater {
            return true
        }
        do {
            try updater.start()
        } catch {
            lastUpdaterStartError = error
            if showErrors {
                publish(.failed(error.localizedDescription))
            } else {
                publish(.hidden)
            }
            return false
        }
        hasStartedUpdater = true
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        return true
    }

    private func canBeginUpdateCheck(showErrors: Bool) -> Bool {
        guard activeUpdateCheck == .none else {
            return false
        }
        guard startUpdaterIfNeeded(showErrors: showErrors) else {
            return false
        }
        // Sparkle owns the active session. A second request must not replace the
        // current check or turn its progress into a generic "unavailable" error.
        guard updater.sessionInProgress == false,
              updater.canCheckForUpdates
        else {
            return false
        }
        return true
    }

    public func feedURLString(for updater: SPUUpdater) -> String? {
        configurationStore.load().effectiveAppcastURL?.absoluteString
    }

    public func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let configuration = configurationStore.load()
        return configuration.effectiveUpdateChannel == .beta ? ["beta"] : []
    }

    public func updater(
        _ updater: SPUUpdater,
        mayPerform updateCheck: SPUUpdateCheck
    ) throws {
        guard updateCheck == .updates || updateCheck == .updateInformation else {
            throw NSError(
                domain: "Stacio.SparkleUpdateController",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Stacio 仅允许前台手动更新和无下载的版本探测。"]
            )
        }
    }

    public func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    public func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        processDiscoveredUpdate(
            promptInfo(from: item),
            isInformationOnly: item.isInformationOnlyUpdate
        )
    }

    func processDiscoveredUpdateForTesting(
        _ promptInfo: SparkleUpdatePromptInfo,
        isInformationOnly: Bool = false
    ) {
        processDiscoveredUpdate(promptInfo, isInformationOnly: isInformationOnly)
    }

    private func processDiscoveredUpdate(
        _ promptInfo: SparkleUpdatePromptInfo,
        isInformationOnly: Bool = false
    ) {
        let check = activeUpdateCheck
        if isInformationOnly {
            activeUpdateCheck = .none
            discardPendingInstalledReleaseNotes(clearCommittedNotes: false)
            switch check {
            case .launchProbe:
                pendingInformationOnlyPromptDismissal = true
                publish(.hidden)
            case .manualProbe:
                pendingInformationOnlyPromptDismissal = true
                let handler = manualStatusHandler
                manualStatusHandler = nil
                handler?(.failed(SparkleUpdateMessage.informationOnly))
                publish(.hidden)
            case .manualInstall, .none:
                _ = handleInformationOnlyUpdate()
            }
            return
        }
        if check == .manualProbe {
            activeUpdateCheck = .none
            pendingManualDiscoveredUpdate = promptInfo
            publish(.hidden)
            let handler = manualStatusHandler
            manualStatusHandler = nil
            if promptInfo.isNewerThanCurrentVersion(currentVersion, build: currentBuild) {
                latestUpdateInfo = promptInfo
                handler?(.available(promptInfo))
            } else {
                handler?(.upToDate)
            }
            return
        }
        guard promptInfo.isNewerThanCurrentVersion(currentVersion, build: currentBuild) else {
            activeUpdateCheck = .none
            publish(.hidden)
            return
        }
        latestUpdateInfo = promptInfo
        guard check != .manualInstall else {
            return
        }
        activeUpdateCheck = .none
        let isSuppressed = suppressionStore.shouldSuppress(
            promptInfo,
            origin: .launch,
            now: nowProvider()
        )
        publish(isSuppressed ? .hidden : .available(promptInfo))
    }

    public func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        handleNoUpdateAvailable(error: error)
    }

    public func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        activeUpdateCheck = .none
        pendingManualDiscoveredUpdate = nil
        pendingInformationOnlyPromptDismissal = false
        pendingTerminationRetry = nil
        preconfirmedDownloadInfo = nil
        discardPendingInstalledReleaseNotes()
        publish(.failed(error.localizedDescription))
    }

    public func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        commitPendingInstalledReleaseNotes(from: item)
        publish(.installing)
    }

    public func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        handleDidFinishUpdateCycle(updateCheck: updateCheck, error: error)
    }

    func finishUpdateCycleForTesting(updateCheck: SPUUpdateCheck, error: Error?) {
        handleDidFinishUpdateCycle(updateCheck: updateCheck, error: error)
    }

    private func handleDidFinishUpdateCycle(updateCheck: SPUUpdateCheck, error: Error?) {
        guard let error else {
            if updateCheck == .updateInformation || updateCheck == .updates {
                activeUpdateCheck = .none
                pendingManualDiscoveredUpdate = nil
                pendingInformationOnlyPromptDismissal = false
                pendingTerminationRetry = nil
                discardPendingInstalledReleaseNotes(clearCommittedNotes: false)
                if updateCheck == .updates {
                    preconfirmedDownloadInfo = nil
                }
            }
            return
        }
        guard updateCheck == .updates else {
            handleUpdaterError(error)
            return
        }
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain {
            if nsError.code == Self.sparkleNoUpdateErrorCode {
                handleNoUpdateAvailable(error: error)
                return
            }
            if nsError.code == Self.sparkleInstallationCanceledErrorCode {
                activeUpdateCheck = .none
                pendingManualDiscoveredUpdate = nil
                pendingInformationOnlyPromptDismissal = false
                pendingTerminationRetry = nil
                preconfirmedDownloadInfo = nil
                discardPendingInstalledReleaseNotes(clearCommittedNotes: false)
                publish(.hidden)
                return
            }
        }
        handleUpdaterError(error)
    }

    private static let sparkleNoUpdateErrorCode = 1001
    private static let sparkleInstallationCanceledErrorCode = 4007
    private static let remindLaterInterval: TimeInterval = 24 * 60 * 60

    private var currentVersion: String {
        if let bundleVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           bundleVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return bundleVersion
        }
        return StacioAppMetadata.displayVersion
            .replacingOccurrences(of: "Stacio-", with: "")
    }

    private var currentBuild: String {
        if let bundleBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           bundleBuild.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return bundleBuild
        }
        return "0"
    }

    private enum ActiveUpdateCheck {
        case none
        case launchProbe
        case manualProbe
        case manualInstall
    }

    private enum NoUpdateOutcome {
        case upToDate
        case failed(String)
    }
}

@MainActor
public struct AppKitRunningTunnelTerminationConfirmation: RunningTunnelTerminationConfirming {
    public init() {}

    public func confirmTerminationWithRunningTunnels(count: Int, parentWindow: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.Tunnels.quitWithRunningTitle
        alert.informativeText = L10n.Tunnels.quitWithRunningMessage(count: count)
        alert.addButton(withTitle: L10n.Tunnels.quitWithRunningConfirm)
        alert.addButton(withTitle: L10n.Common.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let workbenchWindowControllerFactory: () -> WorkbenchWindowShowing
    private let feedbackWindowControllerFactory: () -> FeedbackWindowController
    private let runningTunnelTerminationConfirmation: RunningTunnelTerminationConfirming
    private let sparkleUpdateChecker: SparkleUpdateChecking
    private let installedUpdateReleaseNotesStore: InstalledUpdateReleaseNotesStore
    private let installedUpdateReleaseNotesPresenter: InstalledUpdateReleaseNotesPresenting
    private let licenseRevalidator: LicenseRevalidating?
    private let licenseNetworkMonitor: LicenseNetworkMonitoring?
    private let appLog: StacioLogWriting?
    private var workbenchWindowController: WorkbenchWindowShowing?
    private var settingsWindowController: AppSettingsWindowController?
    private var feedbackWindowController: FeedbackWindowController?
    private var updatePromptWindowController: UpdatePromptWindowController?
    private var licenseWindowController: LicenseWindowController?
    private var agentBridgeServer: AgentBridgeServer?
    private var licenseRevalidationTask: Task<Void, Never>?

    public override init() {
        let updateController = SparkleUpdateController.shared
        let licenseConfiguration = ProductOpsConfigurationStore().load()
        let licenseStore = LicenseKeychainStore()
        let licenseService = LicenseService(store: licenseStore)
        workbenchWindowControllerFactory = {
            WorkbenchWindowController(
                workspaceViewController: WorkspaceViewController(),
                sparkleUpdateController: updateController
            )
        }
        feedbackWindowControllerFactory = {
            let configuration = ProductOpsConfigurationStore().load()
            return FeedbackWindowController(
                configuration: configuration,
                context: FeedbackDiagnosticContext.current(configuration: configuration)
            )
        }
        runningTunnelTerminationConfirmation = AppKitRunningTunnelTerminationConfirmation()
        sparkleUpdateChecker = updateController
        installedUpdateReleaseNotesStore = InstalledUpdateReleaseNotesStore()
        installedUpdateReleaseNotesPresenter = AppKitInstalledUpdateReleaseNotesPresenter()
        licenseRevalidator = LicenseRevalidationCoordinator(
            store: licenseStore,
            service: licenseService,
            onlineValidator: LicenseOnlineValidationService(configuration: licenseConfiguration),
            contextProvider: {
                LicenseRevalidationContext(
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                        ?? StacioAppMetadata.displayVersion,
                    buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev",
                    anonymousDeviceID: AnonymousDeviceIdentifierStore.shared.deviceID()
                )
            }
        )
        licenseNetworkMonitor = NWPathLicenseNetworkMonitor()
        appLog = StacioLogStore.shared
        super.init()
    }

    convenience init(factory: @escaping () -> WorkbenchWindowShowing) {
        self.init(
            factory: factory,
            runningTunnelTerminationConfirmation: AppKitRunningTunnelTerminationConfirmation(),
            appLog: nil
        )
    }

    convenience init(factory: @escaping () -> WorkbenchWindowShowing, appLog: StacioLogWriting?) {
        self.init(
            factory: factory,
            runningTunnelTerminationConfirmation: AppKitRunningTunnelTerminationConfirmation(),
            appLog: appLog
        )
    }

    init(
        factory: @escaping () -> WorkbenchWindowShowing,
        runningTunnelTerminationConfirmation: RunningTunnelTerminationConfirming,
        sparkleUpdateChecker: SparkleUpdateChecking,
        installedUpdateReleaseNotesStore: InstalledUpdateReleaseNotesStore = InstalledUpdateReleaseNotesStore(),
        installedUpdateReleaseNotesPresenter: InstalledUpdateReleaseNotesPresenting? = nil,
        licenseRevalidator: LicenseRevalidating? = nil,
        licenseNetworkMonitor: LicenseNetworkMonitoring? = nil,
        feedbackWindowControllerFactory: (() -> FeedbackWindowController)? = nil,
        appLog: StacioLogWriting? = nil
    ) {
        workbenchWindowControllerFactory = factory
        self.feedbackWindowControllerFactory = feedbackWindowControllerFactory ?? {
            let configuration = ProductOpsConfigurationStore().load()
            return FeedbackWindowController(
                configuration: configuration,
                context: FeedbackDiagnosticContext.current(configuration: configuration)
            )
        }
        self.runningTunnelTerminationConfirmation = runningTunnelTerminationConfirmation
        self.sparkleUpdateChecker = sparkleUpdateChecker
        self.installedUpdateReleaseNotesStore = installedUpdateReleaseNotesStore
        self.installedUpdateReleaseNotesPresenter = installedUpdateReleaseNotesPresenter
            ?? AppKitInstalledUpdateReleaseNotesPresenter()
        self.licenseRevalidator = licenseRevalidator
        self.licenseNetworkMonitor = licenseNetworkMonitor
        self.appLog = appLog
        super.init()
    }

    convenience init(
        factory: @escaping () -> WorkbenchWindowShowing,
        runningTunnelTerminationConfirmation: RunningTunnelTerminationConfirming,
        appLog: StacioLogWriting? = nil
    ) {
        self.init(
            factory: factory,
            runningTunnelTerminationConfirmation: runningTunnelTerminationConfirmation,
            sparkleUpdateChecker: SparkleUpdateController(),
            appLog: appLog
        )
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacyApplicationSupportIfNeeded()
        logApplicationStarted()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        NSApplication.shared.mainMenu = StacioMenuBuilder(target: self).makeMainMenu()
        let controller = workbenchWindowControllerFactory()
        controller.showWindow(self)
        workbenchWindowController = controller
        startAgentBridgeServerIfNeeded()
        NSApplication.shared.activate(ignoringOtherApps: true)
        scheduleWorkbenchVisibilityRepair()
        presentInstalledUpdateReleaseNotesIfNeeded()
        startLicenseRevalidation()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        TransferCompletionNotificationPresenter.dismissAllForApplicationTermination()
        licenseNetworkMonitor?.cancel()
        licenseRevalidationTask?.cancel()
        licenseRevalidationTask = nil
    }

    private func startLicenseRevalidation() {
        guard licenseRevalidator != nil else { return }
        let onNetworkRestored = { [weak self] in
            _ = Task { @MainActor in
                self?.scheduleLicenseRevalidation(afterNetworkRestore: true)
            }
        }
        let onNetworkUnavailable = { [weak self] in
            _ = Task { @MainActor in
                self?.scheduleLicenseNetworkUnavailable()
            }
        }
        if let statusMonitor = licenseNetworkMonitor as? LicenseNetworkStatusMonitoring {
            statusMonitor.start(
                onNetworkRestored: onNetworkRestored,
                onNetworkUnavailable: onNetworkUnavailable
            )
        } else {
            licenseNetworkMonitor?.start(onNetworkRestored: onNetworkRestored)
        }
        scheduleLicenseRevalidation(afterNetworkRestore: false)
    }

    private func scheduleLicenseRevalidation(afterNetworkRestore: Bool) {
        licenseRevalidationTask?.cancel()
        licenseRevalidationTask = Task { @MainActor [weak self] in
            guard let self, let licenseRevalidator else { return }
            do {
                if afterNetworkRestore {
                    _ = try await licenseRevalidator.revalidateAfterNetworkRestore()
                } else {
                    _ = try await licenseRevalidator.revalidateOnLaunch()
                }
            } catch is CancellationError {
                return
            } catch {
                // LicenseService preserves the last verified state for explicit offline failures.
            }
        }
    }

    private func scheduleLicenseNetworkUnavailable() {
        licenseRevalidationTask?.cancel()
        licenseRevalidationTask = Task { @MainActor [weak self] in
            guard let self,
                  let handler = licenseRevalidator as? LicenseNetworkUnavailableHandling
            else { return }
            do {
                _ = try await handler.markNetworkUnavailable()
            } catch is CancellationError {
                return
            } catch {
                // LicenseService keeps terminal states and stores explicit network-unavailable state when possible.
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ensureWorkbenchWindowVisible(sender: self, hasVisibleWindows: flag)
        return true
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let updateTerminationProtection = sparkleUpdateChecker as? SparkleUpdateTerminationProtecting,
           updateTerminationProtection.prepareForApplicationTermination() == false {
            return .terminateCancel
        }
        let runningTunnelCount = (workbenchWindowController as? RunningTunnelReporting)?.runningTunnelCount ?? 0
        if runningTunnelCount > 0 {
            let parentWindow = (workbenchWindowController as? NSWindowController)?.window
            guard runningTunnelTerminationConfirmation.confirmTerminationWithRunningTunnels(
                count: runningTunnelCount,
                parentWindow: parentWindow
            ) else {
                return .terminateCancel
            }
        }

        guard workbenchWindowController?.prepareForApplicationTermination() ?? true else {
            return .terminateCancel
        }
        agentBridgeServer?.stop()
        agentBridgeServer = nil
        return .terminateNow
    }

    @objc
    public func showAboutPanel(_ sender: Any?) {
        showAboutPanel(sender, presenter: StacioAboutWindowPresenter.shared)
    }

    public func showAboutPanel(_ sender: Any?, presenter: AboutPanelPresenting) {
        presenter.showAboutPanel(content: StacioAboutContent.current())
    }

    @objc
    public func showSettingsWindow(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = AppSettingsWindowController()
        }
        settingsWindowController?.showWindow(sender)
        settingsWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    @objc
    public func showFeedbackWindow(_ sender: Any?) {
        if feedbackWindowController == nil
            || (feedbackWindowController?.window?.isVisible != true
                && feedbackWindowController?.shouldReuseAfterClose == false) {
            feedbackWindowController = feedbackWindowControllerFactory()
        }
        feedbackWindowController?.showWindow(sender)
        feedbackWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    @objc
    public func showUpdateCheckWindow(_ sender: Any?) {
        if updatePromptWindowController == nil {
            updatePromptWindowController = UpdatePromptWindowController(
                sparkleChecker: sparkleUpdateChecker,
                actionHandler: sparkleUpdateChecker as? SparkleUpdateActionHandling
            )
        }
        updatePromptWindowController?.showWindow(sender)
        updatePromptWindowController?.window?.makeKeyAndOrderFront(sender)
        updatePromptWindowController?.beginManualCheck(sender)
    }

    public func presentInstalledUpdateReleaseNotesIfNeeded(bundle: Bundle = .main) {
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        presentInstalledUpdateReleaseNotesIfNeeded(currentVersion: shortVersion, build: build)
    }

    public func presentInstalledUpdateReleaseNotesIfNeeded(currentVersion: String?, build: String?) {
        guard let payload = installedUpdateReleaseNotesStore.pendingNotesMatching(
            version: currentVersion,
            build: build
        ) else {
            return
        }
        installedUpdateReleaseNotesPresenter.showInstalledUpdateReleaseNotes(
            version: payload.version,
            releaseNotes: payload.releaseNotes
        )
        installedUpdateReleaseNotesStore.markPresented()
    }

    @objc
    public func showLicenseWindow(_ sender: Any?) {
        if licenseWindowController?.window?.isVisible != true {
            licenseWindowController = LicenseWindowController(configuration: ProductOpsConfigurationStore().load())
        }
        licenseWindowController?.showWindow(sender)
        licenseWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    @objc
    public func openLocalShellFromMenu(_ sender: Any?) {
        _ = try? (workbenchWindowController as? WorkbenchWindowController)?.openLocalShellFromToolbar(sender)
    }

    @objc
    public func quickConnectFromMenu(_ sender: Any?) {
        (workbenchWindowController as? WorkbenchWindowController)?.performQuickConnectFromToolbar(sender)
    }

    @objc
    public func closeCurrentTerminalFromMenu(_ sender: Any?) {
        (workbenchWindowController as? WorkbenchWindowController)?.closeCurrentTerminalFromMenu(sender)
    }

    @objc
    public func copyFromTerminalMenu(_ sender: Any?) {
        (workbenchWindowController as? WorkbenchWindowController)?.workspaceViewController.copyFromCurrentTerminal()
    }

    @objc
    public func pasteIntoTerminalMenu(_ sender: Any?) {
        (workbenchWindowController as? WorkbenchWindowController)?.workspaceViewController.pasteIntoCurrentTerminal()
    }

    @objc
    public func findInTerminalMenu(_ sender: Any?) {
        (workbenchWindowController as? WorkbenchWindowController)?.workspaceViewController.showFindInCurrentTerminal()
    }

    @objc
    public func splitTerminalFromMenu(_ sender: Any?) {
        (workbenchWindowController as? WorkbenchWindowController)?.performMultiExecFromToolbar(sender)
    }

    @objc
    public func toggleDeviceDashboardFromMenu(_ sender: Any?) {
        workbenchWindowController?.toggleDeviceDashboardFromMenu(sender)
    }

    func ensureWorkbenchWindowVisible(sender: Any?, hasVisibleWindows: Bool) {
        guard hasVisibleWindows == false else {
            return
        }
        appLog?.append(
            level: .info,
            category: "App",
            message: "app.window.repair reason=no-visible-workbench-window"
        )
        let controller: WorkbenchWindowShowing
        if let workbenchWindowController {
            controller = workbenchWindowController
        } else {
            controller = workbenchWindowControllerFactory()
            workbenchWindowController = controller
        }
        controller.showWindow(sender)
    }

    @objc
    public func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let rawURL = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: rawURL)
        else {
            return
        }
        openStacioURL(url)
    }

    public func openStacioURLForTesting(_ url: URL) {
        openStacioURL(url)
    }

    private func openStacioURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              StacioAppMetadata.supportedURLSchemes.contains(scheme),
              url.host?.lowercased() == "open-session"
        else {
            return
        }
        let sessionID = String(url.path.dropFirst()).removingPercentEncoding ?? String(url.path.dropFirst())
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        workbenchWindowController?.showWindow(self)
        workbenchWindowController?.openSavedSession(id: sessionID)
    }

    private func startAgentBridgeServerIfNeeded() {
        guard agentBridgeServer == nil,
              let provider = workbenchWindowController as? AgentBridgeHandlerProviding
        else {
            return
        }
        do {
            let server = AgentBridgeServer(
                handler: provider.makeAgentBridgeRequestHandler(),
                socketPath: try StacioPaths.agentBridgeSocketPath().path
            )
            try server.start()
            agentBridgeServer = server
        } catch {
            StacioLogStore.shared.append(
                level: .warning,
                category: "agent.bridge",
                message: RuntimeDiagnosticFormatter.userMessage(for: error)
            )
        }
    }

    private func scheduleWorkbenchVisibilityRepair() {
        for delay in [300, 1_000] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                guard let self else { return }
                let hasVisibleWindows = NSApplication.shared.windows.contains { $0.isVisible }
                self.ensureWorkbenchWindowVisible(sender: self, hasVisibleWindows: hasVisibleWindows)
            }
        }
    }

    private func migrateLegacyApplicationSupportIfNeeded() {
        do {
            try StacioPaths.migrateLegacyApplicationSupportIfNeeded()
        } catch {
            appLog?.append(
                level: .warning,
                category: "App",
                message: "app.support.migration.failed \(RuntimeDiagnosticFormatter.userMessage(for: error))"
            )
        }
    }

    private func logApplicationStarted() {
        let bundle = Bundle.main.bundleURL.path
        let executable = Bundle.main.executableURL?.path ?? ""
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        appLog?.append(
            level: .info,
            category: "App",
            message: [
                "app.started",
                "bundle=\(bundle)",
                "executable=\(executable)",
                "identifier=\(bundleIdentifier)",
                "version=\(StacioAppMetadata.displayVersion)",
                "process=\(processIdentifier)"
            ].joined(separator: " ")
        )
    }
}
