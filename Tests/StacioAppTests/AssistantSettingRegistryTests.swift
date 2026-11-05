import Foundation
import XCTest
@testable import StacioApp

final class AssistantSettingRegistryTests: XCTestCase {
    private func makeRegistry() throws -> AssistantSettingRegistry {
        try AssistantSettingRegistry.standard()
    }

    private var expectedStandardIDs: Set<String> {
        let assistantIDs = [
            "assistant.general.defaultRuntime",
            "assistant.general.defaultWorkMode",
            "assistant.general.defaultReasoningEffort",
            "assistant.general.queueAutoAdvance",
            "assistant.general.restoreLastConversation",
            "assistant.general.sendKeyMode",
            "assistant.general.localAutoTitle",
            "assistant.general.language",
            "assistant.general.configurationOrder",
            "assistant.execution.defaultTerminalMode",
            "assistant.execution.maxParallelAttempts",
            "assistant.execution.capacityWaitMinutes",
            "assistant.execution.approvalDeadlineMinutes",
            "assistant.execution.userInputDeadline",
            "assistant.execution.maxEffectiveMinutes",
            "assistant.execution.maxToolSteps",
            "assistant.execution.maxControlledChildTasks",
            "assistant.execution.managedStopGraceSeconds",
            "assistant.usage.maxModelInvocations",
            "assistant.usage.tokenWarningThreshold",
            "assistant.usage.hardTokenLimit",
            "assistant.usage.costWarning",
            "assistant.usage.hardCostLimit",
            "assistant.security.approvalLevel",
            "assistant.tools.enabledToolIDs",
            "assistant.instructions.globalText",
            "assistant.instructions.projectDiscovery",
            "assistant.instructions.approvedRootReferences",
            "assistant.context.defaultOptionalSourceIDs",
            "assistant.context.terminalOutputMode",
            "assistant.context.maxSingleSourceMiB",
            "assistant.context.budgetMode",
            "assistant.context.autoCompression",
            "assistant.memory.projectEnabled",
            "assistant.history.retention",
            "assistant.storage.databaseGiB",
            "assistant.storage.attachmentsGiB",
            "assistant.storage.terminalLogsGiB",
            "assistant.storage.singleAttachmentMiB",
            "assistant.storage.singleExecutionLogMiB",
            "assistant.notifications.eventIDs",
            "assistant.notifications.longCapacityWaitMinutes",
            "assistant.privacy.telemetryEnabled",
            "assistant.privacy.terminalRecordingScope",
            "assistant.appearance.timelineDensity",
            "assistant.appearance.codeFontSize",
            "assistant.appearance.terminalBlockHeight",
            "assistant.appearance.motionMode"
        ]
        let provider = [
            "displayName", "enabled", "baseURL", "protocol", "modelDiscoveryStrategy",
            "enabledModelIDs", "defaultModelID", "modelCapabilityOverrides",
            "connectionTimeoutSeconds", "firstByteTimeoutSeconds", "streamIdleTimeoutSeconds",
            "setupTimeoutSeconds", "safeRetryCount", "userAgent", "customHeaders", "proxyMode",
            "customProxyURL", "customCAReference", "allowInsecureLANHTTP", "websiteActionOverrides"
        ].map { "provider.{id}.\($0)" }
        let codingPlan = [
            "displayName", "enabled", "baseURL", "protocol", "enabledModelIDs", "defaultModelID",
            "modelCapabilityOverrides", "selectedCompatibilityID",
            "selectedLocalAgentConfigurationID", "networkPolicy", "customHeaders",
            "websiteActionOverrides"
        ].map { "codingPlan.{id}.\($0)" }
        let localAgent = [
            "displayName", "enabled", "executionProfileID", "executableReference",
            "workingDirectoryMode", "workingDirectoryReference", "pathPolicy", "customPATHEntries",
            "environmentAllowlist", "enabledModelIDs", "defaultModelID", "websiteActionOverrides"
        ].map { "localAgent.{id}.\($0)" }
        return Set(assistantIDs + provider + codingPlan + localAgent)
    }

