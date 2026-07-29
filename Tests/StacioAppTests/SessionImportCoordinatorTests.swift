import AppKit
import XCTest
@testable import StacioApp
import StacioCoreBindings
import ZIPFoundation

final class SessionImportCoordinatorTests: XCTestCase {
    func testCoordinatorRecordsBoundedRedactedTraceForBastionImport() throws {
        let traceStore = FeedbackDiagnosticTraceStore(
            maxEvents: 16,
            ttl: 86_400,
            clock: Date.init,
            routeHashKey: Data(repeating: 0x42, count: 32)
        )
        let diagnosticLog = makeTestFeedbackDiagnosticLogStore()
        let payload = ExternalSessionImportPayload(
            sessions: [externalBastionSession(
                name: "Database",
                targetHost: "10.20.30.40",
                targetUsername: "dbadmin",
                credential: .password("never-record-this")
            )],
            warnings: []
        )
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(
                    sourceName: "topsec-export.xsh",
                    sourceType: .bastionHost,
                    contents: "topsec raw export"
                )
            ),
            presenter: RecordingSessionImportPresenter(confirmImport: true),
            core: RecordingSessionImportCore(
                applyResult: makeApplyResult(importedNames: ["Database"], importedCount: 1, skippedCount: 0)
            ),
            credentialApplier: RecordingExternalSessionCredentialApplier(),
            bastionHostAuthorizer: RecordingBastionHostFeatureAuthorizer(),
            bastionHostImportResolver: RecordingBastionHostSessionImportResolver(
                fallbackPayload: nil,
                automaticallyResolvedPayload: payload
            ),
            diagnosticTraceRecorder: traceStore,
            diagnosticLogRecorder: diagnosticLog
        )

        _ = try coordinator.runImport(sourceType: .bastionHost, parentWindow: nil)

        let trace = traceStore.snapshot()
        XCTAssertEqual(trace.events.map(\.stage), [.selection, .recognition, .preview, .apply, .credentials])
        XCTAssertEqual(trace.events.map(\.result), [.selected, .ready, .ready, .succeeded, .succeeded])
        let routeHashes = trace.events.flatMap(\.routeHashes)
        XCTAssertFalse(routeHashes.isEmpty)
        XCTAssertTrue(routeHashes.allSatisfy {
            $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
        })
        let json = try XCTUnwrap(trace.encodedJSONString())
        XCTAssertFalse(json.contains("bastion.example.com"))
        XCTAssertFalse(json.contains("10.20.30.40"))
        XCTAssertFalse(json.contains("dbadmin"))
        XCTAssertFalse(json.contains("opaque@default"))
        XCTAssertFalse(json.contains("never-record-this"))
        XCTAssertFalse(json.contains("topsec raw export"))
        XCTAssertFalse(json.contains("topsec-export.xsh"))
        let diagnosticEvents = diagnosticLog.snapshot().events
        XCTAssertEqual(diagnosticEvents.map(\.eventCode), Array(repeating: .sessionImportStage, count: 5))
        XCTAssertEqual(
            diagnosticEvents.map(\.stage),
            [.selection, .recognition, .preview, .apply, .credentials]
        )
        let diagnosticJSON = try XCTUnwrap(diagnosticLog.snapshot().encodedJSONString())
        for forbidden in [
            "bastion.example.com", "10.20.30.40", "dbadmin", "opaque@default",
            "never-record-this", "topsec raw export", "topsec-export.xsh"
        ] {
            XCTAssertFalse(diagnosticJSON.contains(forbidden), forbidden)
        }
    }

    func testCoordinatorRecordsApplySuccessBeforeCredentialFailure() throws {
        let traceStore = FeedbackDiagnosticTraceStore(
            maxEvents: 16,
            ttl: 86_400,
            clock: Date.init,
            routeHashKey: Data(repeating: 0x42, count: 32)
        )
        let payload = ExternalSessionImportPayload(
            sessions: [externalBastionSession(
                name: "Database",
                targetHost: "10.20.30.40",
                credential: .password("never-record-this")
            )],
            warnings: []
        )
        let credentialError = NSError(domain: "credential", code: 1)
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(
                    sourceName: "topsec-export.xsh",
                    sourceType: .bastionHost,
                    contents: "topsec raw export"
                )
            ),
            presenter: RecordingSessionImportPresenter(confirmImport: true),
            core: RecordingSessionImportCore(
                applyResult: makeApplyResult(importedNames: ["Database"], importedCount: 1, skippedCount: 0)
            ),
            credentialApplier: RecordingExternalSessionCredentialApplier(error: credentialError),
            bastionHostAuthorizer: RecordingBastionHostFeatureAuthorizer(),
            bastionHostImportResolver: RecordingBastionHostSessionImportResolver(
                fallbackPayload: nil,
                automaticallyResolvedPayload: payload
            ),
            diagnosticTraceRecorder: traceStore
        )

        XCTAssertThrowsError(try coordinator.runImport(sourceType: .bastionHost, parentWindow: nil))

        let events = traceStore.snapshot().events
        XCTAssertEqual(events.suffix(2).map(\.stage), [.apply, .credentials])
        XCTAssertEqual(events.suffix(2).map(\.result), [.succeeded, .failed])
        XCTAssertEqual(events.last?.errorCode, "credentials_failed")
    }

    func testSourcePickerListsRequestedClientsWithoutNyaTerm() {
        XCTAssertEqual(AppKitSessionImportSourcePicker.supportedSources.map(\.type), [
            .stacioJSON,
            .xShell,
            .mobaXterm,
            .windTerm,
            .secureCRT,
            .finalShell,
            .termius,
            .electerm,
            .genericJSON,
            .bastionHost
        ])
        XCTAssertFalse(AppKitSessionImportSourcePicker.supportedSources.map(\.name).contains("NyaTerm"))
        XCTAssertEqual(
            AppKitSessionImportSourcePicker.supportedSources.compactMap(\.iconResourceName),
            [
                "xshell.svg",
                "mobaxterm.svg",
                "windterm.svg",
                "securecrt.svg",
                "finalshell.svg",
                "termius.svg",
                "electerm.svg",
                "bastion-host.png"
            ]
        )
        XCTAssertEqual(
            AppKitSessionImportSourcePicker.supportedSources.first { $0.type == .secureCRT }?.hint,
            ".xml / .ini / .zip"
        )
    }

    func testImportSourceIconsLoadAtMenuSize() throws {
        for source in AppKitSessionImportSourcePicker.supportedSources {
            let image = try XCTUnwrap(SessionImportSourceIconCatalog.image(for: source), source.name)
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18), source.name)
            if source.type != .genericJSON {
                XCTAssertFalse(image.isTemplate, source.name)
            }
        }
    }

    func testBastionImportMenuItemIsDisabledWithUpgradeTooltipWithoutLicense() throws {
        let source = try XCTUnwrap(
            AppKitSessionImportSourcePicker.supportedSources.first { $0.type == .bastionHost }
        )
        let item = NSMenuItem(title: source.name, action: nil, keyEquivalent: "")
        SessionImportSourceAvailability.configure(
            item,
            for: source,
            licenseAccess: RecordingLicenseFeatureAccessProvider(enabled: false)
        )

        XCTAssertFalse(item.isEnabled)
        XCTAssertEqual(item.toolTip, "该功能模块无有效授权，请升级授权。")
    }

    func testBastionImportMenuItemIsEnabledWithValidLicense() throws {
        let source = try XCTUnwrap(
            AppKitSessionImportSourcePicker.supportedSources.first { $0.type == .bastionHost }
        )
        let item = NSMenuItem(title: source.name, action: nil, keyEquivalent: "")
        SessionImportSourceAvailability.configure(
            item,
            for: source,
            licenseAccess: RecordingLicenseFeatureAccessProvider(enabled: true)
        )

        XCTAssertTrue(item.isEnabled)
        XCTAssertNil(item.toolTip)
    }

    func testOrdinaryBulkImportMenuItemRequiresSessionBulkIOLicense() throws {
        let source = try XCTUnwrap(
            AppKitSessionImportSourcePicker.supportedSources.first { $0.type == .windTerm }
        )
        let item = NSMenuItem(title: source.name, action: nil, keyEquivalent: "")
        SessionImportSourceAvailability.configure(
            item,
            for: source,
            licenseAccess: RecordingLicenseFeatureAccessProvider(enabled: false)
        )

        XCTAssertFalse(item.isEnabled)
        XCTAssertEqual(item.toolTip, L10n.Import.licenseUnavailableTooltip)
    }

    func testBulkImportRequiresLicenseBeforeOpeningFilePicker() throws {
        let picker = RecordingSourceAwareSessionImportFilePicker(file: nil)
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: picker,
            presenter: RecordingSessionImportPresenter(confirmImport: false),
            core: RecordingSessionImportCore(),
            licensedFeatureAuthorizer: LicenseFeatureAuthorizer(
                accessProvider: RecordingLicenseFeatureAccessProvider(enabled: false)
            )
        )

        XCTAssertThrowsError(try coordinator.runImport(sourceType: .windTerm, parentWindow: nil)) { error in
            XCTAssertEqual(error as? LicensedFeatureAccessError, .licenseRequired(.sessionBulkIO))
        }
        XCTAssertTrue(picker.requestedSourceTypes.isEmpty)
    }

    func testCoordinatorRequestsFileForSelectedImportSourceWithoutSourcePicker() throws {
        let picker = RecordingSourceAwareSessionImportFilePicker(file: nil)
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: picker,
            presenter: RecordingSessionImportPresenter(confirmImport: false),
            core: RecordingSessionImportCore()
        )

        _ = try coordinator.runImport(sourceType: .windTerm, parentWindow: nil)

        XCTAssertEqual(picker.requestedSourceTypes, [.windTerm])
    }

    func testBastionImportRequiresLicenseBeforeOpeningFilePicker() {
        let picker = RecordingSourceAwareSessionImportFilePicker(file: nil)
        let presenter = RecordingSessionImportPresenter(confirmImport: false)
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: picker,
            presenter: presenter,
            core: RecordingSessionImportCore(),
            bastionHostAuthorizer: RecordingBastionHostFeatureAuthorizer(error: .licenseRequired)
        )

        XCTAssertThrowsError(try coordinator.runImport(sourceType: .bastionHost, parentWindow: nil)) { error in
            XCTAssertEqual(error as? BastionHostFeatureAccessError, .licenseRequired)
        }
        XCTAssertTrue(picker.requestedSourceTypes.isEmpty)
        XCTAssertTrue(presenter.shownErrors.isEmpty)
    }

    func testBastionImportDoesNotAlsoRequireSessionBulkIOLicense() throws {
        let picker = RecordingSourceAwareSessionImportFilePicker(file: nil)
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: picker,
            presenter: RecordingSessionImportPresenter(confirmImport: false),
            core: RecordingSessionImportCore(),
            bastionHostAuthorizer: RecordingBastionHostFeatureAuthorizer(),
            licensedFeatureAuthorizer: LicenseFeatureAuthorizer(
                accessProvider: RecordingLicenseFeatureAccessProvider(enabled: false)
            )
        )

        let result = try coordinator.runImport(sourceType: .bastionHost, parentWindow: nil)

        XCTAssertNil(result)
        XCTAssertEqual(picker.requestedSourceTypes, [.bastionHost])
    }

    func testBastionImportAutomaticallyParsesXshellFileBehindDedicatedSource() throws {
        let contents = """
        [CONNECTION]
        Host=bastion.example.com
        Port=60022
        UserName=SSH@ops@10.0.0.8
        """
        let presenter = RecordingSessionImportPresenter(confirmImport: false)
        let authorizer = RecordingBastionHostFeatureAuthorizer()
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSourceAwareSessionImportFilePicker(
                file: SessionImportFile(
                    sourceName: "asset.xsh",
                    sourceType: .bastionHost,
                    contents: contents,
                    sourceURL: URL(fileURLWithPath: "/tmp/asset.xsh")
                )
            ),
            presenter: presenter,
            core: RecordingSessionImportCore(),
            bastionHostAuthorizer: authorizer
        )

        _ = try coordinator.runImport(sourceType: .bastionHost, parentWindow: nil)

        XCTAssertEqual(authorizer.authorizationCount, 1)
        XCTAssertEqual(presenter.previewedSessionNames, ["asset"])
    }

    func testRecognizedBastionImportDoesNotPromptForVendorFallback() throws {
        let contents = """
        [CONNECTION]
        Host=bastion.example.com
        Port=2222
        [CONNECTION:AUTHENTICATION]
        UserName=opaque-account@default@SSH@ops@10.0.0.8@22
        """
        let vendorSelector = RecordingBastionHostVendorSelector(selectedVendor: .sangfor)
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSourceAwareSessionImportFilePicker(
                file: SessionImportFile(
                    sourceName: "asset.xsh",
                    sourceType: .bastionHost,
                    contents: contents,
                    sourceURL: URL(fileURLWithPath: "/tmp/asset.xsh")
                )
            ),
            presenter: RecordingSessionImportPresenter(confirmImport: false),
            core: RecordingSessionImportCore(),
            bastionHostAuthorizer: RecordingBastionHostFeatureAuthorizer(),
            bastionHostVendorSelector: vendorSelector
        )

        _ = try coordinator.runImport(sourceType: .bastionHost, parentWindow: nil)

        XCTAssertTrue(vendorSelector.requestedSourceNames.isEmpty)
    }

    func testBastionImportRecognitionFailurePromptsAndRetriesWithSelectedVendor() throws {
        let fallbackPayload = ExternalSessionImportPayload(
            sessions: [
                ExternalImportedSession(
                    name: "Asset",
                    folderPath: nil,
                    protocolName: "ssh",
                    host: "bastion.example.com",
                    port: 22,
                    username: "account",
                    privateKeyPath: nil,
                    credential: nil
                )
            ],
            warnings: []
        )
        let resolver = RecordingBastionHostSessionImportResolver(fallbackPayload: fallbackPayload)
        let vendorSelector = RecordingBastionHostVendorSelector(selectedVendor: .sangfor)
        let presenter = RecordingSessionImportPresenter(confirmImport: false)
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSourceAwareSessionImportFilePicker(
                file: SessionImportFile(
                    sourceName: "vendor-export.dat",
                    sourceType: .bastionHost,
                    contents: "unrecognized",
                    sourceURL: URL(fileURLWithPath: "/tmp/vendor-export.dat")
                )
            ),
            presenter: presenter,
            core: RecordingSessionImportCore(),
            bastionHostAuthorizer: RecordingBastionHostFeatureAuthorizer(),
            bastionHostImportResolver: resolver,
            bastionHostVendorSelector: vendorSelector
        )

        _ = try coordinator.runImport(sourceType: .bastionHost, parentWindow: nil)

        XCTAssertEqual(resolver.vendorHints, [nil, .sangfor])
        XCTAssertEqual(vendorSelector.requestedSourceNames, ["vendor-export.dat"])
        XCTAssertEqual(presenter.previewedSessionNames, ["Asset"])
    }

    func testBastionImportVendorFallbackCancellationStopsWithoutError() throws {
        let resolver = RecordingBastionHostSessionImportResolver(fallbackPayload: nil)
        let vendorSelector = RecordingBastionHostVendorSelector(selectedVendor: nil)
        let presenter = RecordingSessionImportPresenter(confirmImport: false)
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSourceAwareSessionImportFilePicker(
                file: SessionImportFile(
                    sourceName: "unknown.dat",
                    sourceType: .bastionHost,
                    contents: "unrecognized"
                )
            ),
            presenter: presenter,
            core: RecordingSessionImportCore(),
            bastionHostAuthorizer: RecordingBastionHostFeatureAuthorizer(),
            bastionHostImportResolver: resolver,
            bastionHostVendorSelector: vendorSelector
        )

        let result = try coordinator.runImport(sourceType: .bastionHost, parentWindow: nil)

        XCTAssertNil(result)
        XCTAssertEqual(resolver.vendorHints, [nil])
        XCTAssertEqual(vendorSelector.requestedSourceNames, ["unknown.dat"])
        XCTAssertTrue(presenter.previewedSessionNames.isEmpty)
    }

    func testBastionImportVendorFallbackFailureReturnsClearSelectedVendorError() {
        let resolver = RecordingBastionHostSessionImportResolver(fallbackPayload: nil)
        let vendorSelector = RecordingBastionHostVendorSelector(selectedVendor: .sangfor)
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSourceAwareSessionImportFilePicker(
                file: SessionImportFile(
                    sourceName: "unknown.dat",
                    sourceType: .bastionHost,
                    contents: "unrecognized"
                )
            ),
            presenter: RecordingSessionImportPresenter(confirmImport: false),
            core: RecordingSessionImportCore(),
            bastionHostAuthorizer: RecordingBastionHostFeatureAuthorizer(),
            bastionHostImportResolver: resolver,
            bastionHostVendorSelector: vendorSelector
        )

        XCTAssertThrowsError(
            try coordinator.runImport(sourceType: .bastionHost, parentWindow: nil)
        ) { error in
            XCTAssertEqual(
                error as? BastionHostVendorFallbackError,
                .recognitionFailed(.sangfor)
            )
            XCTAssertTrue(error.localizedDescription.contains("深信服"))
        }
        XCTAssertEqual(resolver.vendorHints, [nil, .sangfor])
    }

    func testSelectedBastionVendorAddsMetadataToGenericClientFormat() throws {
        let payload = try DefaultBastionHostSessionImportResolver().resolve(
            file: SessionImportFile(
                sourceName: "asset.xsh",
                sourceType: .bastionHost,
                contents: """
                [CONNECTION]
                Host=bastion.example.com
                Port=2222
                UserName=account
                """,
                sourceURL: URL(fileURLWithPath: "/tmp/asset.xsh")
            ),
            vendorHint: .sangfor
        )

        let config = try XCTUnwrap(payload.sessions.first?.configJSON)
        XCTAssertTrue(config.contains("\"bastionVendor\":\"sangfor\""))
        XCTAssertTrue(config.contains("\"bastionFormat\":\"vendor_selected_external_session\""))
    }

    func testBastionVendorFallbackPopupListsStableVendorChoices() {
        let popup = AppKitBastionHostVendorSelector.vendorPopupForTesting()

        XCTAssertEqual(popup.identifier?.rawValue, "Stacio.Import.bastionVendor")
        XCTAssertEqual(popup.numberOfItems, AppKitBastionHostVendorSelector.selectableVendors.count)
        XCTAssertEqual(Set(AppKitBastionHostVendorSelector.selectableVendors), Set(BastionHostVendor.allCases))
        XCTAssertEqual(
            popup.itemArray.compactMap { $0.representedObject as? String },
            AppKitBastionHostVendorSelector.selectableVendors.map(\.rawValue)
        )
        XCTAssertEqual(popup.itemTitles.first, "天融信")
    }

    func testSecureCRTImportAutomaticallyParsesTopsecZIP() throws {
        let contents = """
        S:"Protocol Name"=SSH2
        S:"Hostname"=bastion.example.com
        S:"Username"=opaque-account@default@SSH@ops@10.0.0.8@22
        D:"[SSH2] Port"=000008AE
        S:"Password"=
        """
        let archiveURL = try makeSessionImportArchive(entries: [
            "asset.ini": Data(contents.utf8)
        ])
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let presenter = RecordingSessionImportPresenter(confirmImport: false)
        let authorizer = RecordingBastionHostFeatureAuthorizer()
        let picker = RecordingSourceAwareSessionImportFilePicker(
            file: SessionImportFile(
                sourceName: "sessions.zip",
                sourceType: .secureCRT,
                contents: "",
                sourceURL: archiveURL
            )
        )
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: picker,
            presenter: presenter,
            core: RecordingSessionImportCore(),
            bastionHostAuthorizer: authorizer
        )

        _ = try coordinator.runImport(sourceType: .secureCRT, parentWindow: nil)

        XCTAssertEqual(picker.requestedSourceTypes, [.secureCRT])
        XCTAssertEqual(authorizer.authorizationCount, 1)
        XCTAssertEqual(presenter.previewedSessionNames, ["asset"])
        XCTAssertTrue(try XCTUnwrap(presenter.previewedConfigJSON.first).contains("topsec_securecrt_zip"))
    }

    func testXshellImportFallsBackToOrdinaryZIPWhenItIsNotATopsecExport() throws {
        let contents = """
        [CONNECTION]
        Host=server.example.com
        Port=2222
        Protocol=SSH
        [CONNECTION:AUTHENTICATION]
        UserName=deploy
        """
        let archiveURL = try makeSessionImportArchive(entries: [
            "Servers/production.xsh": Data(contents.utf8)
        ])
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let presenter = RecordingSessionImportPresenter(confirmImport: false)
        let authorizer = RecordingBastionHostFeatureAuthorizer()
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSourceAwareSessionImportFilePicker(
                file: SessionImportFile(
                    sourceName: "sessions.zip",
                    sourceType: .xShell,
                    contents: "",
                    sourceURL: archiveURL
                )
            ),
            presenter: presenter,
            core: RecordingSessionImportCore(),
            bastionHostAuthorizer: authorizer
        )

        _ = try coordinator.runImport(sourceType: .xShell, parentWindow: nil)

        XCTAssertEqual(presenter.previewedSessionNames, ["production"])
        XCTAssertEqual(authorizer.authorizationCount, 0)
    }

    func testSecureCRTImportFallsBackToOrdinaryZIPWhenItIsNotATopsecExport() throws {
        let contents = """
        D:"Is Session"=00000001
        S:"Protocol Name"=SSH2
        S:"Hostname"=server.example.com
        S:"Username"=deploy
        D:"[SSH2] Port"=000008AE
        """
        let archiveURL = try makeSessionImportArchive(entries: [
            "Servers/production.ini": Data(contents.utf8)
        ])
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let presenter = RecordingSessionImportPresenter(confirmImport: false)
        let authorizer = RecordingBastionHostFeatureAuthorizer()
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSourceAwareSessionImportFilePicker(
                file: SessionImportFile(
                    sourceName: "sessions.zip",
                    sourceType: .secureCRT,
                    contents: "",
                    sourceURL: archiveURL
                )
            ),
            presenter: presenter,
            core: RecordingSessionImportCore(),
            bastionHostAuthorizer: authorizer
        )

        _ = try coordinator.runImport(sourceType: .secureCRT, parentWindow: nil)

        XCTAssertEqual(presenter.previewedSessionNames, ["Servers__production"])
        XCTAssertEqual(authorizer.authorizationCount, 0)
    }

    func testBastionManifestConfigIsForwardedIntoImportPreview() throws {
        let contents = """
        {"format":"stacio.bastion.v1","vendor":"安恒","sessions":[{
          "name":"DB","protocol":"ssh","gatewayHost":"bastion.example.com",
          "gatewayPort":22,"gatewayUsername":"dba@asset@gateway","assetId":"asset-db"
        }]}
        """
        let presenter = RecordingSessionImportPresenter(confirmImport: false)
        let core = RecordingSessionImportCore()
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSourceAwareSessionImportFilePicker(
                file: SessionImportFile(
                    sourceName: "db.stacio-bastion",
                    sourceType: .bastionHost,
                    contents: contents,
                    sourceURL: URL(fileURLWithPath: "/tmp/db.stacio-bastion")
                )
            ),
            presenter: presenter,
            core: core,
            bastionHostAuthorizer: RecordingBastionHostFeatureAuthorizer()
        )

        _ = try coordinator.runImport(sourceType: .bastionHost, parentWindow: nil)

        XCTAssertEqual(presenter.previewedSessionNames, ["DB"])
        XCTAssertTrue(try XCTUnwrap(presenter.previewedConfigJSON.first).contains("dbappsecurity"))
    }

    func testCoordinatorRequiresBastionLicenseBeforeConfirmingDetectedXshellSession() {
        let contents = """
        [CONNECTION]
        Host=bastion.example.com
        Port=60022
        UserName=SSH@ops@10.0.0.8
        """
        let presenter = RecordingSessionImportPresenter(confirmImport: true)
        let authorizer = RecordingBastionHostFeatureAuthorizer(error: .licenseRequired)
        let traceStore = FeedbackDiagnosticTraceStore(
            maxEvents: 16,
            ttl: 86_400,
            clock: Date.init,
            routeHashKey: Data(repeating: 0x42, count: 32)
        )
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(sourceName: "asset.xsh", sourceType: .xShell, contents: contents)
            ),
            presenter: presenter,
            core: RecordingSessionImportCore(),
            bastionHostAuthorizer: authorizer,
            diagnosticTraceRecorder: traceStore
        )

        XCTAssertThrowsError(try coordinator.runImport(parentWindow: nil)) { error in
            XCTAssertEqual(error as? BastionHostFeatureAccessError, .licenseRequired)
        }
        XCTAssertEqual(authorizer.authorizationCount, 1)
        XCTAssertTrue(presenter.previewedSessionNames.isEmpty)
        XCTAssertEqual(traceStore.snapshot().events.last?.stage, .recognition)
        XCTAssertEqual(traceStore.snapshot().events.last?.result, .failed)
        XCTAssertEqual(traceStore.snapshot().events.last?.errorCode, "authorization_failed")
    }

    func testCoordinatorDoesNotRequireBastionLicenseForOrdinaryXshellSession() throws {
        let contents = """
        [CONNECTION]
        Host=server.example.com
        Port=22
        UserName=root
        """
        let authorizer = RecordingBastionHostFeatureAuthorizer(error: .licenseRequired)
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(sourceName: "server.xsh", sourceType: .xShell, contents: contents)
            ),
            presenter: RecordingSessionImportPresenter(confirmImport: false),
            core: RecordingSessionImportCore(),
            bastionHostAuthorizer: authorizer
        )

        _ = try coordinator.runImport(parentWindow: nil)

        XCTAssertEqual(authorizer.authorizationCount, 0)
    }

    func testCoordinatorAppliesExternalCredentialsAfterSessionImport() throws {
        let contents = """
        [{"session.protocol":"SSH","session.target":"deploy@web.example.com","session.label":"Web","session.password":"pw"}]
        """
        let core = RecordingSessionImportCore(
            applyResult: makeApplyResult(importedNames: ["Web"], importedCount: 1, skippedCount: 0)
        )
        let credentialApplier = RecordingExternalSessionCredentialApplier()
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(sourceName: "sessions.sessions", sourceType: .windTerm, contents: contents)
            ),
            presenter: RecordingSessionImportPresenter(confirmImport: true),
            core: core,
            credentialApplier: credentialApplier
        )

        let result = try coordinator.runImport(parentWindow: nil)

        XCTAssertEqual(result?.report.importedCount, 1)
        XCTAssertEqual(credentialApplier.appliedSessions.map(\.name), ["Web"])
        XCTAssertEqual(credentialApplier.appliedPayload?.sessions[0].credential, .password("pw"))
        XCTAssertEqual(core.events, ["listAll", "apply:windterm:sessions.sessions"])
    }

    func testCoordinatorAppliesMobaXtermPreviewAndCredentials() throws {
        let contents = """
        [Bookmarks]
        SubRep=Production\\Web
        Web 01=#109#0%web.example.com%2222%deploy
        [Passwords]
        deploy@web.example.com=plain-secret
        """
        let core = RecordingSessionImportCore(
            applyResult: makeApplyResult(importedNames: ["Web 01"], importedCount: 1, skippedCount: 0)
        )
        let credentialApplier = RecordingExternalSessionCredentialApplier()
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(
                    sourceName: "MobaXterm Sessions.mxtsessions",
                    sourceType: .mobaXterm,
                    contents: contents
                )
            ),
            presenter: RecordingSessionImportPresenter(confirmImport: true),
            core: core,
            credentialApplier: credentialApplier
        )

        let result = try coordinator.runImport(parentWindow: nil)

        XCTAssertEqual(result?.report.importedCount, 1)
        XCTAssertEqual(credentialApplier.appliedSessions.map(\.name), ["Web 01"])
        XCTAssertEqual(credentialApplier.appliedPayload?.sessions[0].credential, .password("plain-secret"))
        XCTAssertEqual(core.events, ["listAll", "apply:mobaxterm:MobaXterm Sessions.mxtsessions"])
    }

    func testCoordinatorDoesNotApplyCredentialFromFilteredFTPSessionWithSameName() throws {
        let payload = ExternalSessionImportPayload(
            sessions: [
                ExternalImportedSession(
                    name: "Shared",
                    folderPath: nil,
                    protocolName: "ssh",
                    host: "shared.example.com",
                    port: 22,
                    username: "deploy",
                    privateKeyPath: nil,
                    credential: .password("ssh-secret")
                ),
                ExternalImportedSession(
                    name: "Shared",
                    folderPath: nil,
                    protocolName: "ftp",
                    host: "shared.example.com",
                    port: 21,
                    username: "deploy",
                    privateKeyPath: nil,
                    credential: .password("ftp-secret")
                )
            ],
            warnings: []
        )
        let core = RecordingSessionImportCore(
            applyResult: makeApplyResult(importedNames: ["Shared"], importedCount: 1, skippedCount: 0)
        )
        let credentialApplier = RecordingExternalSessionCredentialApplier()
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(
                    sourceName: "sessions.stacio-bastion",
                    sourceType: .bastionHost,
                    contents: "fixture"
                )
            ),
            presenter: RecordingSessionImportPresenter(confirmImport: true),
            core: core,
            credentialApplier: credentialApplier,
            bastionHostAuthorizer: RecordingBastionHostFeatureAuthorizer(),
            bastionHostImportResolver: RecordingBastionHostSessionImportResolver(
                fallbackPayload: nil,
                automaticallyResolvedPayload: payload
            )
        )

        _ = try coordinator.runImport(parentWindow: nil)

        let appliedPayload = try XCTUnwrap(credentialApplier.appliedPayload)
        XCTAssertEqual(appliedPayload.sessions.map(\.protocolName), ["ssh"])
        XCTAssertEqual(appliedPayload.sessions.map(\.credential), [.password("ssh-secret")])
    }

    func testBastionPreviewUsesRouteIdentityAndRenamesSameNameDifferentTarget() throws {
        let existing = SessionRecord(
            id: "existing_target_a",
            folderId: nil,
            name: "Database",
            protocol: "ssh",
            host: "bastion.example.com",
            port: 2222,
            username: "opaque@default@SSH@dbadmin@10.0.0.8@22",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )
        let existingConfig = """
        {"bastionVendor":"topsec","bastionTargetHost":"10.0.0.8","bastionTargetPort":22,"bastionTargetUsername":"dbadmin"}
        """
        let payload = ExternalSessionImportPayload(
            sessions: [
                externalBastionSession(name: "Database", targetHost: "10.0.0.8"),
                externalBastionSession(name: "Database", targetHost: "10.0.0.9")
            ],
            warnings: []
        )
        let presenter = RecordingSessionImportPresenter(confirmImport: false)
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(
                    sourceName: "sessions.zip",
                    sourceType: .bastionHost,
                    contents: "fixture"
                )
            ),
            presenter: presenter,
            core: RecordingSessionImportCore(
                existingSessions: [existing],
                configJSONBySessionID: [existing.id: existingConfig]
            ),
            bastionHostAuthorizer: RecordingBastionHostFeatureAuthorizer(),
            bastionHostImportResolver: RecordingBastionHostSessionImportResolver(
                fallbackPayload: nil,
                automaticallyResolvedPayload: payload
            )
        )

        _ = try coordinator.runImport(sourceType: .bastionHost, parentWindow: nil)

        XCTAssertEqual(presenter.previewedSessions.map(\.conflict), [true, false])
        XCTAssertEqual(presenter.previewedSessions.map(\.name), ["Database", "Database · 10.0.0.9"])
        XCTAssertTrue(presenter.previewedSessions.allSatisfy { $0.host == "bastion.example.com" })
        XCTAssertTrue(presenter.previewedSessions.allSatisfy {
            $0.username?.contains("opaque@default@SSH") == true
        })
    }

    func testBastionCredentialMatcherUsesRouteWhenImportedDisplayNameChanged() {
        let source = externalBastionSession(
            name: "Database",
            targetHost: "10.0.0.9",
            credential: .password("secret")
        )
        let imported = SessionRecord(
            id: "imported_target_b",
            folderId: nil,
            name: "Database · 10.0.0.9",
            protocol: "ssh",
            host: source.host,
            port: UInt32(source.port),
            username: source.username,
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )

        let matchedID = KeychainExternalSessionCredentialApplier.matchedSessionIDForTesting(
            source: source,
            importedSessions: [imported],
            configJSONBySessionID: [imported.id: source.configJSON ?? ""]
        )

        XCTAssertEqual(matchedID, imported.id)
    }

    func testCoordinatorPreviewsConfirmsAppliesAndRefreshesImportedSessions() throws {
        let file = SessionImportFile(
            sourceName: "sessions.csv",
            sourceType: .csv,
            contents: "csv-body"
        )
        let core = RecordingSessionImportCore(
            existingSessions: [makeRecord(name: "API", host: "api.example.com")],
            csvPreview: preview(
                sessions: [
                    previewSession(name: "API", host: "api.example.com", conflict: true),
                    previewSession(name: "Worker", host: "worker.example.com", conflict: false)
                ],
                conflictCount: 1
            ),
            applyResult: makeApplyResult(importedNames: ["Worker"], importedCount: 1, skippedCount: 1)
        )
        let presenter = RecordingSessionImportPresenter(confirmImport: true)
        var refreshCount = 0
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(file: file),
            presenter: presenter,
            core: core,
            onImported: { refreshCount += 1 }
        )

        let result = try coordinator.runImport(parentWindow: nil)

        XCTAssertEqual(result?.report.importedCount, 1)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(core.events, [
            "listAll",
            "previewCSV:sessions.csv",
            "apply:csv:sessions.csv"
        ])
        XCTAssertEqual(presenter.previewedSessionNames, ["API", "Worker"])
    }

    func testCoordinatorDoesNothingWhenFileSelectionIsCancelled() throws {
        let core = RecordingSessionImportCore()
        let presenter = RecordingSessionImportPresenter(confirmImport: true)
        var refreshCount = 0
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(file: nil),
            presenter: presenter,
            core: core,
            onImported: { refreshCount += 1 }
        )

        let result = try coordinator.runImport(parentWindow: nil)

        XCTAssertNil(result)
        XCTAssertEqual(core.events, [])
        XCTAssertEqual(refreshCount, 0)
    }

    func testCoordinatorDoesNotApplyWhenPreviewIsCancelled() throws {
        let core = RecordingSessionImportCore(
            csvPreview: preview(
                sessions: [previewSession(name: "Worker", host: "worker.example.com", conflict: false)]
            ),
            applyResult: makeApplyResult(importedNames: ["Worker"], importedCount: 1, skippedCount: 0)
        )
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(sourceName: "sessions.csv", sourceType: .csv, contents: "csv-body")
            ),
            presenter: RecordingSessionImportPresenter(confirmImport: false),
            core: core,
            onImported: {}
        )

        let result = try coordinator.runImport(parentWindow: nil)

        XCTAssertNil(result)
        XCTAssertEqual(core.events, ["listAll", "previewCSV:sessions.csv"])
    }

    func testCoordinatorReturnsVisibleNoChangeResultWhenEveryPreviewRowConflicts() throws {
        let skippedReport = ImportReport(
            id: "report_skipped",
            sourceType: "csv",
            sourceName: "sessions.csv",
            status: "skipped",
            importedCount: 0,
            skippedCount: 1,
            failedCount: 0,
            issues: ["API skipped because a session with the same name exists"],
            createdAt: "2026-05-31T00:00:00Z"
        )
        let core = RecordingSessionImportCore(
            existingSessions: [makeRecord(name: "API", host: "api.example.com")],
            csvPreview: preview(
                sessions: [previewSession(name: "API", host: "api.example.com", conflict: true)],
                conflictCount: 1
            ),
            applyResult: ImportApplyResult(report: skippedReport, importedSessions: [])
        )
        let presenter = RecordingSessionImportPresenter(confirmImport: true)
        var refreshCount = 0
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(sourceName: "sessions.csv", sourceType: .csv, contents: "csv-body")
            ),
            presenter: presenter,
            core: core,
            onImported: { refreshCount += 1 }
        )

        let result = try coordinator.runImport(parentWindow: nil)

        XCTAssertEqual(result?.report.status, "skipped")
        XCTAssertEqual(result?.report.importedCount, 0)
        XCTAssertEqual(result?.report.skippedCount, 1)
        XCTAssertEqual(result?.report.failedCount, 0)
        XCTAssertTrue(result?.report.issues.first?.contains("API") == true)
        XCTAssertEqual(core.events, [
            "listAll",
            "previewCSV:sessions.csv",
            "apply:csv:sessions.csv"
        ])
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(presenter.shownResults.map(\.report.status), ["skipped"])
    }

    func testCoordinatorPersistsSkippedReportWhenEveryPreviewRowConflicts() throws {
        let skippedReport = ImportReport(
            id: "persisted_skipped_report",
            sourceType: "csv",
            sourceName: "sessions.csv",
            status: "skipped",
            importedCount: 0,
            skippedCount: 1,
            failedCount: 0,
            issues: ["API skipped because a session with the same name exists"],
            createdAt: "2026-05-31T00:00:00Z"
        )
        let core = RecordingSessionImportCore(
            existingSessions: [makeRecord(name: "API", host: "api.example.com")],
            csvPreview: preview(
                sessions: [previewSession(name: "API", host: "api.example.com", conflict: true)],
                conflictCount: 1
            ),
            applyResult: ImportApplyResult(report: skippedReport, importedSessions: [])
        )
        let presenter = RecordingSessionImportPresenter(confirmImport: true)
        var refreshCount = 0
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(sourceName: "sessions.csv", sourceType: .csv, contents: "csv-body")
            ),
            presenter: presenter,
            core: core,
            onImported: { refreshCount += 1 }
        )

        let result = try coordinator.runImport(parentWindow: nil)

        XCTAssertEqual(result?.report, skippedReport)
        XCTAssertEqual(core.events, [
            "listAll",
            "previewCSV:sessions.csv",
            "apply:csv:sessions.csv"
        ])
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(presenter.shownResults.map(\.report.id), ["persisted_skipped_report"])
    }

    func testCoordinatorFallsBackToCSVWhenUnknownFileDoesNotLookLikeLegacyIni() throws {
        let core = RecordingSessionImportCore(
            csvPreview: preview(
                sessions: [previewSession(name: "Worker", host: "worker.example.com", conflict: false)]
            ),
            legacyIniPreview: preview(sessions: []),
            applyResult: makeApplyResult(importedNames: ["Worker"], importedCount: 1, skippedCount: 0)
        )
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(sourceName: "export.data", sourceType: .unknown, contents: "csv-body")
            ),
            presenter: RecordingSessionImportPresenter(confirmImport: true),
            core: core,
            onImported: {}
        )

        _ = try coordinator.runImport(parentWindow: nil)

        XCTAssertEqual(core.events, [
            "listAll",
            "previewStacioJSON:export.data",
            "previewLegacyIni:export.data",
            "previewCSV:export.data",
            "apply:csv:export.data"
        ])
    }

    func testCoordinatorExcludesRemovedFTPWhileKeepingSupportedLegacySessionsImportable() throws {
        let core = RecordingSessionImportCore(
            legacyIniPreview: preview(
                sessions: [
                    previewSession(name: "FTP 站点", protocol: "ftp", host: "ftp.example.com", port: 21),
                    previewSession(name: "VNC 控制台", protocol: "vnc", host: "bmc.example.com", port: 5900)
                ]
            ),
            applyResult: makeApplyResult(importedNames: ["VNC 控制台"], importedCount: 1, skippedCount: 0)
        )
        let presenter = RecordingSessionImportPresenter(confirmImport: true)
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(sourceName: "Legacy INI.ini", sourceType: .legacyINI, contents: "legacy-ini-body")
            ),
            presenter: presenter,
            core: core,
            onImported: {}
        )

        let result = try coordinator.runImport(parentWindow: nil)

        XCTAssertEqual(result?.report.importedCount, 1)
        XCTAssertEqual(presenter.previewedSessionNames, ["VNC 控制台"])
        XCTAssertEqual(core.appliedPreview?.sessions.map(\.protocol), ["vnc"])
        XCTAssertTrue(core.appliedPreview?.warnings.contains(where: {
            $0.contains("FTP") && $0.contains("SFTP")
        }) == true)
        XCTAssertEqual(core.events, [
            "listAll",
            "previewLegacyIni:Legacy INI.ini",
            "apply:legacy_ini:Legacy INI.ini"
        ])
    }

    func testCoordinatorRejectsImportContainingOnlyRemovedFTP() {
        let traceStore = FeedbackDiagnosticTraceStore(
            maxEvents: 16,
            ttl: 86_400,
            clock: Date.init,
            routeHashKey: Data(repeating: 0x42, count: 32)
        )
        let core = RecordingSessionImportCore(
            legacyIniPreview: preview(
                sessions: [
                    previewSession(
                        name: "FTP 站点",
                        protocol: "ftp",
                        host: "ftp.example.com",
                        port: 21
                    )
                ]
            )
        )
        let presenter = RecordingSessionImportPresenter(confirmImport: true)
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(
                    sourceName: "Legacy INI.ini",
                    sourceType: .legacyINI,
                    contents: "[Sessions]"
                )
            ),
            presenter: presenter,
            core: core,
            diagnosticTraceRecorder: traceStore
        )

        XCTAssertThrowsError(try coordinator.runImport(parentWindow: nil)) { error in
            XCTAssertEqual(error as? SessionImportRemovedProtocolError, .onlyRemovedFTP)
        }
        XCTAssertTrue(presenter.previewedSessionNames.isEmpty)
        XCTAssertNil(core.appliedPreview)
        XCTAssertEqual(traceStore.snapshot().events.last?.stage, .preview)
        XCTAssertEqual(traceStore.snapshot().events.last?.result, .failed)
        XCTAssertEqual(traceStore.snapshot().events.last?.errorCode, "preview_failed")
    }

    func testCoordinatorAppliesStacioJSONPreviewForExportedGroups() throws {
        let core = RecordingSessionImportCore(
            jsonPreview: preview(
                sessions: [
                    previewSession(
                        name: "Primary DB",
                        protocol: "ssh",
                        host: "db.example.com",
                        port: 22
                    )
                ]
            ),
            applyResult: makeApplyResult(importedNames: ["Primary DB"], importedCount: 1, skippedCount: 0)
        )
        let presenter = RecordingSessionImportPresenter(confirmImport: true)
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(
                    sourceName: "Production Sessions.json",
                    sourceType: .stacioJSON,
                    contents: "json-body"
                )
            ),
            presenter: presenter,
            core: core,
            onImported: {}
        )

        let result = try coordinator.runImport(parentWindow: nil)

        XCTAssertEqual(result?.report.importedCount, 1)
        XCTAssertEqual(presenter.previewedSessionNames, ["Primary DB"])
        XCTAssertEqual(core.events, [
            "listAll",
            "previewStacioJSON:Production Sessions.json",
            "apply:stacio_json:Production Sessions.json"
        ])
    }

    func testCoordinatorImportsEncryptedSingleSessionAndRestoresCredentialAndPrivateKey() throws {
        let session = makeRecord(name: "API", host: "api.example.com")
        let sessionJSON = try SessionSidebarSingleSessionExport.jsonString(for: session, configJSON: nil)
        let transfer = SecureSessionTransferPayload(
            sessionJSON: sessionJSON,
            metadata: SecureSessionTransferSessionMetadata(
                name: "API",
                protocolName: "ssh",
                host: "api.example.com",
                port: 22,
                username: "deploy"
            ),
            credential: SecureSessionTransferCredential(kind: .privateKeyPassphrase, secret: "key-passphrase"),
            privateKey: SecureSessionTransferPrivateKey(
                fileName: "id_ed25519",
                contents: Data("private-key-material".utf8)
            )
        )
        let encrypted = try SecureSessionTransfer.encrypt(transfer, passphrase: "migration-passphrase")
        let core = RecordingSessionImportCore(
            jsonPreview: preview(sessions: [previewSession(name: "API", host: "api.example.com", conflict: false)]),
            applyResult: makeApplyResult(importedNames: ["API"], importedCount: 1, skippedCount: 0)
        )
        let credentialApplier = RecordingExternalSessionCredentialApplier()
        let privateKeyInstaller = RecordingSecureSessionTransferPrivateKeyInstaller()
        let passphrasePrompter = RecordingSecureSessionTransferPassphrasePrompter(importPassphrase: "migration-passphrase")
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(
                    sourceName: "API.stacio-session",
                    sourceType: .stacioJSON,
                    contents: encrypted
                )
            ),
            presenter: RecordingSessionImportPresenter(confirmImport: true),
            core: core,
            credentialApplier: credentialApplier,
            secureSessionTransferPassphrasePrompter: passphrasePrompter,
            importedPrivateKeyInstaller: privateKeyInstaller
        )

        let result = try coordinator.runImport(parentWindow: nil)

        XCTAssertEqual(result?.report.importedCount, 1)
        XCTAssertEqual(passphrasePrompter.importedSourceNames, ["API.stacio-session"])
        XCTAssertEqual(core.events, [
            "listAll",
            "previewStacioJSON:API.stacio-session",
            "apply:stacio_json:API.stacio-session"
        ])
        XCTAssertEqual(core.stacioJSONInputs, [sessionJSON])
        XCTAssertEqual(credentialApplier.appliedPayload?.sessions.first?.credential, .privateKeyPassphrase("key-passphrase"))
        XCTAssertEqual(privateKeyInstaller.installedPrivateKeys.map(\.fileName), ["id_ed25519"])
        XCTAssertEqual(privateKeyInstaller.installedSessionIDs, ["session_api"])
    }

    func testCoordinatorRejectsEncryptedSessionWithWrongMigrationPassphrase() throws {
        let transfer = SecureSessionTransferPayload(
            sessionJSON: "{}",
            metadata: SecureSessionTransferSessionMetadata(
                name: "API",
                protocolName: "ssh",
                host: "api.example.com",
                port: 22,
                username: "deploy"
            ),
            credential: nil,
            privateKey: nil
        )
        let encrypted = try SecureSessionTransfer.encrypt(transfer, passphrase: "correct-passphrase")
        let core = RecordingSessionImportCore()
        let coordinator = SessionImportCoordinator(
            databasePath: "/tmp/Stacio.sqlite",
            filePicker: RecordingSessionImportFilePicker(
                file: SessionImportFile(
                    sourceName: "API.stacio-session",
                    sourceType: .genericJSON,
                    contents: encrypted
                )
            ),
            presenter: RecordingSessionImportPresenter(confirmImport: true),
            core: core,
            secureSessionTransferPassphrasePrompter: RecordingSecureSessionTransferPassphrasePrompter(
                importPassphrase: "wrong-passphrase"
            )
        )

        XCTAssertThrowsError(try coordinator.runImport(parentWindow: nil)) { error in
            XCTAssertEqual(error as? SecureSessionTransferError, .decryptionFailed)
        }
        XCTAssertEqual(core.events, [])
    }

    func testImportPreviewMessageUsesChineseSourceTypeLabel() {
        let message = L10n.Import.previewMessage(
            sourceName: "sessions.csv",
            sourceType: .csv,
            importableCount: 1,
            conflictCount: 0
        )

        XCTAssertTrue(message.contains("CSV 文件"))
        XCTAssertFalse(message.contains(" - csv。"))
    }

    func testImportErrorsUseChineseMessagesWithoutExposingBindingTypeNames() {
        let invalidSession = AppKitSessionImportPreviewPresenter.errorMessageForTesting(
            SessionError.InvalidQuickConnect
        )
        let invalidFormat = AppKitSessionImportPreviewPresenter.errorMessageForTesting(
            ExternalSessionImportParserError.invalidFormat
        )
        let credentialFailure = AppKitSessionImportPreviewPresenter.errorMessageForTesting(
            KeychainCredentialError.accessDenied(-25_293)
        )
        let unexpectedFailure = AppKitSessionImportPreviewPresenter.errorMessageForTesting(
            NSError(
                domain: "InternalImportSubsystem",
                code: 41,
                userInfo: [NSLocalizedDescriptionKey: "sensitive implementation detail"]
            )
        )

        XCTAssertEqual(invalidSession, L10n.Import.invalidSessionData)
        XCTAssertEqual(invalidFormat, "无法识别配置文件内容，请确认文件为来源系统导出的原始配置。")
        XCTAssertEqual(credentialFailure, L10n.Import.credentialStorageFailure)
        XCTAssertEqual(unexpectedFailure, L10n.Import.genericFailure)
        XCTAssertFalse(invalidSession.contains("StacioCoreBindings"))
        XCTAssertFalse(invalidFormat.contains("ExternalSessionImportParserError"))
        XCTAssertFalse(credentialFailure.contains("KeychainCredentialError"))
        XCTAssertFalse(unexpectedFailure.contains("InternalImportSubsystem"))
        XCTAssertFalse(unexpectedFailure.contains("sensitive implementation detail"))
    }

    func testImportPreviewTextShowsNonSSHProtocolsAndTargets() {
        let preview = preview(
            sessions: [
                previewSession(name: "FTP 站点", protocol: "ftp", host: "ftp.example.com", port: 21),
                previewSession(name: "Telnet 控制台", protocol: "telnet", host: "10.0.0.20", port: 23),
                previewSession(name: "VNC 控制台", protocol: "vnc", host: "bmc.example.com", port: 5900)
            ]
        )

        let text = AppKitSessionImportPreviewPresenter.previewTextForTesting(preview)

        XCTAssertTrue(text.contains("名称\t文件夹\t协议\t目标\t状态"))
        XCTAssertTrue(text.contains("FTP 站点\tProduction\tFTP\tdeploy@ftp.example.com:21\t新增"))
        XCTAssertTrue(text.contains("Telnet 控制台\tProduction\tTelnet\tdeploy@10.0.0.20:23\t新增"))
        XCTAssertTrue(text.contains("VNC 控制台\tProduction\tVNC\tdeploy@bmc.example.com:5900\t新增"))
        XCTAssertFalse(text.contains("SSH\tdeploy@ftp.example.com:21"))
    }

    func testImportPreviewTextRedactsSensitiveWarnings() {
        let preview = preview(
            sessions: [previewSession(name: "API", host: "api.example.com", conflict: false)],
            warnings: [
                "已忽略 password=hunter2、secret=token123、private key=/Users/me/.ssh/id_rsa"
            ]
        )

        let text = AppKitSessionImportPreviewPresenter.previewTextForTesting(preview)

        XCTAssertTrue(text.contains("已隐藏敏感字段"))
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains("token123"))
        XCTAssertFalse(text.contains("id_rsa"))
    }

    func testImportPreviewTextRedactsTokensApiKeysAndPrivateKeyPathsInWarnings() {
        let preview = preview(
            sessions: [previewSession(name: "API", host: "api.example.com", conflict: false)],
            warnings: [
                "已忽略 token=def",
                "已忽略 api_key=ghi",
                "已忽略 /Users/mac/.ssh/id_rsa"
            ]
        )

        let text = AppKitSessionImportPreviewPresenter.previewTextForTesting(preview)

        XCTAssertTrue(text.contains("已隐藏敏感字段"))
        XCTAssertFalse(text.contains("def"))
        XCTAssertFalse(text.contains("ghi"))
        XCTAssertFalse(text.contains("/Users/mac/.ssh/id_rsa"))
        XCTAssertFalse(text.contains("id_rsa"))
    }

    func testImportPreviewSheetRendersReadableNativeTableWithBastionTargetAndRedactedWarnings() throws {
        let longName = "天融信堡垒机导出的生产数据库服务器会话名称非常长需要截断显示"
        let configJSON = """
        {"bastionVendor":"topsec","bastionTargetHost":"10.20.30.40","bastionTargetPort":2222,"bastionTargetUsername":"dbadmin"}
        """
        let preview = preview(
            sessions: [
                previewSession(
                    name: longName,
                    protocol: "ssh",
                    host: "192.0.2.10",
                    port: 22,
                    conflict: true,
                    username: "SSH@dbadmin@10.20.30.40@internal-account-id",
                    configJSON: configJSON
                ),
                previewSession(name: "Worker", protocol: "ftp", host: "worker.example.com", port: 21)
            ],
            warnings: [
                "第一行普通警告",
                "已忽略 password=hunter2、secret=token123、private key=/Users/me/.ssh/id_rsa"
            ],
            conflictCount: 1
        )

        let controller = AppKitSessionImportPreviewPresenter.previewWindowControllerForTesting(
            preview,
            message: "长文件名 sessions-20260724-production-export.stacio-bastion\n请核对目标与警告后导入"
        )
        let window: NSWindow = try XCTUnwrap(controller.window)
        let contentView: NSView = try XCTUnwrap(window.contentView)
        window.appearance = NSAppearance(named: .darkAqua)
        contentView.layoutSubtreeIfNeeded()
        let scrollView: NSScrollView = try XCTUnwrap(contentView.firstSubview(ofType: NSScrollView.self))
        let tableView: NSTableView = try XCTUnwrap(contentView.firstSubview(ofType: NSTableView.self))
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()

        XCTAssertEqual(tableView.tableColumns.map { $0.title }, ["名称", "文件夹", "协议", "目标", "状态", "警告"])
        XCTAssertEqual(tableView.numberOfRows, 2)
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.width, 760)
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.height, 460)
        XCTAssertFalse(tableView.usesAlternatingRowBackgroundColors)
        XCTAssertEqual(tableView.backgroundColor, NSColor.clear)
        XCTAssertEqual(scrollView.hasHorizontalScroller, false)
        XCTAssertEqual(scrollView.borderType, NSBorderType.bezelBorder)
        XCTAssertLessThanOrEqual(
            tableView.tableColumns.reduce(CGFloat(0)) { $0 + $1.width },
            scrollView.contentSize.width + 1
        )
        XCTAssertEqual(
            contentView.effectiveAppearance.bestMatch(from: [NSAppearance.Name.darkAqua, .aqua]),
            NSAppearance.Name.darkAqua
        )
        XCTAssertEqual(tableView.stringValue(row: 0, column: "name"), longName)
        XCTAssertEqual(tableView.toolTip(row: 0, column: "name"), longName)
        XCTAssertEqual(tableView.stringValue(row: 0, column: "status"), "冲突")
        XCTAssertEqual(tableView.stringValue(row: 1, column: "protocol"), "FTP")
        XCTAssertEqual(tableView.stringValue(row: 1, column: "target"), "deploy@worker.example.com:21")
        let bastionTarget = tableView.stringValue(row: 0, column: "target")
        XCTAssertEqual(bastionTarget, "dbadmin@10.20.30.40:2222\n经由 192.0.2.10:22")
        XCTAssertFalse(bastionTarget.contains("internal-account-id"))

        let warningText = tableView.stringValue(row: 0, column: "warnings")
        XCTAssertTrue(warningText.contains("第一行普通警告"))
        XCTAssertTrue(warningText.contains("已隐藏敏感字段"))
        XCTAssertFalse(warningText.contains("hunter2"))
        XCTAssertFalse(warningText.contains("token123"))
        XCTAssertFalse(warningText.contains("id_rsa"))

        let importButton = try XCTUnwrap(
            contentView.firstSubview(accessibilityIdentifier: "Stacio.ImportPreview.import") as? NSButton
        )
        let cancelButton = try XCTUnwrap(
            contentView.firstSubview(accessibilityIdentifier: "Stacio.ImportPreview.cancel") as? NSButton
        )
        XCTAssertTrue(contentView.bounds.contains(importButton.frame))
        XCTAssertTrue(contentView.bounds.contains(cancelButton.frame))
        XCTAssertGreaterThan(importButton.frame.minY, 0)
    }

    func testImportPreviewSheetClampsToSmallVisibleScreenWithoutHidingFooter() {
        let availableSize = NSSize(width: 760, height: 480)

        let contentSize = AppKitSessionImportPreviewPresenter.previewContentSizeForTesting(
            availableSize: availableSize
        )

        XCTAssertLessThanOrEqual(contentSize.width, availableSize.width)
        XCTAssertLessThanOrEqual(contentSize.height, availableSize.height)
        XCTAssertGreaterThanOrEqual(contentSize.height, 360)
    }
}

