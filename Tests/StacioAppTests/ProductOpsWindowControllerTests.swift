import AppKit
import XCTest
@testable import StacioApp

@MainActor
final class ProductOpsWindowControllerTests: XCTestCase {
    func testFeedbackWindowShowsRequiredFieldsAndVisibleDiagnostics() throws {
        let context = FeedbackDiagnosticContext(
            appVersion: "0.13.1-Beta",
            build: "42",
            osVersion: "macOS 14.5",
            deviceID: "anonymous-device-id",
            diagnostics: ["configuredUpdateChannel": "stable"]
        )
        let controller = FeedbackWindowController(
            configuration: ProductOpsConfiguration(apiBaseURL: URL(string: "https://ops.example.test")),
            context: context,
            submitter: StubFeedbackSubmitting()
        )

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        XCTAssertEqual(controller.window?.title, "反馈")
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Feedback.title") as? NSTextField)
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Feedback.description") as? NSScrollView)
        let contact = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Feedback.contact") as? NSTextField
        )
        XCTAssertEqual(contact.placeholderString, "邮箱，选填")
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Feedback.includeDiagnostics") as? NSButton)
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Feedback.previewDiagnostics") as? NSButton)
        let typePopup = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Feedback.type") as? NSPopUpButton)
        XCTAssertEqual(typePopup.itemTitles, FeedbackType.allCases.map(\.displayName))
        let diagnostics = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Feedback.diagnostics") as? NSTextField
        )
        XCTAssertTrue(diagnostics.stringValue.contains("匿名设备标识：anonymous-device-id"))
        XCTAssertTrue(diagnostics.stringValue.contains("不会包含密码"))
        XCTAssertTrue(diagnostics.stringValue.contains("SSH 配置"))
        let submit = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Feedback.submit") as? NSButton)
        XCTAssertEqual(submit.title, "提交反馈")
    }

    func testFeedbackWindowKeepsDraftWhenSubmissionFails() throws {
        let submitter = StubFeedbackSubmitting(error: ProductOpsError.missingAPIBaseURL)
        let controller = FeedbackWindowController(
            configuration: ProductOpsConfiguration(apiBaseURL: nil),
            context: FeedbackDiagnosticContext(
                appVersion: "0.13.1-Beta",
                build: "42",
                osVersion: "macOS 14.5",
                deviceID: "anonymous-device-id"
            ),
            submitter: submitter
        )

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let title = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Feedback.title") as? NSTextField)
        let contact = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Feedback.contact") as? NSTextField)
        title.stringValue = "Update check failed"
        contact.stringValue = "user@example.com"

        controller.renderSubmissionFailureForTesting("网络不可用")

        XCTAssertEqual(title.stringValue, "Update check failed")
        XCTAssertEqual(contact.stringValue, "user@example.com")
        let status = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Feedback.status") as? NSTextField)
        XCTAssertTrue(status.stringValue.contains("提交失败"))
        XCTAssertFalse((content.firstSubview(withIdentifier: "Stacio.Feedback.copyError") as? NSButton)?.isHidden ?? true)
    }

    func testFeedbackWindowShowsSpecificValidationErrors() throws {
        let submitter = StubFeedbackSubmitting()
        let controller = FeedbackWindowController(
            configuration: ProductOpsConfiguration(apiBaseURL: URL(string: "https://ops.example.test")),
            context: FeedbackDiagnosticContext(
                appVersion: "0.13.2-Beta",
                build: "42",
                osVersion: "macOS 14.5",
                deviceID: "anonymous-device-id"
            ),
            submitter: submitter
        )
        controller.showWindow(nil)
        defer { controller.close() }
        try fillValidFeedbackDraft(in: controller)

        let content = try XCTUnwrap(controller.window?.contentView)
        let title = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Feedback.title") as? NSTextField)
        let contact = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Feedback.contact") as? NSTextField)
        let status = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Feedback.status") as? NSTextField)
        title.stringValue = String(repeating: "a", count: FeedbackReport.maximumTitleLength + 1)
        contact.stringValue = "not-an-email"

        controller.submitCurrentReportForTesting()

        XCTAssertTrue(status.stringValue.contains(FeedbackReportValidationError.titleTooLong.displayName))
        XCTAssertTrue(status.stringValue.contains(FeedbackReportValidationError.invalidContactEmail.displayName))
        XCTAssertTrue(submitter.idempotencyKeys.isEmpty)
    }

    func testFeedbackWindowPreventsConcurrentSubmissionOfSameDraft() async throws {
        let submitter = GatedFeedbackSubmitter()
        let controller = FeedbackWindowController(
            configuration: ProductOpsConfiguration(apiBaseURL: URL(string: "https://ops.example.test")),
            context: FeedbackDiagnosticContext(
                appVersion: "0.13.2-Beta",
                build: "42",
                osVersion: "macOS 14.5",
                deviceID: "anonymous-device-id"
            ),
            submitter: submitter
        )
        controller.showWindow(nil)
        defer { controller.close() }
        try fillValidFeedbackDraft(in: controller)

        controller.submitCurrentReportForTesting()
        controller.submitCurrentReportForTesting()

        let deadline = Date().addingTimeInterval(0.2)
        while await submitter.submissionCount() < 2, Date() < deadline {
            await Task.yield()
        }
        let submissionCount = await submitter.submissionCount()
        await submitter.finishAll()

        XCTAssertEqual(submissionCount, 1)
    }

    func testFeedbackWindowReusesIdempotencyKeyForManualRetryAndPreventsDuplicateAfterSuccess() async throws {
        let firstSubmission = expectation(description: "first submission")
        let secondSubmission = expectation(description: "second submission")
        let submitter = StubFeedbackSubmitting(outcomes: [
            .failure(ProductOpsError.timeout),
            .success(FeedbackSubmissionResult(id: "feedback-1", message: "ok"))
        ])
        submitter.onSubmission = {
            if submitter.idempotencyKeys.count == 1 {
                firstSubmission.fulfill()
            } else if submitter.idempotencyKeys.count == 2 {
                secondSubmission.fulfill()
            }
        }
        let controller = FeedbackWindowController(
            configuration: ProductOpsConfiguration(apiBaseURL: URL(string: "https://ops.example.test")),
            context: FeedbackDiagnosticContext(
                appVersion: "0.13.2",
                build: "17",
                osVersion: "macOS",
                deviceID: "device"
            ),
            submitter: submitter
        )
        controller.showWindow(nil)
        defer { controller.close() }
        try fillValidFeedbackDraft(in: controller)

        controller.submitCurrentReportForTesting()
        await fulfillment(of: [firstSubmission], timeout: 1)
        try await waitForFeedbackState(.failed, in: controller)
        controller.submitCurrentReportForTesting()
        await fulfillment(of: [secondSubmission], timeout: 1)

        XCTAssertEqual(submitter.idempotencyKeys.count, 2)
        XCTAssertEqual(submitter.idempotencyKeys[0], submitter.idempotencyKeys[1])
        let submitButton = try XCTUnwrap(
            controller.window?.contentView?.firstSubview(withIdentifier: "Stacio.Feedback.submit") as? NSButton
        )
        XCTAssertFalse(submitButton.isEnabled)

        controller.submitCurrentReportForTesting()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(submitter.idempotencyKeys.count, 2)
    }

    func testFeedbackWindowGeneratesNewIdempotencyKeyWhenDraftChangesAfterFailure() async throws {
        let firstSubmission = expectation(description: "first changed-draft submission")
        let secondSubmission = expectation(description: "second changed-draft submission")
        let submitter = StubFeedbackSubmitting(outcomes: [
            .failure(ProductOpsError.timeout),
            .failure(ProductOpsError.offline)
        ])
        submitter.onSubmission = {
            if submitter.idempotencyKeys.count == 1 {
                firstSubmission.fulfill()
            } else if submitter.idempotencyKeys.count == 2 {
                secondSubmission.fulfill()
            }
        }
        let controller = FeedbackWindowController(
            configuration: ProductOpsConfiguration(apiBaseURL: URL(string: "https://ops.example.test")),
            context: FeedbackDiagnosticContext(
                appVersion: "0.13.2",
                build: "17",
                osVersion: "macOS",
                deviceID: "device"
            ),
            submitter: submitter
        )
        controller.showWindow(nil)
        defer { controller.close() }
        try fillValidFeedbackDraft(in: controller)

        controller.submitCurrentReportForTesting()
        await fulfillment(of: [firstSubmission], timeout: 1)
        try await waitForFeedbackState(.failed, in: controller)
        let title = try XCTUnwrap(
            controller.window?.contentView?.firstSubview(withIdentifier: "Stacio.Feedback.title") as? NSTextField
        )
        title.stringValue = "Changed feedback title"
        controller.submitCurrentReportForTesting()
        await fulfillment(of: [secondSubmission], timeout: 1)

        XCTAssertEqual(submitter.idempotencyKeys.count, 2)
        XCTAssertNotEqual(submitter.idempotencyKeys[0], submitter.idempotencyKeys[1])
    }

    func testFeedbackWindowReusesIdempotencyKeyAcrossControllerRecreationWithoutPersistingDraft() async throws {
        let defaults = try makeProductOpsWindowDefaults()
        let firstSubmission = expectation(description: "first persisted-key submission")
        let firstSubmitter = StubFeedbackSubmitting(outcomes: [.failure(ProductOpsError.timeout)])
        firstSubmitter.onSubmission = { firstSubmission.fulfill() }
        var firstController: FeedbackWindowController? = FeedbackWindowController(
            configuration: ProductOpsConfiguration(apiBaseURL: URL(string: "https://ops.example.test")),
            context: FeedbackDiagnosticContext(
                appVersion: "0.13.2",
                build: "17",
                osVersion: "macOS",
                deviceID: "device"
            ),
            submitter: firstSubmitter,
            idempotencyStore: FeedbackIdempotencyKeyStore(defaults: defaults)
        )
        firstController?.showWindow(nil)
        try fillValidFeedbackDraft(in: try XCTUnwrap(firstController))
        firstController?.submitCurrentReportForTesting()
        await fulfillment(of: [firstSubmission], timeout: 1)
        try await waitForFeedbackState(.failed, in: try XCTUnwrap(firstController))
        firstController?.close()
        firstController = nil

        let secondSubmission = expectation(description: "second persisted-key submission")
        let secondSubmitter = StubFeedbackSubmitting(outcomes: [.failure(ProductOpsError.offline)])
        secondSubmitter.onSubmission = { secondSubmission.fulfill() }
        let secondController = FeedbackWindowController(
            configuration: ProductOpsConfiguration(apiBaseURL: URL(string: "https://ops.example.test")),
            context: FeedbackDiagnosticContext(
                appVersion: "0.13.2",
                build: "17",
                osVersion: "macOS",
                deviceID: "device"
            ),
            submitter: secondSubmitter,
            idempotencyStore: FeedbackIdempotencyKeyStore(defaults: defaults)
        )
        secondController.showWindow(nil)
        defer { secondController.close() }
        try fillValidFeedbackDraft(in: secondController)
        secondController.submitCurrentReportForTesting()
        await fulfillment(of: [secondSubmission], timeout: 1)

        XCTAssertEqual(firstSubmitter.idempotencyKeys, secondSubmitter.idempotencyKeys)
        let persisted = try XCTUnwrap(defaults.data(forKey: FeedbackIdempotencyKeyStore.defaultsKey))
        let persistedText = try XCTUnwrap(String(data: persisted, encoding: .utf8))
        XCTAssertFalse(persistedText.contains("Connection problem"))
        XCTAssertFalse(persistedText.contains("The connection did not recover."))
    }

    func testUpdatePromptRendersManualStatesWithoutOpeningDownloadURL() throws {
        let opener = StubProductOpsURLOpener()
        let controller = UpdatePromptWindowController(
            configuration: ProductOpsConfiguration(apiBaseURL: URL(string: "https://ops.example.test")),
            checker: StubUpdateChecking(status: .upToDate),
            urlOpener: opener
        )
        let update = UpdateInfo(
            version: "0.14.0",
            build: "50",
            channel: .stable,
            releaseNotes: "反馈、更新检查与 License 基础能力。",
            artifactURL: URL(string: "https://download.example.test/Stacio.dmg"),
            publishedAt: nil,
            minSupportedVersion: nil
        )

        controller.showWindow(nil)
        defer { controller.close() }

        controller.renderStatusForTesting(.updateAvailable(update))
        let content = try XCTUnwrap(controller.window?.contentView)
        let status = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Update.status") as? NSTextField)
        let download = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Update.download") as? NSButton)
        XCTAssertTrue(status.stringValue.contains("发现新版本"))
        XCTAssertFalse(download.isHidden)
        XCTAssertEqual(opener.openedURLs, [])

        controller.renderStatusForTesting(.upToDate)
        XCTAssertTrue(status.stringValue.contains("已是最新"))
        XCTAssertTrue(download.isHidden)

        controller.renderFailureForTesting("网络不可用")
        XCTAssertTrue(status.stringValue.contains("检查失败"))
        XCTAssertTrue(download.isHidden)
    }

    func testSparkleUpdateWindowRendersManualResultsAndFullUpdateDetails() throws {
        let checker = StubSparkleManualUpdateChecker()
        let actions = RecordingSparkleUpdateActions()
        let controller = UpdatePromptWindowController(
            sparkleChecker: checker,
            actionHandler: actions
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        let status = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Update.status") as? NSTextField)
        let details = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Update.details") as? NSTextField)
        let notes = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Update.releaseNotes") as? NSTextView)
        let download = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Update.download") as? NSButton)
        let later = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Update.later") as? NSButton)
        let skip = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Update.skip") as? NSButton)

        controller.renderManualStateForTesting(.checking)
        XCTAssertTrue(status.stringValue.contains("正在检查"))

        controller.renderManualStateForTesting(.upToDate)
        XCTAssertTrue(status.stringValue.contains("已是最新"))

        controller.renderManualStateForTesting(.failed("Appcast 不可用"))
        XCTAssertTrue(status.stringValue.contains("Appcast 不可用"))

        let update = SparkleUpdatePromptInfo(
            version: "0.14.0",
            build: "50",
            releaseNotes: "<p>新增<strong>更新中心</strong>与安装确认。</p>",
            packageSize: 12_000_000
        )
        controller.renderManualStateForTesting(.available(update))

        XCTAssertTrue(status.stringValue.contains("发现新版本"))
        XCTAssertTrue(details.stringValue.contains("0.14.0"))
        XCTAssertTrue(details.stringValue.contains("Build 50"))
        XCTAssertTrue(details.stringValue.contains("12"))
        XCTAssertEqual(notes.string, "新增更新中心与安装确认。")
        XCTAssertFalse(download.isHidden)
        XCTAssertFalse(later.isHidden)
        XCTAssertFalse(skip.isHidden)

        download.performClick(nil)
        later.performClick(nil)
        skip.performClick(nil)

        XCTAssertEqual(actions.downloadedUpdates, [update])
        XCTAssertEqual(actions.remindedLaterUpdates, [update])
        XCTAssertEqual(actions.skippedUpdates, [update])
    }

    func testLicenseWindowShowsOfflineGraceStateAndTokenInput() throws {
        let now = ISO8601DateFormatter().date(from: "2026-07-10T12:00:00Z")!
        let state = LicenseState(
            username: "Ada",
            email: "ada@example.com",
            signedLicenseToken: "signed-token",
            plan: "team",
            expiresAt: ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z"),
            graceUntil: ISO8601DateFormatter().date(from: "2026-07-12T12:00:00Z"),
            status: .offlineGrace,
            lastValidatedAt: ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z"),
            offlineToken: nil
        )
        let controller = LicenseWindowController(
            service: LicenseService(
                store: InMemoryProductOpsLicenseStateStore(state: state),
                verifier: StubProductOpsOfflineLicenseTokenVerifier(isValid: false),
                signedTokenVerifier: StubProductOpsSignedLicenseTokenVerifier(claims: SignedLicenseClaims(
                    licenseID: "license-1",
                    productID: "stacio",
                    email: state.email,
                    username: state.username,
                    plan: state.plan,
                    entitlements: state.permissions,
                    expiresAt: state.expiresAt!,
                    offlineGraceSeconds: 14 * 24 * 60 * 60,
                    issuedAt: state.lastValidatedAt!
                ))
            ),
            nowProvider: { now }
        )

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let status = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.License.status") as? NSTextField)
        XCTAssertTrue(status.stringValue.contains("离线宽限期"))
        XCTAssertTrue(status.stringValue.contains("Ada"))
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.License.username") as? NSTextField)
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.License.email") as? NSTextField)
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.License.licenseKey") as? NSSecureTextField)
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.License.offlineToken") as? NSScrollView)
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.License.applyOfflineToken") as? NSButton)
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.License.importOfflineLicenseFile") as? NSButton)
    }

    func testLicenseWindowImportsOfflineLicenseFileDataAndValidatesIdentity() throws {
        let now = ISO8601DateFormatter().date(from: "2026-07-10T12:00:00Z")!
        let store = InMemoryProductOpsLicenseStateStore()
        let controller = LicenseWindowController(
            service: LicenseService(
                store: store,
                verifier: StubProductOpsOfflineLicenseTokenVerifier(isValid: true)
            ),
            nowProvider: { now }
        )

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let username = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.License.username") as? NSTextField)
        let email = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.License.email") as? NSTextField)
        username.stringValue = "Ada"
        email.stringValue = "ada@example.com"
        let token = OfflineLicenseToken(
            productID: "stacio",
            username: "Ada",
            email: "ada@example.com",
            plan: "team",
            issuedAt: now,
            expiresAt: ISO8601DateFormatter().date(from: "2026-08-10T12:00:00Z")!,
            signatureKeyID: "primary",
            signature: "signature"
        )

        controller.importOfflineLicenseFileForTesting(try JSONEncoder.productOps.encode(token))

        XCTAssertEqual(store.state?.status, .offlineActive)
        XCTAssertEqual(store.state?.username, "Ada")
        let status = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.License.actionStatus") as? NSTextField)
        XCTAssertTrue(status.stringValue.contains("离线授权已应用"))
    }

    func testLicenseWindowImportsBackendSignedOfflineLicenseFile() throws {
        let now = ISO8601DateFormatter().date(from: "2026-07-10T12:00:00Z")!
        let claims = SignedLicenseClaims(
            licenseID: "license-1",
            productID: "stacio",
            email: "ada@example.com",
            username: "Ada",
            plan: "team",
            entitlements: ["remote_sessions"],
            expiresAt: ISO8601DateFormatter().date(from: "2026-08-10T12:00:00Z")!,
            offlineGraceSeconds: 1_209_600,
            issuedAt: now
        )
        let store = InMemoryProductOpsLicenseStateStore()
        let controller = LicenseWindowController(
            service: LicenseService(
                store: store,
                signedTokenVerifier: StubProductOpsSignedLicenseTokenVerifier(claims: claims)
            ),
            nowProvider: { now }
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let username = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.username") as? NSTextField
        )
        let email = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.email") as? NSTextField
        )
        username.stringValue = claims.username
        email.stringValue = claims.email
        let fileData = try JSONSerialization.data(withJSONObject: [
            "signedLicenseToken": "v1.payload.signature"
        ])

        controller.importOfflineLicenseFileForTesting(fileData)

        XCTAssertEqual(store.state?.status, .offlineActive)
        XCTAssertEqual(store.state?.signedLicenseToken, "v1.payload.signature")
        XCTAssertEqual(store.state?.plan, claims.plan)
        XCTAssertEqual(store.state?.permissions, claims.entitlements)
        XCTAssertNil(store.state?.offlineToken)
        let status = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.actionStatus") as? NSTextField
        )
        XCTAssertTrue(status.stringValue.contains("离线授权已应用"), status.stringValue)
    }

    func testLicenseWindowShowsRevokedOnlineValidationAsTerminalState() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let validator = StubProductOpsLicenseOnlineValidator(
            response: LicenseValidationResponse(
                username: "Ada",
                email: "ada@example.com",
                plan: "",
                expiresAt: nil,
                status: .revoked
            )
        )
        let controller = LicenseWindowController(
            service: LicenseService(store: InMemoryProductOpsLicenseStateStore()),
            onlineValidator: validator,
            nowProvider: { now }
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let licenseKey = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.licenseKey") as? NSSecureTextField
        )
        let username = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.username") as? NSTextField
        )
        let email = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.email") as? NSTextField
        )
        let validate = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.validateOnline") as? NSButton
        )
        let actionStatus = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.actionStatus") as? NSTextField
        )
        licenseKey.stringValue = "STACIO-KEY"
        username.stringValue = "Ada"
        email.stringValue = "ada@example.com"

        validate.performClick(nil)

        let deadline = Date().addingTimeInterval(1)
        while actionStatus.stringValue.contains("已撤销") == false, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(actionStatus.stringValue.contains("已撤销"), actionStatus.stringValue)
        XCTAssertFalse(actionStatus.stringValue.contains(L10n.ProductOps.licenseOnlineValidated))
    }

    func testLicenseWindowPersistsActivationRecordAfterSuccessfulOnlineValidation() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let claims = SignedLicenseClaims(
            licenseID: "license-1",
            productID: "stacio",
            email: "ada@example.com",
            username: "Ada",
            plan: "pro",
            entitlements: ["remote_sessions"],
            expiresAt: now.addingTimeInterval(86_400),
            offlineGraceSeconds: 7_200,
            issuedAt: now
        )
        let activationStore = InMemoryProductOpsActivationStore()
        let validator = StubProductOpsLicenseOnlineValidator(
            response: LicenseValidationResponse(
                username: claims.username,
                email: claims.email,
                signedLicenseToken: "v1.payload.signature",
                plan: claims.plan,
                permissions: claims.entitlements,
                expiresAt: claims.expiresAt,
                offlineGraceSeconds: claims.offlineGraceSeconds,
                status: .active
            )
        )
        let controller = LicenseWindowController(
            service: LicenseService(
                store: InMemoryProductOpsLicenseStateStore(),
                signedTokenVerifier: StubProductOpsSignedLicenseTokenVerifier(claims: claims)
            ),
            onlineValidator: validator,
            activationStore: activationStore,
            nowProvider: { now }
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let licenseKey = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.licenseKey") as? NSSecureTextField
        )
        let username = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.username") as? NSTextField
        )
        let email = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.email") as? NSTextField
        )
        let validate = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.validateOnline") as? NSButton
        )
        let actionStatus = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.actionStatus") as? NSTextField
        )
        licenseKey.stringValue = "STACIO-SECRET-KEY"
        username.stringValue = claims.username
        email.stringValue = claims.email

        validate.performClick(nil)

        let deadline = Date().addingTimeInterval(1)
        while activationStore.record == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(
            activationStore.record,
            LicenseActivationRecord(
                licenseKey: "STACIO-SECRET-KEY",
                username: claims.username,
                email: claims.email
            )
        )
        XCTAssertTrue(actionStatus.stringValue.contains(L10n.ProductOps.licenseOnlineValidated))
    }

    func testLicenseWindowDoesNotPersistActiveStateWhenActivationRecordWriteFails() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let claims = SignedLicenseClaims(
            licenseID: "license-1",
            productID: "stacio",
            email: "ada@example.com",
            username: "Ada",
            plan: "pro",
            entitlements: ["remote_sessions"],
            expiresAt: now.addingTimeInterval(86_400),
            offlineGraceSeconds: 7_200,
            issuedAt: now
        )
        let stateStore = InMemoryProductOpsLicenseStateStore()
        let activationStore = ThrowingProductOpsActivationStore()
        let controller = LicenseWindowController(
            service: LicenseService(
                store: stateStore,
                signedTokenVerifier: StubProductOpsSignedLicenseTokenVerifier(claims: claims)
            ),
            onlineValidator: StubProductOpsLicenseOnlineValidator(
                response: LicenseValidationResponse(
                    username: claims.username,
                    email: claims.email,
                    signedLicenseToken: "v1.payload.signature",
                    plan: claims.plan,
                    permissions: claims.entitlements,
                    expiresAt: claims.expiresAt,
                    offlineGraceSeconds: claims.offlineGraceSeconds,
                    status: .active
                )
            ),
            activationStore: activationStore,
            nowProvider: { now }
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let licenseKey = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.licenseKey") as? NSSecureTextField
        )
        let username = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.username") as? NSTextField
        )
        let email = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.email") as? NSTextField
        )
        let validate = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.validateOnline") as? NSButton
        )
        let actionStatus = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.actionStatus") as? NSTextField
        )
        licenseKey.stringValue = "STACIO-SECRET-KEY"
        username.stringValue = claims.username
        email.stringValue = claims.email

        validate.performClick(nil)

        let deadline = Date().addingTimeInterval(1)
        while actionStatus.stringValue.contains(L10n.ProductOps.licenseOnlineFailedPrefix) == false,
              Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertNil(stateStore.state)
        XCTAssertEqual(activationStore.saveAttempts, 1)
    }

    func testLicenseWindowOfflineImportPreservesPreviousOnlineActivationRecordForFutureRevalidation() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let activationStore = InMemoryProductOpsActivationStore()
        let previous = LicenseActivationRecord(
            licenseKey: "OLD-LICENSE-KEY",
            username: "Ada",
            email: "ada@example.com"
        )
        activationStore.record = previous
        let controller = LicenseWindowController(
            service: LicenseService(
                store: InMemoryProductOpsLicenseStateStore(),
                verifier: StubProductOpsOfflineLicenseTokenVerifier(isValid: true)
            ),
            activationStore: activationStore,
            nowProvider: { now }
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let username = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.username") as? NSTextField
        )
        let email = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.email") as? NSTextField
        )
        username.stringValue = "Ada"
        email.stringValue = "ada@example.com"
        let token = OfflineLicenseToken(
            productID: "stacio",
            username: "Ada",
            email: "ada@example.com",
            plan: "pro",
            permissions: ["remote_sessions"],
            issuedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            signatureKeyID: "primary",
            signature: "signature"
        )

        controller.importOfflineLicenseFileForTesting(try JSONEncoder.productOps.encode(token))

        XCTAssertEqual(activationStore.record, previous)
    }

    func testLicenseServiceRestoresPreviousActivationWhenOnlineStatePersistenceFails() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let claims = SignedLicenseClaims(
            licenseID: "license-1",
            productID: "stacio",
            email: "ada@example.com",
            username: "Ada",
            plan: "pro",
            entitlements: ["remote_sessions"],
            expiresAt: now.addingTimeInterval(86_400),
            offlineGraceSeconds: 7_200,
            issuedAt: now
        )
        let previous = LicenseActivationRecord(
            licenseKey: "OLD-LICENSE-KEY",
            username: "Ada",
            email: "ada@example.com"
        )
        let activationStore = InMemoryProductOpsActivationStore()
        activationStore.record = previous
        let service = LicenseService(
            store: ThrowingProductOpsLicenseStateStore(),
            signedTokenVerifier: StubProductOpsSignedLicenseTokenVerifier(claims: claims)
        )
        let request = LicenseValidationRequest(
            licenseKey: "NEW-LICENSE-KEY",
            username: claims.username,
            email: claims.email,
            appVersion: "1.0",
            buildNumber: "1",
            anonymousDeviceID: "anonymous-device"
        )
        let response = LicenseValidationResponse(
            username: claims.username,
            email: claims.email,
            signedLicenseToken: "v1.payload.signature",
            plan: claims.plan,
            permissions: claims.entitlements,
            expiresAt: claims.expiresAt,
            offlineGraceSeconds: claims.offlineGraceSeconds,
            status: .active
        )

        XCTAssertThrowsError(
            try service.state(
                applyingOnlineValidation: response,
                expected: request,
                activationStore: activationStore,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ProductOpsWindowTestError, .stateWriteFailed)
        }
        XCTAssertEqual(activationStore.record, previous)
    }

    func testLicenseServicePreservesPreviousActivationWhenOfflineStatePersistenceFails() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = LicenseActivationRecord(
            licenseKey: "OLD-LICENSE-KEY",
            username: "Ada",
            email: "ada@example.com"
        )
        let activationStore = InMemoryProductOpsActivationStore()
        activationStore.record = previous
        let service = LicenseService(
            store: ThrowingProductOpsLicenseStateStore(),
            verifier: StubProductOpsOfflineLicenseTokenVerifier(isValid: true)
        )
        let token = OfflineLicenseToken(
            productID: "stacio",
            username: "Ada",
            email: "ada@example.com",
            plan: "pro",
            permissions: ["remote_sessions"],
            issuedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            signatureKeyID: "primary",
            signature: "signature"
        )

        XCTAssertThrowsError(
            try service.state(
                applyingOfflineToken: token,
                expectedUsername: "Ada",
                expectedEmail: "ada@example.com",
                activationStore: activationStore,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ProductOpsWindowTestError, .stateWriteFailed)
        }
        XCTAssertEqual(activationStore.record, previous)
    }

    func testLicenseWindowCancelsPendingOnlineValidationWhenClosed() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let claims = SignedLicenseClaims(
            licenseID: "license-1",
            productID: "stacio",
            email: "ada@example.com",
            username: "Ada",
            plan: "pro",
            entitlements: ["remote_sessions"],
            expiresAt: now.addingTimeInterval(86_400),
            offlineGraceSeconds: 7_200,
            issuedAt: now
        )
        let activationStore = InMemoryProductOpsActivationStore()
        let gate = ProductOpsWindowAsyncGate()
        let validator = GatedProductOpsLicenseOnlineValidator(
            gate: gate,
            response: LicenseValidationResponse(
                username: claims.username,
                email: claims.email,
                signedLicenseToken: "v1.payload.signature",
                plan: claims.plan,
                permissions: claims.entitlements,
                expiresAt: claims.expiresAt,
                offlineGraceSeconds: claims.offlineGraceSeconds,
                status: .active
            )
        )
        let controller = LicenseWindowController(
            service: LicenseService(
                store: InMemoryProductOpsLicenseStateStore(),
                signedTokenVerifier: StubProductOpsSignedLicenseTokenVerifier(claims: claims)
            ),
            onlineValidator: validator,
            activationStore: activationStore,
            nowProvider: { now }
        )
        controller.showWindow(nil)

        let content = try XCTUnwrap(controller.window?.contentView)
        let licenseKey = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.licenseKey") as? NSSecureTextField
        )
        let username = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.username") as? NSTextField
        )
        let email = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.email") as? NSTextField
        )
        let validate = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.validateOnline") as? NSButton
        )
        let actionStatus = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.License.actionStatus") as? NSTextField
        )
        licenseKey.stringValue = "STACIO-SECRET-KEY"
        username.stringValue = claims.username
        email.stringValue = claims.email

        validate.performClick(nil)
        while await validator.requestCount == 0 {
            await Task.yield()
        }
        controller.close()
        await gate.open()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertNil(activationStore.record)
        XCTAssertFalse(actionStatus.stringValue.contains(L10n.ProductOps.licenseOnlineValidated))
    }
}