    func testStandardRegistryHasExactNinetyTwoStableIDs() throws {
        let registry = try makeRegistry()
        XCTAssertEqual(expectedStandardIDs.count, 92)
        XCTAssertEqual(Set(registry.descriptorsByID.keys), expectedStandardIDs)
        XCTAssertEqual(registry.revision, 2)

        let retiredIDs = [
            "general.autoTitle", "execution.maxParallelSessions", "provider.customHeaders",
            "codingPlan.authorizationScope", "localAgent.modelCollection", "memory.deleteAllData"
        ]
        for id in retiredIDs {
            XCTAssertNil(registry.descriptor(for: id), "旧 Setting ID 不得继续被生产 Registry 接受: \(id)")
        }
    }

    func testEveryDescriptorHasRequiredTypedMetadata() throws {
        let registry = try makeRegistry()
        for (id, descriptor) in registry.descriptorsByID {
            XCTAssertFalse(descriptor.migrationKey.isEmpty, id)
            XCTAssertEqual(descriptor.migrationKey, "\(id).v1", id)
            XCTAssertNotNil(SettingCategoryResolver.classify(descriptor), id)
            switch descriptor.defaultValue {
            case .string: XCTAssertEqual(descriptor.valueType, .string, id)
            case .int: XCTAssertEqual(descriptor.valueType, .int, id)
            case .bool: XCTAssertEqual(descriptor.valueType, .bool, id)
            case .double: XCTAssertEqual(descriptor.valueType, .double, id)
            case .stringArray: XCTAssertEqual(descriptor.valueType, .stringArray, id)
            case .structured: XCTAssertEqual(descriptor.valueType, .structured, id)
            }
            if descriptor.writeControlPolicy == .actionOnly {
                XCTAssertNotNil(descriptor.writeOperationKind, id)
            }
        }
    }

    func testDescriptorsCoverAllSettingPagesAndOnlyDiagnosticsIsActionProjectionOnly() throws {
        let pages = Set(try makeRegistry().descriptorsByID.values.map(\.page))
        let expected = Set(AssistantSettingsPage.allCases).subtracting([.advancedDiagnostics])
        XCTAssertEqual(pages, expected)
    }

    func testDocumentedDefaultsRangesAndEnums() throws {
        let registry = try makeRegistry()
        XCTAssertEqual(registry.descriptor(for: "assistant.general.defaultRuntime")?.defaultValue, .string(""))
        XCTAssertEqual(registry.descriptor(for: "assistant.general.defaultWorkMode")?.allowedValues, ["agent", "plan", "answer"])
        XCTAssertEqual(registry.descriptor(for: "assistant.general.sendKeyMode")?.defaultValue, .string("return"))
        XCTAssertEqual(registry.descriptor(for: "assistant.execution.maxParallelAttempts")?.range, 1...4)
        XCTAssertEqual(registry.descriptor(for: "assistant.execution.maxParallelAttempts")?.defaultValue, .int(2))
        XCTAssertEqual(registry.descriptor(for: "assistant.execution.maxEffectiveMinutes")?.range, 5...120)
        XCTAssertEqual(registry.descriptor(for: "assistant.execution.maxEffectiveMinutes")?.defaultValue, .int(30))
        XCTAssertEqual(registry.descriptor(for: "assistant.execution.maxToolSteps")?.range, 5...200)
        XCTAssertEqual(registry.descriptor(for: "assistant.execution.maxToolSteps")?.defaultValue, .int(40))
        XCTAssertEqual(registry.descriptor(for: "assistant.usage.maxModelInvocations")?.range, 5...200)
        XCTAssertEqual(registry.descriptor(for: "assistant.usage.maxModelInvocations")?.defaultValue, .int(40))
        XCTAssertEqual(registry.descriptor(for: "assistant.context.maxSingleSourceMiB")?.range, 1...25)
        XCTAssertEqual(registry.descriptor(for: "assistant.context.maxSingleSourceMiB")?.defaultValue, .int(10))
        XCTAssertEqual(registry.descriptor(for: "assistant.memory.projectEnabled")?.defaultValue, .bool(false))
        XCTAssertEqual(registry.descriptor(for: "assistant.storage.databaseGiB")?.defaultValue, .int(1))
        XCTAssertEqual(registry.descriptor(for: "assistant.storage.attachmentsGiB")?.defaultValue, .int(2))
        XCTAssertEqual(registry.descriptor(for: "assistant.storage.terminalLogsGiB")?.defaultValue, .int(2))
        XCTAssertEqual(registry.descriptor(for: "assistant.storage.singleAttachmentMiB")?.defaultValue, .int(100))
        XCTAssertEqual(registry.descriptor(for: "assistant.storage.singleExecutionLogMiB")?.defaultValue, .int(100))
        XCTAssertEqual(registry.descriptor(for: "assistant.notifications.longCapacityWaitMinutes")?.range, 1...30)
        XCTAssertEqual(registry.descriptor(for: "assistant.notifications.longCapacityWaitMinutes")?.defaultValue, .int(5))
        XCTAssertEqual(registry.descriptor(for: "assistant.privacy.telemetryEnabled")?.defaultValue, .bool(false))
    }