private final class RecordingSessionImportFilePicker: SessionImportFilePicking {
    private let file: SessionImportFile?

    init(file: SessionImportFile?) {
        self.file = file
    }

    func pickImportFile(parentWindow: NSWindow?) throws -> SessionImportFile? {
        file
    }
}

private final class RecordingSourceAwareSessionImportFilePicker: SessionImportFilePicking {
    private let file: SessionImportFile?
    private(set) var requestedSourceTypes: [SessionImportSourceType] = []

    init(file: SessionImportFile?) { self.file = file }

    func pickImportFile(parentWindow: NSWindow?) throws -> SessionImportFile? { file }

    func pickImportFile(
        sourceType: SessionImportSourceType,
        parentWindow: NSWindow?
    ) throws -> SessionImportFile? {
        requestedSourceTypes.append(sourceType)
        return file
    }
}

private final class RecordingSessionImportPresenter: SessionImportPreviewPresenting {
    private let confirmImport: Bool
    private(set) var previewedSessionNames: [String] = []
    private(set) var previewedSessions: [ImportSessionPreview] = []
    private(set) var previewedConfigJSON: [String] = []
    private(set) var shownResults: [ImportApplyResult] = []
    private(set) var shownErrors: [Error] = []

    init(confirmImport: Bool) {
        self.confirmImport = confirmImport
    }