private func makeProductOpsWindowDefaults() throws -> UserDefaults {
    let suiteName = "StacioProductOpsWindowControllerTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private final class StubFeedbackSubmitting: FeedbackSubmitting {
    private var outcomes: [Result<FeedbackSubmissionResult, Error>]
    private(set) var idempotencyKeys: [String] = []
    var onSubmission: (() -> Void)?

    init(error: Error? = nil) {
        if let error {
            outcomes = [.failure(error)]
        } else {
            outcomes = [.success(FeedbackSubmissionResult(id: "feedback-1", message: "ok"))]
        }
    }

    init(outcomes: [Result<FeedbackSubmissionResult, Error>]) {
        self.outcomes = outcomes
    }

    func submit(report: FeedbackReport, context: FeedbackDiagnosticContext) async throws -> FeedbackSubmissionResult {
        try await submit(report: report, context: context, idempotencyKey: "legacy-submit")
    }

    func submit(
        report: FeedbackReport,
        context: FeedbackDiagnosticContext,
        idempotencyKey: String
    ) async throws -> FeedbackSubmissionResult {
        idempotencyKeys.append(idempotencyKey)
        onSubmission?()
        guard outcomes.isEmpty == false else {
            return FeedbackSubmissionResult(id: "feedback-1", message: "ok")
        }
        return try outcomes.removeFirst().get()
    }
}

