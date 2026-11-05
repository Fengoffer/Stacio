import XCTest
import Foundation
@testable import StacioApp

/// P4-4：配置 Store 与 RuntimeConfigurationStateProjector
/// （Provider/Coding Plan 关闭集合、Local Agent 13 态阻断优先级、owner 矩阵、metadata 加密域）。
final class RuntimeConfigurationStateProjectorTests: XCTestCase {

    // MARK: - Provider 关闭集合与判定顺序

    func testProjectorClosedStateSet() {
        XCTAssertEqual(ProviderConfigurationState.allCases.count, 9)
        let closedSet = Set(ProviderConfigurationState.allCases)
        XCTAssertTrue(closedSet.contains(.savedDraft))
        XCTAssertTrue(closedSet.contains(.needsEndpoint))
        XCTAssertTrue(closedSet.contains(.needsCredential))
        XCTAssertTrue(closedSet.contains(.needsVerification))
        XCTAssertTrue(closedSet.contains(.readyToFetch))
        XCTAssertTrue(closedSet.contains(.fetching))
        XCTAssertTrue(closedSet.contains(.testing))
        XCTAssertTrue(closedSet.contains(.ready))
        XCTAssertTrue(closedSet.contains(.abandoned))
    }

    func testNilEndpointTakesPriorityOverCredential() {
        // nil endpoint → NeedsEndpoint（不以 NeedsCredential/ReadyToFetch 掩盖）
        let state = RuntimeConfigurationStateProjector.projectProvider(
            ProviderProjectionInput(hasSavedDraft: true, endpointPresent: false, credentialPresent: true)
        )
        XCTAssertEqual(state, .needsEndpoint)
        // 无 endpoint 即使无 credential 也是 NeedsEndpoint
        XCTAssertEqual(
            RuntimeConfigurationStateProjector.projectProvider(
                ProviderProjectionInput(hasSavedDraft: true, endpointPresent: false, credentialPresent: false)
            ),
            .needsEndpoint
        )
    }

    func testNoDraftYieldsSavedDraft() {
        XCTAssertEqual(
            RuntimeConfigurationStateProjector.projectProvider(
                ProviderProjectionInput(hasSavedDraft: false, endpointPresent: true, credentialPresent: true)
            ),
            .savedDraft
        )
        XCTAssertEqual(
            RuntimeConfigurationStateProjector.projectProvider(
                ProviderProjectionInput(hasSavedDraft: true, abandoned: true)
            ),
            .abandoned
        )
    }

    func testFetchingDerivedFromInFlightVerificationNotSpinner() {
        // 非终态 verificationRequest → fetching（Spinner 可见性不参与）
        let inFlight = ProviderProjectionInput(
            hasSavedDraft: true, endpointPresent: true, credentialPresent: true,
            verificationState: "inFlight", isFetching: false, isTesting: false
        )
        XCTAssertEqual(
            RuntimeConfigurationStateProjector.projectProvider(inFlight),
            .fetching
        )
        XCTAssertTrue(RuntimeConfigurationStateProjector.isDerivedFromInFlightVerification(inFlight))

        // 终态 → 不是 fetching
        let settled = ProviderProjectionInput(
            hasSavedDraft: true, endpointPresent: true, credentialPresent: true,
            verificationState: "settledSucceeded", isFetching: true, isTesting: false
        )
        XCTAssertFalse(RuntimeConfigurationStateProjector.isDerivedFromInFlightVerification(settled))
        // isFetching 布尔不来自 Spinner——由调用方从非终态请求派生后传入
        XCTAssertEqual(RuntimeConfigurationStateProjector.projectProvider(settled), .ready)
    }

    func testTestingDerivedFromVerificationRequest() {
        let input = ProviderProjectionInput(
            hasSavedDraft: true, endpointPresent: true, credentialPresent: true,
            verificationState: "inFlight", isFetching: false, isTesting: true
        )
        XCTAssertEqual(RuntimeConfigurationStateProjector.projectProvider(input), .testing)
    }