    func confirmImport(
        preview: ImportPreview,
        sourceName: String,
        sourceType: SessionImportSourceType,
        parentWindow: NSWindow?
    ) -> Bool {
        previewedSessions = preview.sessions
        previewedSessionNames = preview.sessions.map(\.name)
        previewedConfigJSON = preview.sessions.compactMap(\.configJson)
        return confirmImport
    }

    func showImportResult(_ result: ImportApplyResult, parentWindow: NSWindow?) {
        shownResults.append(result)
    }

    func showImportError(_ error: Error, parentWindow: NSWindow?) {
        shownErrors.append(error)
    }
}

private struct RecordingLicenseFeatureAccessProvider: LicenseFeatureAccessProviding {
    let enabled: Bool

    func isEnabled(_ feature: StacioLicensedFeature) -> Bool {
        enabled
    }
}

private final class RecordingSessionImportCore: SessionImportCoreBridging {
    var events: [String] = []
    private(set) var stacioJSONInputs: [String] = []
    private(set) var appliedPreview: ImportPreview?
    private let existingSessions: [SessionRecord]
    private let csvPreview: ImportPreview
    private let legacyIniPreview: ImportPreview
    private let jsonPreview: ImportPreview
    private let applyResult: ImportApplyResult
    private let configJSONBySessionID: [String: String]