private actor GatedFeedbackSubmitter: FeedbackSubmitting {
    private var idempotencyKeys: [String] = []
    private var continuations: [CheckedContinuation<FeedbackSubmissionResult, Never>] = []

    func submit(report: FeedbackReport, context: FeedbackDiagnosticContext) async throws -> FeedbackSubmissionResult {
        try await submit(report: report, context: context, idempotencyKey: "legacy-submit")
    }

    func submit(
        report: FeedbackReport,
        context: FeedbackDiagnosticContext,
        idempotencyKey: String
    ) async throws -> FeedbackSubmissionResult {
        idempotencyKeys.append(idempotencyKey)
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func submissionCount() -> Int {
        idempotencyKeys.count
    }

    func finishAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach {
            $0.resume(returning: FeedbackSubmissionResult(id: "feedback-1", message: "ok"))
        }
    }
}

private final class StubUpdateChecking: UpdateChecking {
    let status: UpdateCheckStatus

    init(status: UpdateCheckStatus) {
        self.status = status
    }

    func checkForUpdates() async throws -> UpdateCheckStatus {
        status
    }
}

@MainActor
private final class StubSparkleManualUpdateChecker: SparkleUpdateChecking {
    func checkForUpdates(_ sender: Any?) {}

    func checkForUpdateInformation(_ sender: Any?) {}
}