    func testNeedsVerificationPriorityAndReadyFlow() {
        // 未验证 → needsVerification（即使 credential/endpoint 都在）
        XCTAssertEqual(
            RuntimeConfigurationStateProjector.projectProvider(
                ProviderProjectionInput(hasSavedDraft: true, endpointPresent: true, credentialPresent: true)
            ),
            .needsVerification
        )
        // 验证失败 → needsVerification（不覆盖用户值：用户值由调用方保留）
        XCTAssertEqual(
            RuntimeConfigurationStateProjector.projectProvider(
                ProviderProjectionInput(
                    hasSavedDraft: true, endpointPresent: true, credentialPresent: true,
                    verificationState: "settledFailed", verificationSucceeded: false
                )
            ),
            .needsVerification
        )
        // 无 verification 但成功 → readyToFetch
        XCTAssertEqual(
            RuntimeConfigurationStateProjector.projectProvider(
                ProviderProjectionInput(
                    hasSavedDraft: true, endpointPresent: true, credentialPresent: true,
                    verificationSucceeded: true
                )
            ),
            .readyToFetch
        )
        // 有 verification 且成功 → ready
        XCTAssertEqual(
            RuntimeConfigurationStateProjector.projectProvider(
                ProviderProjectionInput(
                    hasSavedDraft: true, endpointPresent: true, credentialPresent: true,
                    verificationState: "settledSucceeded", verificationSucceeded: true
                )
            ),
            .ready
        )
    }

    // MARK: - Local Agent 13 态

    func testLocalAgentThirteenStateClosedSet() {
        XCTAssertEqual(LocalAgentConfigurationState.allCases.count, 13)
        let ranks = LocalAgentConfigurationState.allCases.map(\.blockingRank)
        XCTAssertEqual(Set(ranks).count, 12, "Detecting|LoggingIn 同级（阻断优先级 3）")
    }

    func testLocalAgentFixedBlockingPriority() {
        // Abandoned 最高优先级
        XCTAssertEqual(
            RuntimeConfigurationStateProjector.projectLocalAgent(
                abandoned: true, processReconciliationRequired: true, isDetecting: true,
                isLoggingIn: false, unsupported: true, unconfigured: true, detectionFailed: true,
                authenticationStateUnknown: true, needsLogin: true, needsProfileSelection: true,
                needsVerification: true, disabled: true
            ),
            .abandoned
        )
        // ProcessReconciliationRequired > Unsupported
        XCTAssertEqual(
            RuntimeConfigurationStateProjector.projectLocalAgent(
                abandoned: false, processReconciliationRequired: true, isDetecting: false,
                isLoggingIn: false, unsupported: true, unconfigured: false, detectionFailed: false,
                authenticationStateUnknown: false, needsLogin: false, needsProfileSelection: false,
                needsVerification: false, disabled: false
            ),
            .processReconciliationRequired
        )
        // Unsupported > Unconfigured
        XCTAssertEqual(
            RuntimeConfigurationStateProjector.projectLocalAgent(
                abandoned: false, processReconciliationRequired: false, isDetecting: false,
                isLoggingIn: false, unsupported: true, unconfigured: true, detectionFailed: false,
                authenticationStateUnknown: false, needsLogin: false, needsProfileSelection: false,
                needsVerification: false, disabled: false
            ),
            .unsupported
        )
        // NeedsVerification > Disabled > Ready
        XCTAssertEqual(
            RuntimeConfigurationStateProjector.projectLocalAgent(
                abandoned: false, processReconciliationRequired: false, isDetecting: false,
                isLoggingIn: false, unsupported: false, unconfigured: false, detectionFailed: false,
                authenticationStateUnknown: false, needsLogin: false, needsProfileSelection: false,
                needsVerification: true, disabled: true
            ),
            .needsVerification
        )
        XCTAssertEqual(
            RuntimeConfigurationStateProjector.projectLocalAgent(
                abandoned: false, processReconciliationRequired: false, isDetecting: false,
                isLoggingIn: false, unsupported: false, unconfigured: false, detectionFailed: false,
                authenticationStateUnknown: false, needsLogin: false, needsProfileSelection: false,
                needsVerification: false, disabled: true
            ),
            .disabled
        )
        // 全部满足 → ready
        XCTAssertEqual(
            RuntimeConfigurationStateProjector.projectLocalAgent(
                abandoned: false, processReconciliationRequired: false, isDetecting: false,
                isLoggingIn: false, unsupported: false, unconfigured: false, detectionFailed: false,
                authenticationStateUnknown: false, needsLogin: false, needsProfileSelection: false,
                needsVerification: false, disabled: false
            ),
            .ready
        )
    }