    init(
        existingSessions: [SessionRecord] = [],
        csvPreview: ImportPreview = preview(sessions: []),
        legacyIniPreview: ImportPreview = preview(sessions: []),
        jsonPreview: ImportPreview = preview(sessions: []),
        applyResult: ImportApplyResult = makeApplyResult(importedNames: [], importedCount: 0, skippedCount: 0),
        configJSONBySessionID: [String: String] = [:]
    ) {
        self.existingSessions = existingSessions
        self.csvPreview = csvPreview
        self.legacyIniPreview = legacyIniPreview
        self.jsonPreview = jsonPreview
        self.applyResult = applyResult
        self.configJSONBySessionID = configJSONBySessionID
    }

    func listAllSessionRecords(databasePath: String) throws -> [SessionRecord] {
        events.append("listAll")
        return existingSessions
    }

    func sessionConfigJSON(databasePath: String, id: String) throws -> String? {
        configJSONBySessionID[id]
    }

    func previewCSVImport(
        _ input: String,
        sourceName: String,
        existingSessionNames: [String]
    ) throws -> ImportPreview {
        events.append("previewCSV:\(sourceName)")
        return csvPreview
    }

    func previewLegacyIniImport(
        _ input: String,
        sourceName: String,
        existingSessionNames: [String]
    ) throws -> ImportPreview {
        events.append("previewLegacyIni:\(sourceName)")
        return legacyIniPreview
    }