@MainActor
private final class RecordingSparkleUpdateActions: SparkleUpdateActionHandling {
    private(set) var downloadedUpdates: [SparkleUpdatePromptInfo] = []
    private(set) var remindedLaterUpdates: [SparkleUpdatePromptInfo] = []
    private(set) var skippedUpdates: [SparkleUpdatePromptInfo] = []

    func downloadUpdate(_ update: SparkleUpdatePromptInfo) {
        downloadedUpdates.append(update)
    }

    func remindLater(_ update: SparkleUpdatePromptInfo) {
        remindedLaterUpdates.append(update)
    }

    func skip(_ update: SparkleUpdatePromptInfo) {
        skippedUpdates.append(update)
    }
}

private final class StubProductOpsURLOpener: ProductOpsURLOpening {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) {
        openedURLs.append(url)
    }
}

private struct StubProductOpsOfflineLicenseTokenVerifier: OfflineLicenseTokenVerifying {
    let isValid: Bool

    func validate(_ token: OfflineLicenseToken) -> Bool {
        isValid
    }
}

private struct StubProductOpsSignedLicenseTokenVerifier: SignedLicenseTokenVerifying {
    let claims: SignedLicenseClaims

    func verifiedClaims(from token: String) throws -> SignedLicenseClaims {
        claims
    }
}