    func testExactSizeLimitContract() throws {
        let registry = try makeRegistry()
        func limit(_ id: String) throws -> SettingSizeLimit {
            try XCTUnwrap(registry.descriptor(for: id)?.sizeLimit, id)
        }

        XCTAssertEqual(try limit("assistant.general.configurationOrder").maxLengthChars, 4_096)
        XCTAssertEqual(try limit("provider.{id}.customHeaders"),
                       SettingSizeLimit(maxCount: 64, maxItemBytes: 4 * 1_024, maxTotalBytes: 64 * 1_024))
        XCTAssertEqual(try limit("provider.{id}.websiteActionOverrides").maxCount, 64)
        XCTAssertEqual(try limit("provider.{id}.websiteActionOverrides").maxItemBytes, 16)
        XCTAssertEqual(try limit("provider.{id}.enabledModelIDs"),
                       SettingSizeLimit(maxCount: 4_096, maxItemBytes: 512, maxTotalBytes: 4 * 1_024 * 1_024))
        XCTAssertEqual(try limit("localAgent.{id}.customPATHEntries").maxCount, 64)
        XCTAssertEqual(try limit("localAgent.{id}.environmentAllowlist").maxCount, 128)
        XCTAssertEqual(try limit("assistant.instructions.approvedRootReferences").maxCount, 128)
        XCTAssertEqual(try limit("assistant.instructions.globalText").maxLengthChars, 256 * 1_024)
    }

    func testLimitsAreEnforcedWithoutPrintingSensitivePayloads() throws {
        let registry = try makeRegistry()
        let paths = Array(repeating: "/bin", count: 65)
        guard case .outOfRange = registry.resolve(
            value: .stringArray(paths),
            for: "localAgent.demo.customPATHEntries"
        ) else { return XCTFail("customPATHEntries 必须执行 64 项上限") }

        let oversizedText = String(repeating: "x", count: 256 * 1_024 + 1)
        guard case .outOfRange = registry.resolve(
            value: .string(oversizedText),
            for: "assistant.instructions.globalText"
        ) else { return XCTFail("globalText 必须执行 256 KiB 上限") }

        let oversizedStructured = Data(repeating: 0, count: 64 * 1_024 + 1)
        guard case .outOfRange = registry.resolve(
            value: .structured(oversizedStructured),
            for: "provider.demo.customHeaders"
        ) else { return XCTFail("structured customHeaders 必须执行总字节上限") }
    }