    func previewStacioJSONImport(
        _ input: String,
        sourceName: String,
        existingSessionNames: [String]
    ) throws -> ImportPreview {
        events.append("previewStacioJSON:\(sourceName)")
        stacioJSONInputs.append(input)
        return jsonPreview
    }

    func applySessionImport(
        databasePath: String,
        sourceType: SessionImportSourceType,
        sourceName: String,
        preview: ImportPreview
    ) throws -> ImportApplyResult {
        events.append("apply:\(sourceType.rawValue):\(sourceName)")
        appliedPreview = preview
        return applyResult
    }
}

private final class RecordingExternalSessionCredentialApplier: ExternalSessionCredentialApplying {
    private(set) var appliedPayload: ExternalSessionImportPayload?
    private(set) var appliedSessions: [SessionRecord] = []
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func applyCredentials(
        from payload: ExternalSessionImportPayload,
        to importedSessions: [SessionRecord],
        databasePath: String
    ) throws {
        if let error { throw error }
        appliedPayload = payload
        appliedSessions = importedSessions
    }
}

private final class RecordingBastionHostFeatureAuthorizer: BastionHostFeatureAuthorizing {
    private let error: BastionHostFeatureAccessError?
    private(set) var authorizationCount = 0

    init(error: BastionHostFeatureAccessError? = nil) {
        self.error = error
    }