    // MARK: - 字段 owner 矩阵

    func testFieldOwnerMatrixNoMultipleOrZeroOwners() throws {
        let allFields: Set<String> = ["baseURL", "apiKey", "connectionState"]
        let owners: [ConfigurationFieldOwner] = [
            ConfigurationFieldOwner(field: "baseURL", owner: .setting("provider.defaultBaseURL")),
            ConfigurationFieldOwner(field: "apiKey", owner: .action("provider.saveApiKey")),
            ConfigurationFieldOwner(field: "connectionState", owner: .readOnlyProjection)
        ]
        try ConfigurationFieldOwnerMatrix.validate(owners, allFields: allFields)

        // 零 owner → 失败
        XCTAssertThrowsError(try ConfigurationFieldOwnerMatrix.validate([], allFields: allFields)) { error in
            XCTAssertEqual(
                error as? ConfigurationFieldOwnerMatrix.MatrixError,
                .zeroOwners(["apiKey", "baseURL", "connectionState"].sorted())
            )
        }
        // 多 owner → 失败
        let multiple = owners + [
            ConfigurationFieldOwner(field: "baseURL", owner: .action("provider.verifyConfiguration"))
        ]
        XCTAssertThrowsError(try ConfigurationFieldOwnerMatrix.validate(multiple, allFields: allFields)) { error in
            switch error as? ConfigurationFieldOwnerMatrix.MatrixError {
            case .multipleOwners(let field, let kinds):
                XCTAssertEqual(field, "baseURL")
                XCTAssertEqual(kinds.count, 2)
            default:
                XCTFail("预期 multipleOwners")
            }
        }
    }

    // MARK: - metadata 加密域隔离

    func testMetadataKeyDomainSeparated() {
        XCTAssertTrue(RuntimeConfigurationMetadataKey.isDomainSeparatedFromPreferenceContentKey())
        XCTAssertNotEqual(
            RuntimeConfigurationMetadataKey.domain,
            AssistantPreferenceContentKey.domain,
            "RuntimeConfigurationMetadataKey 与 AssistantPreferenceContentKey 加密域分离"
        )
    }

    func testMetadataEncryptionRoundTripAndAADBinding() throws {
        let master = Data((0..<32).map { UInt8($0) })
        let value = Data("自定义名称/内网 Base URL metadata".utf8)
        let sealed = try RuntimeConfigurationMetadataKey.seal(
            value: value, configurationID: "config-1", field: "customName", masterKeyData: master
        )
        XCTAssertNotEqual(sealed, value)
        XCTAssertEqual(
            try RuntimeConfigurationMetadataKey.open(
                sealed: sealed, configurationID: "config-1", field: "customName", masterKeyData: master
            ),
            value
        )
        // 换 field → authenticationFailed（内容跨字段替换被拒）
        XCTAssertThrowsError(
            try RuntimeConfigurationMetadataKey.open(
                sealed: sealed, configurationID: "config-1", field: "baseURL", masterKeyData: master
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeConfigurationMetadataError, .authenticationFailed)
        }
        // 换 configurationID → authenticationFailed
        XCTAssertThrowsError(
            try RuntimeConfigurationMetadataKey.open(
                sealed: sealed, configurationID: "config-2", field: "customName", masterKeyData: master
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeConfigurationMetadataError, .authenticationFailed)
        }
    }

    // MARK: - Stores（CRUD 走真实 P3-12 后端）

    func testProviderConfigurationStoreCRUD() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-config-p44-\(UUID().uuidString).sqlite3").path
        let backend = try ConfigurationStoreBackend(databasePath: path)
        let store = ProviderConfigurationStore(backend: backend)
        try store.upsert(configurationID: "provider-1", expectedRevision: nil, valueDigest: "digest-1", credentialReference: "credential-lifecycle:gen-1")
        let snapshot = try store.snapshot(configurationID: "provider-1")
        XCTAssertEqual(snapshot?.revision, 1)
        XCTAssertEqual(snapshot?.state, "draft")
        // 状态唯一由 Projector 计算（Store 不接受外部赋值）
        XCTAssertEqual(
            store.projectedState(
                ProviderProjectionInput(hasSavedDraft: true, endpointPresent: true, credentialPresent: true)
            ),
            .needsVerification
        )
    }
}