private final class StubProductOpsLicenseOnlineValidator: LicenseOnlineValidating {
    let response: LicenseValidationResponse

    init(response: LicenseValidationResponse) {
        self.response = response
    }

    func validate(_ requestBody: LicenseValidationRequest) async throws -> LicenseValidationResponse {
        response
    }
}

private actor GatedProductOpsLicenseOnlineValidator: LicenseOnlineValidating {
    private let gate: ProductOpsWindowAsyncGate
    private let response: LicenseValidationResponse
    private(set) var requestCount = 0

    init(gate: ProductOpsWindowAsyncGate, response: LicenseValidationResponse) {
        self.gate = gate
        self.response = response
    }

    func validate(_ requestBody: LicenseValidationRequest) async throws -> LicenseValidationResponse {
        requestCount += 1
        await gate.wait()
        return response
    }
}

private actor ProductOpsWindowAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard isOpen == false else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class InMemoryProductOpsActivationStore: LicenseActivationRecordStoring {
    var record: LicenseActivationRecord?

    func loadActivationRecord() throws -> LicenseActivationRecord? {
        record
    }

    func saveActivationRecord(_ record: LicenseActivationRecord) throws {
        self.record = record
    }

    func deleteActivationRecord() throws {
        record = nil
    }
}

private enum ProductOpsWindowTestError: Error {
    case activationWriteFailed
    case stateWriteFailed
}