    func authorizeBastionHostAccess() throws {
        authorizationCount += 1
        if let error { throw error }
    }
}

private final class RecordingBastionHostSessionImportResolver: BastionHostSessionImportResolving {
    private let fallbackPayload: ExternalSessionImportPayload?
    private let automaticallyResolvedPayload: ExternalSessionImportPayload?
    private(set) var vendorHints: [BastionHostVendor?] = []

    init(
        fallbackPayload: ExternalSessionImportPayload?,
        automaticallyResolvedPayload: ExternalSessionImportPayload? = nil
    ) {
        self.fallbackPayload = fallbackPayload
        self.automaticallyResolvedPayload = automaticallyResolvedPayload
    }

    func resolve(
        file: SessionImportFile,
        vendorHint: BastionHostVendor?
    ) throws -> ExternalSessionImportPayload {
        vendorHints.append(vendorHint)
        if vendorHint == nil, let automaticallyResolvedPayload {
            return automaticallyResolvedPayload
        }
        guard vendorHint != nil, let fallbackPayload else {
            throw ExternalSessionImportParserError.invalidFormat
        }
        return fallbackPayload
    }
}

private final class RecordingBastionHostVendorSelector: BastionHostVendorSelecting {
    private let selectedVendor: BastionHostVendor?
    private(set) var requestedSourceNames: [String] = []