    func testConfigurationTemplatesResolveConcreteInstanceIDs() throws {
        let registry = try makeRegistry()
        let provider = try XCTUnwrap(registry.descriptor(for: "provider.4f6a.baseURL"))
        XCTAssertEqual(provider.id, "provider.4f6a.baseURL")
        XCTAssertEqual(provider.page, .providerDetails)
        XCTAssertEqual(provider.scope, .provider)
        XCTAssertEqual(provider.writeControlPolicy, .actionOnly)
        XCTAssertEqual(provider.migrationKey, "provider.4f6a.baseURL.v1")

        let codingPlan = try XCTUnwrap(registry.descriptor(for: "codingPlan.glm-plan.enabledModelIDs"))
        XCTAssertEqual(codingPlan.page, .codingPlan)
        let localAgent = try XCTUnwrap(registry.descriptor(for: "localAgent.codex.pathPolicy"))
        XCTAssertEqual(localAgent.defaultSource, .localAgent)
        XCTAssertNil(registry.descriptor(for: "provider..baseURL"))
    }

    func testNeedsReviewWrongTypeAndOutOfRangeDoNotFallback() throws {
        let registry = try makeRegistry()
        XCTAssertEqual(registry.resolve(value: .int(1), for: "unknown.setting"), .needsReview)
        XCTAssertEqual(
            registry.resolve(value: .string("yes"), for: "assistant.general.restoreLastConversation"),
            .wrongType(.string("yes"))
        )
        XCTAssertEqual(
            registry.resolve(value: .int(300), for: "assistant.execution.maxToolSteps"),
            .outOfRange(.int(300))
        )
        XCTAssertEqual(
            registry.resolve(value: .string("deleted"), for: "assistant.appearance.timelineDensity"),
            .needsReview
        )
    }

    func testActionOnlyAndReadOnlyCannotBeBypassed() throws {
        let registry = try makeRegistry()
        XCTAssertFalse(registry.bulkSetterCanWrite(id: "assistant.general.configurationOrder"))
        XCTAssertFalse(registry.bulkSetterCanWrite(id: "provider.demo.customHeaders"))
        XCTAssertFalse(registry.bulkSetterCanWrite(id: "assistant.history.retention"))
        XCTAssertFalse(registry.bulkSetterCanWrite(id: "assistant.privacy.telemetryEnabled"))
        XCTAssertTrue(registry.bulkSetterCanWrite(id: "assistant.general.localAutoTitle"))
    }

    func testSnapshotIsTheOnlyDefaultsAndPolicySource() throws {
        let registry = try makeRegistry()
        let snapshot = registry.snapshot()
        XCTAssertEqual(snapshot.revision, 2)
        XCTAssertEqual(snapshot.defaultsByID.count, 92)
        XCTAssertEqual(snapshot.defaultsByID["assistant.execution.maxParallelAttempts"], .int(2))
        XCTAssertEqual(snapshot.defaultsByID["assistant.execution.maxToolSteps"], .int(40))
        XCTAssertEqual(snapshot.defaultsByID["assistant.context.maxSingleSourceMiB"], .int(10))
        XCTAssertEqual(snapshot.defaultsByID["assistant.appearance.timelineDensity"], .string("comfortable"))
    }

    func testRegistryBuildRejectsMissingOperationAndDuplicateID() throws {
        let incomplete = SettingDescriptor(
            id: "broken.actionOnly", valueType: .bool, category: .general,
            defaultValue: .bool(false), scope: .global, applyBoundary: .nextSession,
            sensitivity: .publicValue, exportPolicy: .includeValue, defaultExportSelection: true,
            resetBehavior: .restoreDefault, migrationKey: "broken.actionOnly.v1",
            writeControlPolicy: .actionOnly
        )
        XCTAssertThrowsError(try AssistantSettingRegistry.build(descriptors: [incomplete]))

        let descriptor = try XCTUnwrap(makeRegistry().descriptorsByID.values.first)
        XCTAssertThrowsError(try AssistantSettingRegistry.build(descriptors: [descriptor, descriptor])) { error in
            XCTAssertEqual(error as? SettingRegistryError, .duplicateID(descriptor.id))
        }
    }

    func testClosedClassificationSetsRemainExhaustive() {
        XCTAssertEqual(Set(SettingSensitivity.allCases).count, 5)
        XCTAssertEqual(Set(SettingExportPolicy.allCases).count, 3)
        XCTAssertEqual(Set(SettingWriteControlPolicy.allCases).count, 3)
        XCTAssertEqual(Set(AssistantSettingsPage.allCases).count, 19)
    }
}
