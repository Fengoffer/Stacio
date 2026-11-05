import Foundation
import XCTest
@testable import StacioApp

final class ConfigurationDeleteActionRouterTests: XCTestCase {
    func testRoutesEachClosedConfigurationKindToOnlyItsRegisteredOwner() throws {
        let harness = try makeHarness()
        var providerCalls: [AssistantSettingsActionRequest] = []
        var localAgentCalls: [AssistantSettingsActionRequest] = []
        try harness.router.registerOwner(for: .provider) { request, completion in
            providerCalls.append(request)
            completion(.succeeded(proofDigest: "provider-deleted"))
        }
        try harness.router.registerOwner(for: .localAgent) { request, completion in
            localAgentCalls.append(request)
            completion(.succeeded(proofDigest: "local-agent-deleted"))
        }

        let providerResult = invoke(
            harness.owner,
            parameters: [
                "configurationKind": .string(ConfigurationKind.provider.rawValue),
                "configurationID": .string("provider-1"),
                "expectedRevision": .int(4)
            ]
        )
        XCTAssertEqual(providerResult, .succeeded(proofDigest: "provider-deleted"))
        XCTAssertEqual(providerCalls.map(\.parameters["configurationID"]), [.string("provider-1")])
        XCTAssertTrue(localAgentCalls.isEmpty)

        let localResult = invoke(
            harness.owner,
            parameters: [
                "configurationKind": .string(ConfigurationKind.localAgent.rawValue),
                "configurationID": .string("local-agent-1"),
                "expectedRevision": .int(7)
            ]
        )
        XCTAssertEqual(localResult, .succeeded(proofDigest: "local-agent-deleted"))
        XCTAssertEqual(localAgentCalls.map(\.parameters["configurationID"]), [.string("local-agent-1")])
        XCTAssertEqual(providerCalls.count, 1)
    }

    func testMissingUnknownAndUnregisteredKindsFailClosed() throws {
        let harness = try makeHarness()
        try harness.router.registerOwner(for: .localAgent) { _, completion in
            completion(.succeeded(proofDigest: "unexpected"))
        }

        XCTAssertEqual(
            invoke(harness.owner, parameters: [:]),
            .failed(reasonCode: "invalid_configuration_delete_kind")
        )
        XCTAssertEqual(
            invoke(harness.owner, parameters: ["configurationKind": .string("unknown")]),
            .failed(reasonCode: "invalid_configuration_delete_kind")
        )
        XCTAssertEqual(
            invoke(
                harness.owner,
                parameters: ["configurationKind": .string(ConfigurationKind.codingPlan.rawValue)]
            ),
            .failed(reasonCode: "configuration_delete_owner_unavailable")
        )
    }

    func testDuplicateKindRegistrationIsRejectedAndTokenizedRollbackCannotRemoveReplacement() throws {
        let router = ConfigurationDeleteActionRouter()
        let token = try router.registerOwner(for: .localAgent) { _, completion in
            completion(.cancelled)
        }
        XCTAssertThrowsError(
            try router.registerOwner(for: .localAgent) { _, completion in
                completion(.cancelled)
            }
        ) { error in
            XCTAssertEqual(
                error as? ConfigurationDeleteActionRouterError,
                .duplicateKind(.localAgent)
            )
        }

        router.unregisterOwner(for: .localAgent, registrationID: UUID())
        XCTAssertTrue(router.hasOwner(for: .localAgent))
        router.unregisterOwner(for: .localAgent, registrationID: token)
        XCTAssertFalse(router.hasOwner(for: .localAgent))
    }

    private func makeHarness() throws -> (
        router: ConfigurationDeleteActionRouter,
        owner: AssistantSettingsActionOwner
    ) {
        let owners = AssistantSettingsActionOwnerRegistry()
        let backend = try AssistantSettingsStoreBackend(
            databasePath: FileManager.default.temporaryDirectory
                .appendingPathComponent("delete-router-\(UUID().uuidString).sqlite3").path
        )
        let coordinator = AssistantSettingsActionCoordinator(
            registry: try .standard(),
            control: DeleteRouterControlState(),
            eventStore: AssistantSettingsEventStore(backend: backend),
            owners: owners
        )
        let router = ConfigurationDeleteActionRouter()
        try router.registerActionOwner(in: coordinator)
        return (router, try XCTUnwrap(owners.owner(for: "configuration.delete")))
    }

    private func invoke(
        _ owner: AssistantSettingsActionOwner,
        parameters: [String: SettingValue]
    ) -> AssistantSettingsActionExecutionResult? {
        var result: AssistantSettingsActionExecutionResult?
        owner(
            .init(
                actionID: "configuration.delete",
                operationID: "delete-router-\(UUID().uuidString)",
                parameters: parameters
            )
        ) { result = $0 }
        return result
    }
}

private final class DeleteRouterControlState: AssistantSettingsControlStateProviding {
    func controlState() throws -> AgentConversationV2ControlState { .enabled }
}