    init(selectedVendor: BastionHostVendor?) {
        self.selectedVendor = selectedVendor
    }

    func selectVendor(sourceName: String, parentWindow: NSWindow?) -> BastionHostVendor? {
        requestedSourceNames.append(sourceName)
        return selectedVendor
    }
}

private final class RecordingSecureSessionTransferPassphrasePrompter: SecureSessionTransferPassphrasePrompting {
    private let importPassphrase: String?
    private(set) var importedSourceNames: [String] = []

    init(importPassphrase: String?) {
        self.importPassphrase = importPassphrase
    }

    func promptForExportPassphrase(sessionName: String, parentWindow: NSWindow?) -> String? {
        nil
    }

    func promptForImportPassphrase(sourceName: String, parentWindow: NSWindow?) -> String? {
        importedSourceNames.append(sourceName)
        return importPassphrase
    }
}

private final class RecordingSecureSessionTransferPrivateKeyInstaller: SecureSessionTransferPrivateKeyInstalling {
    private(set) var installedPrivateKeys: [SecureSessionTransferPrivateKey] = []
    private(set) var installedSessionIDs: [String] = []

    func install(
        _ privateKey: SecureSessionTransferPrivateKey,
        for importedSession: SessionRecord,
        databasePath: String
    ) throws {
        installedPrivateKeys.append(privateKey)
        installedSessionIDs.append(importedSession.id)
    }
}