private final class ThrowingProductOpsActivationStore: LicenseActivationRecordStoring {
    private(set) var saveAttempts = 0

    func loadActivationRecord() throws -> LicenseActivationRecord? {
        nil
    }

    func saveActivationRecord(_ record: LicenseActivationRecord) throws {
        saveAttempts += 1
        throw ProductOpsWindowTestError.activationWriteFailed
    }

    func deleteActivationRecord() throws {}
}

private final class ThrowingProductOpsLicenseStateStore: LicenseStateStoring {
    func load() throws -> LicenseState? {
        nil
    }

    func save(_ state: LicenseState) throws {
        throw ProductOpsWindowTestError.stateWriteFailed
    }
}

private final class InMemoryProductOpsLicenseStateStore: LicenseStateStoring {
    var state: LicenseState?

    init(state: LicenseState? = nil) {
        self.state = state
    }

    func load() throws -> LicenseState? {
        state
    }

    func save(_ state: LicenseState) throws {
        self.state = state
    }
}

private extension NSView {
    func firstSubview(withIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }
        for subview in subviews {
            if let match = subview.firstSubview(withIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private func fillValidFeedbackDraft(in controller: FeedbackWindowController) throws {
    let content = try XCTUnwrap(controller.window?.contentView)
    let title = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Feedback.title") as? NSTextField)
    let descriptionScroll = try XCTUnwrap(
        content.firstSubview(withIdentifier: "Stacio.Feedback.description") as? NSScrollView
    )
    let description = try XCTUnwrap(descriptionScroll.documentView as? NSTextView)
    title.stringValue = "Connection problem"
    description.string = "The connection did not recover."
}

@MainActor
private func waitForFeedbackState(
    _ expectedState: FeedbackSubmissionState,
    in controller: FeedbackWindowController,
    timeout: TimeInterval = 1
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while controller.submissionState != expectedState, Date() < deadline {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(controller.submissionState, expectedState)
}
