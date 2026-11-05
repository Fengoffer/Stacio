import Foundation
import XCTest
@testable import StacioApp

final class LocalAgentConfigurationStoreTests: XCTestCase {
    func testEncryptedRoundTripPublishesVerifiedPassthroughConfiguration() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let saved = try fixture.store.save(
            makeRecord(fixture: fixture, configurationID: "local-agent-config-1"),
            expectedRevision: nil
        )
        XCTAssertEqual(saved.configurationRevision, 1)
        XCTAssertEqual(try fixture.store.records(), [saved])
        XCTAssertEqual(
            try fixture.store.snapshot(configurationID: saved.configurationID)?.state,
            "active"
        )

        let sidecar = try String(contentsOf: fixture.sidecarURL, encoding: .utf8)
        XCTAssertFalse(sidecar.contains(saved.executablePath))
        XCTAssertFalse(sidecar.contains(saved.userDisplayName))
        XCTAssertFalse(sidecar.contains(saved.detectedVersion))

        let reopened = try LocalAgentConfigurationStore(
            backend: ConfigurationStoreBackend(databasePath: fixture.databaseURL.path),
            fileURL: fixture.sidecarURL,
            masterKeyProvider: fixture.masterKey,
            catalog: fixture.catalog,
            environment: { fixture.environment },
            homeDirectory: { fixture.homeDirectory }
        )
        let resolver = makeResolver(fixture: fixture, store: reopened)
        let configuration = try XCTUnwrap(resolver.passthroughConfiguration(for: .codex))
        XCTAssertEqual(configuration.configurationRevision, 1)
        XCTAssertEqual(configuration.executablePath, fixture.executableURL.path)
        XCTAssertEqual(configuration.authenticationState, .authenticated)
        XCTAssertEqual(configuration.launchArguments, ["--no-alt-screen"])
        XCTAssertTrue(configuration.launchEnvironment.contains("LANG=zh_CN.UTF-8"))
        XCTAssertFalse(configuration.launchEnvironment.contains { $0.hasPrefix("ACCESS_TOKEN=") })
        XCTAssertEqual(
            LocalAgentConfigurationIntegrity.environmentDigest(configuration.launchEnvironment),
            configuration.environmentDigest
        )
    }

    func testAskEveryTurnRoundTripRequiresNoPersistedDirectoryReference() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let record = replacingWorkingDirectory(
            makeRecord(fixture: fixture, configurationID: "local-agent-ask-every-turn"),
            mode: .askEveryTurn,
            reference: nil
        )

        let saved = try fixture.store.save(record, expectedRevision: nil)
        XCTAssertEqual(saved.workingDirectoryMode, .askEveryTurn)
        XCTAssertNil(saved.workingDirectoryReference)

        let reopened = try reopenStore(fixture)
        let restored = try XCTUnwrap(
            reopened.record(configurationID: saved.configurationID)
        )
        XCTAssertEqual(restored.workingDirectoryMode, .askEveryTurn)
        XCTAssertNil(restored.workingDirectoryReference)
        XCTAssertNotNil(
            makeResolver(fixture: fixture, store: reopened)
                .passthroughConfiguration(for: .codex)
        )
    }

    func testNeedsLoginEvidenceIsPersistedAndCannotBecomeRunnable() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let record = replacing(
            makeRecord(fixture: fixture, configurationID: "local-agent-needs-login"),
            authenticationState: .needsLogin
        )
        let saved = try fixture.store.save(record, expectedRevision: nil)
        XCTAssertEqual(saved.authenticationState, .needsLogin)
        XCTAssertNil(
            makeResolver(fixture: fixture, store: fixture.store)
                .passthroughConfiguration(for: .codex)
        )
    }

    func testDeleteUsesRevisionCASRemovesSidecarValueAndPublishesAudit() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let saved = try fixture.store.save(
            makeRecord(fixture: fixture, configurationID: "local-agent-delete"),
            expectedRevision: nil,
            operationID: "op-create",
            eventID: "event-create"
        )

        XCTAssertThrowsError(try fixture.store.delete(
            configurationID: saved.configurationID,
            expectedRevision: 0,
            operationID: "op-stale-delete",
            eventID: "event-stale-delete"
        )) { error in
            XCTAssertEqual(
                error as? LocalAgentConfigurationStoreError,
                .staleRevision(expected: 0, actual: 1)
            )
        }
        XCTAssertEqual(try fixture.store.record(configurationID: saved.configurationID), saved)

        let deletedRevision = try fixture.store.delete(
            configurationID: saved.configurationID,
            expectedRevision: 1,
            operationID: "op-delete",
            eventID: "event-delete"
        )
        XCTAssertEqual(deletedRevision, 2)
        XCTAssertNil(try fixture.store.record(configurationID: saved.configurationID))
        XCTAssertTrue(try fixture.store.records().isEmpty)
        let snapshot = try fixture.store.snapshot(configurationID: saved.configurationID)
        XCTAssertEqual(snapshot?.revision, 2)
        XCTAssertEqual(snapshot?.state, "deleted")
        let backend = try ConfigurationStoreBackend(databasePath: fixture.databaseURL.path)
        XCTAssertEqual(
            try backend.eventsByOperation(operationID: "op-delete"),
            ["configurationDeletionCommitted", "configurationDeleted"]
        )
        let sidecar = try String(contentsOf: fixture.sidecarURL, encoding: .utf8)
        XCTAssertFalse(sidecar.contains(saved.configurationID))

        let reopened = try reopenStore(fixture)
        XCTAssertTrue(try reopened.records().isEmpty)
    }

    func testStaleStoreRefreshesSidecarBeforeMutationAndCannotOverwriteNewerRevision() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let revisionOne = try fixture.store.save(
            makeRecord(fixture: fixture, configurationID: "local-agent-concurrent"),
            expectedRevision: nil,
            operationID: "op-one",
            eventID: "event-one"
        )
        let staleStore = try reopenStore(fixture)
        let revisionTwo = try fixture.store.save(
            revisionOne,
            expectedRevision: 1,
            operationID: "op-two",
            eventID: "event-two"
        )
        let sidecarBeforeStaleMutation = try Data(contentsOf: fixture.sidecarURL)

        XCTAssertThrowsError(try staleStore.delete(
            configurationID: revisionOne.configurationID,
            expectedRevision: 1,
            operationID: "op-stale",
            eventID: "event-stale"
        )) { error in
            XCTAssertEqual(
                error as? LocalAgentConfigurationStoreError,
                .staleRevision(expected: 1, actual: 2)
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.sidecarURL), sidecarBeforeStaleMutation)
        XCTAssertEqual(
            try staleStore.record(configurationID: revisionOne.configurationID),
            revisionTwo
        )
    }

    func testExecutableReplacementFailsClosedWithoutPATHFallback() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.store.save(
            makeRecord(fixture: fixture, configurationID: "local-agent-config-1"),
            expectedRevision: nil
        )
        let resolver = makeResolver(
            fixture: fixture,
            store: fixture.store,
            allowsLegacyPathDiscovery: true
        )
        XCTAssertNotNil(resolver.passthroughConfiguration(for: .codex))

        try Data("#!/bin/sh\necho replaced\n".utf8).write(to: fixture.executableURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: fixture.executableURL.path
        )

        XCTAssertNil(resolver.passthroughConfiguration(for: .codex))
        XCTAssertEqual(
            resolver.executablePath(for: .codex),
            nil,
            "An invalid persisted authority must not silently become a PATH-discovered launch"
        )
        let compatibilityResolver = makeResolver(
            fixture: fixture,
            store: fixture.store,
            environment: fixture.environment.merging(["PATH": fixture.root.path]) { _, new in new },
            allowsLegacyPathDiscovery: true
        )
        XCTAssertNil(
            compatibilityResolver.legacyExecutablePath(for: .codex),
            "A persisted but invalid authority must not be bypassed through compatibility mode"
        )
    }

    func testCompatibilityPathDiscoveryRequiresNoDurableRecord() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let resolver = makeResolver(
            fixture: fixture,
            store: fixture.store,
            environment: fixture.environment.merging(["PATH": fixture.root.path]) { _, new in new },
            allowsLegacyPathDiscovery: true
        )

        XCTAssertNil(resolver.executablePath(for: .codex))
        XCTAssertNil(resolver.passthroughConfiguration(for: .codex))
        XCTAssertEqual(resolver.legacyExecutablePath(for: .codex), fixture.executableURL.path)
    }

    func testDisabledMigrationRecordKeepsExplicitLegacyCompatibilityPath() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.store.save(
            makeRecord(
                fixture: fixture,
                configurationID: "local-agent-migrated",
                explicitlyEnabled: false
            ),
            expectedRevision: nil
        )
        let resolver = makeResolver(
            fixture: fixture,
            store: fixture.store,
            environment: fixture.environment.merging(["PATH": fixture.root.path]) { _, new in new },
            allowsLegacyPathDiscovery: true
        )

        XCTAssertNil(resolver.passthroughConfiguration(for: .codex))
        XCTAssertEqual(resolver.legacyExecutablePath(for: .codex), fixture.executableURL.path)
    }

    func testRuntimeModeNeverFallsBackToPATHWhenDurableStoreIsUnavailable() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let environment = ["PATH": fixture.root.path]

        let discoveryResolver = LocalAgentToolResolver(
            environment: environment,
            homeDirectory: fixture.homeDirectory,
            catalog: fixture.catalog
        )
        XCTAssertEqual(discoveryResolver.executablePath(for: .codex), fixture.executableURL.path)

        let runtimeResolver = LocalAgentToolResolver(
            environment: environment,
            homeDirectory: fixture.homeDirectory,
            catalog: fixture.catalog,
            configurationStore: nil,
            allowsPathDiscovery: false,
            allowsLegacyPathDiscovery: true
        )
        XCTAssertNil(runtimeResolver.executablePath(for: .codex))
        XCTAssertNil(runtimeResolver.passthroughConfiguration(for: .codex))
        XCTAssertEqual(
            runtimeResolver.legacyExecutablePath(for: .codex),
            fixture.executableURL.path,
            "The explicit compatibility API may discover PATH without becoming V2 authority"
        )
    }

    func testEnvironmentChangeRequiresReverification() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.store.save(
            makeRecord(fixture: fixture, configurationID: "local-agent-config-1"),
            expectedRevision: nil
        )
        var changed = fixture.environment
        changed["LANG"] = "en_US.UTF-8"
        let resolver = LocalAgentToolResolver(
            environment: changed,
            homeDirectory: fixture.homeDirectory,
            catalog: fixture.catalog,
            configurationStore: fixture.store
        )

        XCTAssertNil(resolver.passthroughConfiguration(for: .codex))
    }

    func testMultipleEnabledProfilesAreAmbiguousAndFailClosed() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.store.save(
            makeRecord(fixture: fixture, configurationID: "local-agent-config-1"),
            expectedRevision: nil
        )
        _ = try fixture.store.save(
            makeRecord(fixture: fixture, configurationID: "local-agent-config-2"),
            expectedRevision: nil
        )

        XCTAssertNil(makeResolver(fixture: fixture, store: fixture.store)
            .passthroughConfiguration(for: .codex))
    }

    func testStoreRejectsStaleRevisionBeforeWritingSidecar() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let original = try fixture.store.save(
            makeRecord(fixture: fixture, configurationID: "local-agent-config-1"),
            expectedRevision: nil
        )
        let before = try Data(contentsOf: fixture.sidecarURL)

        XCTAssertThrowsError(try fixture.store.save(original, expectedRevision: nil)) { error in
            XCTAssertEqual(
                error as? LocalAgentConfigurationStoreError,
                .staleRevision(expected: nil, actual: 1)
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.sidecarURL), before)
        XCTAssertEqual(try fixture.store.record(configurationID: original.configurationID), original)
    }

    func testCatalogRevisionMismatchFailsClosed() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var record = makeRecord(fixture: fixture, configurationID: "local-agent-config-1")
        record = LocalAgentConfigurationRecord(
            configurationID: record.configurationID,
            catalogID: record.catalogID,
            catalogSetRevision: record.catalogSetRevision + 1,
            descriptorRevision: record.descriptorRevision,
            rawIdentity: record.rawIdentity,
            userDisplayName: record.userDisplayName,
            executablePath: record.executablePath,
            executableIdentityDigest: record.executableIdentityDigest,
            executableReferenceConfirmedAt: record.executableReferenceConfirmedAt,
            detectedVersion: record.detectedVersion,
            authenticationState: .authenticated,
            executionProfileID: record.executionProfileID,
            executionProfileRevision: record.executionProfileRevision,
            authenticationEvidenceRevision: record.authenticationEvidenceRevision,
            cliAuthenticationScopeDigest: record.cliAuthenticationScopeDigest,
            cliLoginIdentityDigest: record.cliLoginIdentityDigest,
            environmentDigest: record.environmentDigest,
            lastVerifiedAt: record.lastVerifiedAt,
            explicitlyEnabled: record.explicitlyEnabled
        )
        XCTAssertThrowsError(try fixture.store.save(record, expectedRevision: nil)) { error in
            XCTAssertEqual(
                error as? LocalAgentConfigurationStoreError,
                .invalidRecord("catalog:local-agent-config-1")
            )
        }
    }

    func testEnvironmentAllowlistRejectsForbiddenAndCatchAllPatterns() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let descriptor = try XCTUnwrap(
            fixture.catalog.catalogSet?.localAgent(catalogID: "local-agent.codex")
        )

        for pattern in ["TOKEN", "OAUTH_*", "SSH_*", "KEYCHAIN_*", "PROXY_*PASS*", "*"] {
            let record = replacing(
                makeRecord(fixture: fixture, configurationID: "config-\(pattern)"),
                environmentAllowlist: [pattern]
            )
            XCTAssertThrowsError(try LocalAgentLaunchEnvironmentBuilder.build(
                record: record,
                descriptor: descriptor,
                environment: fixture.environment,
                homeDirectory: fixture.homeDirectory
            ), "Pattern \(pattern) must fail closed") { error in
                switch error as? LocalAgentLaunchEnvironmentBuilder.BuildError {
                case .forbiddenEnvironmentKey, .invalidEnvironmentPattern:
                    break
                default:
                    XCTFail("Unexpected error for \(pattern): \(error)")
                }
            }
        }
    }

    func testCustomPATHRejectsNonCanonicalAbsoluteEntry() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let descriptor = try XCTUnwrap(
            fixture.catalog.catalogSet?.localAgent(catalogID: "local-agent.codex")
        )
        let record = replacing(
            makeRecord(fixture: fixture, configurationID: "config-path"),
            pathPolicy: .custom,
            customPATHEntries: ["/usr/bin/../bin"]
        )

        XCTAssertThrowsError(try LocalAgentLaunchEnvironmentBuilder.build(
            record: record,
            descriptor: descriptor,
            environment: fixture.environment,
            homeDirectory: fixture.homeDirectory
        )) { error in
            XCTAssertEqual(
                error as? LocalAgentLaunchEnvironmentBuilder.BuildError,
                .invalidPATHEntry("/usr/bin/../bin")
            )
        }
    }

    func testPATHRejectsEmptyComponentInsteadOfUsingCurrentDirectory() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let descriptor = try XCTUnwrap(
            fixture.catalog.catalogSet?.localAgent(catalogID: "local-agent.codex")
        )
        let record = replacing(
            makeRecord(fixture: fixture, configurationID: "config-empty-component"),
            pathPolicy: .custom,
            customPATHEntries: ["/usr/bin", ""]
        )

        XCTAssertThrowsError(try LocalAgentLaunchEnvironmentBuilder.build(
            record: record,
            descriptor: descriptor,
            environment: fixture.environment,
            homeDirectory: fixture.homeDirectory
        )) { error in
            XCTAssertEqual(
                error as? LocalAgentLaunchEnvironmentBuilder.BuildError,
                .invalidPATHEntry("")
            )
        }
    }

    func testCustomAndLoginShellPATHRejectEmptyEntries() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let descriptor = try XCTUnwrap(
            fixture.catalog.catalogSet?.localAgent(catalogID: "local-agent.codex")
        )

        for policy in [LocalAgentPATHPolicy.custom, .loginShell] {
            let record = replacing(
                makeRecord(fixture: fixture, configurationID: "config-empty-path-\(policy.rawValue)"),
                pathPolicy: policy,
                customPATHEntries: []
            )
            XCTAssertThrowsError(try LocalAgentLaunchEnvironmentBuilder.build(
                record: record,
                descriptor: descriptor,
                environment: fixture.environment,
                homeDirectory: fixture.homeDirectory
            )) { error in
                XCTAssertEqual(error as? LocalAgentLaunchEnvironmentBuilder.BuildError, .emptyCustomPATH)
            }
        }
    }

    func testEnvironmentValuesRejectNULAndNewline() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let descriptor = try XCTUnwrap(
            fixture.catalog.catalogSet?.localAgent(catalogID: "local-agent.codex")
        )
        let record = replacing(
            makeRecord(fixture: fixture, configurationID: "config-environment-value"),
            environmentAllowlist: ["SAFE_VALUE"]
        )

        for unsafeValue in ["prefix\0suffix", "first\nsecond", "first\rsecond"] {
            var environment = fixture.environment
            environment["SAFE_VALUE"] = unsafeValue
            XCTAssertThrowsError(try LocalAgentLaunchEnvironmentBuilder.build(
                record: record,
                descriptor: descriptor,
                environment: environment,
                homeDirectory: fixture.homeDirectory
            )) { error in
                XCTAssertEqual(
                    error as? LocalAgentLaunchEnvironmentBuilder.BuildError,
                    .invalidEnvironmentValue("SAFE_VALUE")
                )
            }
        }
    }

    func testStoreRejectsNonSHA256AuthenticationEvidence() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let record = replacing(
            makeRecord(fixture: fixture, configurationID: "config-invalid-evidence"),
            cliLoginIdentityDigest: "person@example.com"
        )

        XCTAssertThrowsError(try fixture.store.save(record, expectedRevision: nil)) { error in
            XCTAssertEqual(
                error as? LocalAgentConfigurationStoreError,
                .invalidRecord("config-invalid-evidence")
            )
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-agent-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executableURL = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\necho codex-test\n".utf8).write(to: executableURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executableURL.path
        )
        let databaseURL = root.appendingPathComponent("config.sqlite3")
        let sidecarURL = root.appendingPathComponent("local-agent-configurations-v1.json")
        let environment = [
            "LANG": "zh_CN.UTF-8",
            "TERM": "xterm-256color",
            "TMPDIR": root.path,
            "ACCESS_TOKEN": "must-not-pass"
        ]
        let masterKey = TestLocalAgentMasterKeyProvider()
        let catalog = BundledRuntimeCatalog.shared
        let store = try LocalAgentConfigurationStore(
            backend: ConfigurationStoreBackend(databasePath: databaseURL.path),
            fileURL: sidecarURL,
            masterKeyProvider: masterKey,
            catalog: catalog,
            environment: { environment },
            homeDirectory: { root.path }
        )
        return Fixture(
            root: root,
            executableURL: executableURL,
            databaseURL: databaseURL,
            sidecarURL: sidecarURL,
            environment: environment,
            homeDirectory: root.path,
            masterKey: masterKey,
            catalog: catalog,
            store: store
        )
    }

    private func reopenStore(_ fixture: Fixture) throws -> LocalAgentConfigurationStore {
        try LocalAgentConfigurationStore(
            backend: ConfigurationStoreBackend(databasePath: fixture.databaseURL.path),
            fileURL: fixture.sidecarURL,
            masterKeyProvider: fixture.masterKey,
            catalog: fixture.catalog,
            environment: { fixture.environment },
            homeDirectory: { fixture.homeDirectory }
        )
    }

    private func makeRecord(
        fixture: Fixture,
        configurationID: String,
        explicitlyEnabled: Bool = true
    ) -> LocalAgentConfigurationRecord {
        let descriptor = fixture.catalog.catalogSet!.localAgent(catalogID: "local-agent.codex")!
        let base = LocalAgentConfigurationRecord(
            configurationID: configurationID,
            catalogID: descriptor.catalogID,
            catalogSetRevision: fixture.catalog.catalogSet!.catalogSetRevision,
            descriptorRevision: descriptor.revision,
            rawIdentity: descriptor.rawIdentity,
            userDisplayName: "My Codex",
            executablePath: fixture.executableURL.path,
            executableIdentityDigest: LocalAgentConfigurationIntegrity.executableDigest(
                path: fixture.executableURL.path
            )!,
            executableReferenceConfirmedAt: Date(timeIntervalSince1970: 1_780_000_000),
            detectedVersion: "codex-test 1.0",
            authenticationState: .authenticated,
            executionProfileID: "terminal-passthrough",
            executionProfileRevision: 1,
            authenticationEvidenceRevision: "auth-evidence-1",
            cliAuthenticationScopeDigest: "sha256:" + String(repeating: "a", count: 64),
            cliLoginIdentityDigest: "sha256:" + String(repeating: "b", count: 64),
            environmentDigest: "pending",
            lastVerifiedAt: Date(timeIntervalSince1970: 1_780_000_001),
            explicitlyEnabled: explicitlyEnabled
        )
        let launchEnvironment = try! LocalAgentLaunchEnvironmentBuilder.build(
            record: base,
            descriptor: descriptor,
            environment: fixture.environment,
            homeDirectory: fixture.homeDirectory
        )
        return LocalAgentConfigurationRecord(
            configurationID: base.configurationID,
            catalogID: base.catalogID,
            catalogSetRevision: base.catalogSetRevision,
            descriptorRevision: base.descriptorRevision,
            rawIdentity: base.rawIdentity,
            userDisplayName: base.userDisplayName,
            executablePath: base.executablePath,
            executableIdentityDigest: base.executableIdentityDigest,
            executableReferenceConfirmedAt: base.executableReferenceConfirmedAt,
            detectedVersion: base.detectedVersion,
            authenticationState: base.authenticationState,
            executionProfileID: base.executionProfileID,
            executionProfileRevision: base.executionProfileRevision,
            authenticationEvidenceRevision: base.authenticationEvidenceRevision,
            cliAuthenticationScopeDigest: base.cliAuthenticationScopeDigest,
            cliLoginIdentityDigest: base.cliLoginIdentityDigest,
            environmentDigest: LocalAgentConfigurationIntegrity.environmentDigest(launchEnvironment),
            lastVerifiedAt: base.lastVerifiedAt,
            explicitlyEnabled: explicitlyEnabled
        )
    }

    private func makeResolver(
        fixture: Fixture,
        store: LocalAgentConfigurationReading,
        environment: [String: String]? = nil,
        allowsLegacyPathDiscovery: Bool = false
    ) -> LocalAgentToolResolver {
        LocalAgentToolResolver(
            environment: environment ?? fixture.environment,
            homeDirectory: fixture.homeDirectory,
            catalog: fixture.catalog,
            configurationStore: store,
            allowsLegacyPathDiscovery: allowsLegacyPathDiscovery
        )
    }

    private func replacing(
        _ record: LocalAgentConfigurationRecord,
        pathPolicy: LocalAgentPATHPolicy? = nil,
        customPATHEntries: [String]? = nil,
        environmentAllowlist: [String]? = nil,
        cliLoginIdentityDigest: String? = nil,
        authenticationState: LocalAgentAuthenticationProbeState? = nil
    ) -> LocalAgentConfigurationRecord {
        LocalAgentConfigurationRecord(
            schemaVersion: record.schemaVersion,
            configurationID: record.configurationID,
            configurationRevision: record.configurationRevision,
            catalogID: record.catalogID,
            catalogSetRevision: record.catalogSetRevision,
            descriptorRevision: record.descriptorRevision,
            rawIdentity: record.rawIdentity,
            userDisplayName: record.userDisplayName,
            executablePath: record.executablePath,
            executableIdentityDigest: record.executableIdentityDigest,
            executableReferenceConfirmedAt: record.executableReferenceConfirmedAt,
            detectedVersion: record.detectedVersion,
            authenticationState: authenticationState ?? record.authenticationState,
            selectedProtocol: record.selectedProtocol,
            executionProfileID: record.executionProfileID,
            executionProfileRevision: record.executionProfileRevision,
            authenticationEvidenceRevision: record.authenticationEvidenceRevision,
            cliAuthenticationScopeDigest: record.cliAuthenticationScopeDigest,
            cliLoginIdentityDigest: cliLoginIdentityDigest ?? record.cliLoginIdentityDigest,
            workingDirectoryMode: record.workingDirectoryMode,
            workingDirectoryReference: record.workingDirectoryReference,
            pathPolicy: pathPolicy ?? record.pathPolicy,
            customPATHEntries: customPATHEntries ?? record.customPATHEntries,
            environmentAllowlist: environmentAllowlist ?? record.environmentAllowlist,
            environmentDigest: record.environmentDigest,
            lastVerifiedAt: record.lastVerifiedAt,
            explicitlyEnabled: record.explicitlyEnabled
        )
    }

    private func replacingWorkingDirectory(
        _ record: LocalAgentConfigurationRecord,
        mode: AgentProcessWorkingDirectoryMode,
        reference: String?
    ) -> LocalAgentConfigurationRecord {
        LocalAgentConfigurationRecord(
            schemaVersion: record.schemaVersion,
            configurationID: record.configurationID,
            configurationRevision: record.configurationRevision,
            catalogID: record.catalogID,
            catalogSetRevision: record.catalogSetRevision,
            descriptorRevision: record.descriptorRevision,
            rawIdentity: record.rawIdentity,
            userDisplayName: record.userDisplayName,
            executablePath: record.executablePath,
            executableIdentityDigest: record.executableIdentityDigest,
            executableReferenceConfirmedAt: record.executableReferenceConfirmedAt,
            detectedVersion: record.detectedVersion,
            authenticationState: record.authenticationState,
            selectedProtocol: record.selectedProtocol,
            executionProfileID: record.executionProfileID,
            executionProfileRevision: record.executionProfileRevision,
            authenticationEvidenceRevision: record.authenticationEvidenceRevision,
            cliAuthenticationScopeDigest: record.cliAuthenticationScopeDigest,
            cliLoginIdentityDigest: record.cliLoginIdentityDigest,
            workingDirectoryMode: mode,
            workingDirectoryReference: reference,
            pathPolicy: record.pathPolicy,
            customPATHEntries: record.customPATHEntries,
            environmentAllowlist: record.environmentAllowlist,
            environmentDigest: record.environmentDigest,
            lastVerifiedAt: record.lastVerifiedAt,
            explicitlyEnabled: record.explicitlyEnabled
        )
    }
}

private struct Fixture {
    let root: URL
    let executableURL: URL
    let databaseURL: URL
    let sidecarURL: URL
    let environment: [String: String]
    let homeDirectory: String
    let masterKey: TestLocalAgentMasterKeyProvider
    let catalog: BundledRuntimeCatalog
    let store: LocalAgentConfigurationStore

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct TestLocalAgentMasterKeyProvider: ConversationMasterKeyProviding {
    func masterKeyData() throws -> Data {
        Data((0..<32).map { UInt8(($0 * 17 + 11) % 251) })
    }
}