private func makeSessionImportArchive(entries: [String: Data]) throws -> URL {
    let archive = try Archive(accessMode: .create)
    for (path, data) in entries.sorted(by: { $0.key < $1.key }) {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            provider: { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        )
    }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("zip")
    try XCTUnwrap(archive.data).write(to: url)
    return url
}

private func preview(
    sessions: [ImportSessionPreview],
    warnings: [String] = [],
    conflictCount: UInt32 = 0
) -> ImportPreview {
    ImportPreview(
        sessions: sessions,
        warnings: warnings,
        conflictCount: conflictCount,
        ignoredSecretFieldCount: 0
    )
}

private extension NSView {
    func firstSubview<View: NSView>(ofType type: View.Type) -> View? {
        if let view = self as? View {
            return view
        }
        for subview in subviews {
            if let match = subview.firstSubview(ofType: type) {
                return match
            }
        }
        return nil
    }

    func firstSubview(accessibilityIdentifier: String) -> NSView? {
        if self.accessibilityIdentifier() == accessibilityIdentifier {
            return self
        }
        for subview in subviews {
            if let match = subview.firstSubview(accessibilityIdentifier: accessibilityIdentifier) {
                return match
            }
        }
        return nil
    }
}

private extension NSTableView {
    func stringValue(row: Int, column identifier: String) -> String {
        guard let columnIndex = tableColumns.firstIndex(where: { $0.identifier.rawValue == identifier }),
              let view = view(atColumn: columnIndex, row: row, makeIfNecessary: true) as? NSTableCellView
        else {
            return ""
        }
        return view.textField?.stringValue ?? ""
    }

    func toolTip(row: Int, column identifier: String) -> String? {
        guard let columnIndex = tableColumns.firstIndex(where: { $0.identifier.rawValue == identifier }),
              let view = view(atColumn: columnIndex, row: row, makeIfNecessary: true) as? NSTableCellView
        else {
            return nil
        }
        return view.textField?.toolTip
    }
}

private func previewSession(
    name: String,
    host: String,
    conflict: Bool
) -> ImportSessionPreview {
    previewSession(name: name, protocol: "ssh", host: host, port: 22, conflict: conflict)
}

private func previewSession(
    name: String,
    protocol: String,
    host: String,
    port: UInt16,
    conflict: Bool = false,
    username: String? = "deploy",
    configJSON: String? = nil
) -> ImportSessionPreview {
    ImportSessionPreview(
        name: name,
        folder: "Production",
        protocol: `protocol`,
        host: host,
        port: port,
        username: username,
        privateKeyPath: nil,
        configJson: configJSON,
        conflict: conflict
    )
}

private func externalBastionSession(
    name: String,
    targetHost: String,
    targetUsername: String = "dbadmin",
    credential: ExternalImportedCredential? = nil
) -> ExternalImportedSession {
    let configJSON = """
    {"bastionVendor":"topsec","bastionTargetHost":"\(targetHost)","bastionTargetPort":22,"bastionTargetUsername":"\(targetUsername)"}
    """
    return ExternalImportedSession(
        name: name,
        folderPath: nil,
        protocolName: "ssh",
        host: "bastion.example.com",
        port: 2222,
        username: "opaque@default@SSH@\(targetUsername)@\(targetHost)@22",
        privateKeyPath: nil,
        credential: credential,
        configJSON: configJSON
    )
}

private func makeApplyResult(
    importedNames: [String],
    importedCount: UInt32,
    skippedCount: UInt32
) -> ImportApplyResult {
    ImportApplyResult(
        report: ImportReport(
            id: "report_1",
            sourceType: "csv",
            sourceName: "sessions.csv",
            status: skippedCount > 0 ? "partial" : "imported",
            importedCount: importedCount,
            skippedCount: skippedCount,
            failedCount: 0,
            issues: [],
            createdAt: "2026-05-28T00:00:00Z"
        ),
        importedSessions: importedNames.map { makeRecord(name: $0, host: "\($0.lowercased()).example.com") }
    )
}

private func makeRecord(name: String, host: String) -> SessionRecord {
    SessionRecord(
        id: "session_\(name.lowercased())",
        folderId: nil,
        name: name,
        protocol: "ssh",
        host: host,
        port: 22,
        username: "deploy",
        privateKeyPath: nil,
        credentialId: nil,
        tags: [],
        lastOpenedAt: nil
    )
}
