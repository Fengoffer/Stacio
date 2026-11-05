import AppKit
import Foundation
import XCTest
@testable import StacioApp

final class AssistantSettingsWindowTests: XCTestCase {
    private func makeRegistry() throws -> AssistantSettingRegistry {
        try AssistantSettingRegistry.standard()
    }

    private func makeActionRegistry() throws -> AssistantSettingsActionRegistry {
        try AssistantSettingsActionRegistry.standard()
    }

    func testNineteenPagesAreStableAndRendered() throws {
        XCTAssertEqual(V2SettingsPaneFactory.pageIDs, AssistantSettingsPage.allCases)
        XCTAssertEqual(Set(V2SettingsPaneFactory.pageIDs).count, 19)

        let pane = V2SettingsPaneFactory.makeRegistryDrivenPane(
            registry: try makeRegistry(),
            actionRegistry: try makeActionRegistry()
        )
        let document = try XCTUnwrap((pane as? NSScrollView)?.documentView as? NSStackView)
        let identifiers = Set(document.arrangedSubviews.compactMap { view -> String? in
            let identifier = view.accessibilityIdentifier()
            return identifier.isEmpty ? nil : identifier
        })
        for page in AssistantSettingsPage.allCases {
            XCTAssertTrue(
                identifiers.contains("Stacio.Settings.group.\(page.rawValue)"),
                "缺少 Settings 页面: \(page.rawValue)"
            )
        }
    }

    func testEveryGlobalUserWritableDescriptorHasOneNativeControl() throws {
        let registry = try makeRegistry()
        let registrations = V2SettingsPaneFactory.registrations()
        try V2SettingsPaneFactory.validate(registrations: registrations)

        let expected = Set(registry.descriptorsByID.values.compactMap { descriptor -> String? in
            guard descriptor.writeControlPolicy == .userWritable, !descriptor.id.contains("{id}") else {
                return nil
            }
            return descriptor.id
        })
        let actual = Set(registrations.compactMap { registration -> String? in
            guard case .editableSetting(let id) = registration.kind else { return nil }
            return id
        })
        XCTAssertEqual(expected.count, 45)
        XCTAssertEqual(actual, expected)

        let pane = V2SettingsPaneFactory.makeRegistryDrivenPane(
            registry: registry,
            actionRegistry: try makeActionRegistry()
        )
        for id in expected {
            XCTAssertNotNil(
                findView(identifier: "Stacio.Settings.\(id).control", in: pane),
                "Setting 必须有原生控件: \(id)"
            )
        }
    }

    func testActionOnlyDescriptorsHaveKnownActionOwnerIncludingInstanceTemplates() throws {
        let registry = try makeRegistry()
        let actionRegistry = try makeActionRegistry()
        let actionOnly = registry.descriptorsByID.values.filter { $0.writeControlPolicy == .actionOnly }
        XCTAssertEqual(actionOnly.count, 47)
        for descriptor in actionOnly {
            let actionID = try XCTUnwrap(
                V2SettingsPaneFactory.actionBinding(for: descriptor.id),
                "Action-only Setting 缺 owner: \(descriptor.id)"
            )
            XCTAssertNotNil(actionRegistry.action(for: actionID), "未知 Action owner: \(actionID)")
        }

        let visibleTemplateIDs = V2SettingsPaneFactory.registrations().filter {
            switch $0.kind {
            case .editableSetting(let id), .actionBackedSetting(let id, _): return id.contains("{id}")
            default: return false
            }
        }
        XCTAssertTrue(visibleTemplateIDs.isEmpty, "未选具体配置时不能显示 {id} 模板控件")
    }

    func testAllFortyEightStableActionsAreRegisteredWithoutLegacyIDs() throws {
        let actionRegistry = try makeActionRegistry()
        let registrations = V2SettingsPaneFactory.registrations()
        let actionIDs = Set(registrations.compactMap { registration -> String? in
            guard case .action(let id) = registration.kind else { return nil }
            return id
        })
        XCTAssertEqual(actionIDs.count, 48)
        XCTAssertEqual(actionIDs, Set(actionRegistry.actionsByID.keys))
        XCTAssertFalse(actionIDs.contains("provider.saveApiKey"))
        XCTAssertFalse(actionIDs.contains("provider.importConfiguration"))
        XCTAssertFalse(actionIDs.contains("memory.deleteAllData"))
    }

    func testReadOnlyProjectionsAlwaysCarrySourceTimestampAndPage() throws {
        let registrations = V2SettingsPaneFactory.registrations()
        try V2SettingsPaneFactory.validate(registrations: registrations)
        let projections = registrations.filter {
            if case .readOnlyProjection = $0.kind { return true }
            return false
        }
        XCTAssertEqual(Set(projections.map(\.page)), Set(AssistantSettingsPage.allCases).subtracting([.general]))
        for registration in projections {
            guard case .readOnlyProjection(let id, let source, let updatedAt) = registration.kind else {
                continue
            }
            XCTAssertFalse(id.isEmpty)
            XCTAssertFalse(source.isEmpty)
            XCTAssertNotNil(updatedAt)
        }
    }

    func testActionDoesNotDisplaySuccessBeforeBusinessOwnerCompletes() throws {
        var pendingCompletion: ((Result<AssistantSettingsActionExecutionResult, AssistantSettingsActionError>) -> Void)?
        let pane = try XCTUnwrap(V2SettingsPaneFactory.makeRegistryDrivenPane(
            registry: makeRegistry(),
            actionRegistry: makeActionRegistry(),
            actionAvailability: { $0 == "provider.fetchModels" },
            actionHandler: { actionID, _, completion in
                XCTAssertEqual(actionID, "provider.fetchModels")
                pendingCompletion = completion
            }
        ) as? V2SettingsPaneView)
        let identifier = "Stacio.Settings.action.provider.fetchModels"
        let button = try XCTUnwrap(findView(identifier: identifier + ".button", in: pane) as? NSButton)
        button.performClick(nil)

        XCTAssertEqual(pane.statusText(for: identifier), "处理中...")
        XCTAssertNotEqual(pane.statusText(for: identifier), "已完成")
        XCTAssertFalse(button.isEnabled)

        pendingCompletion?(.success(.succeeded(proofDigest: "sha256:done")))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(pane.statusText(for: identifier), "已完成")
        XCTAssertTrue(button.isEnabled)
    }

    func testMissingBusinessOwnerDisablesActionInsteadOfFalseSuccess() throws {
        let pane = try XCTUnwrap(V2SettingsPaneFactory.makeRegistryDrivenPane(
            registry: makeRegistry(),
            actionRegistry: makeActionRegistry(),
            actionAvailability: { _ in false },
            actionHandler: { _, _, completion in
                completion(.failure(.missingOwner("unexpected")))
            }
        ) as? V2SettingsPaneView)
        let identifier = "Stacio.Settings.action.provider.fetchModels"
        let button = try XCTUnwrap(findView(identifier: identifier + ".button", in: pane) as? NSButton)
        XCTAssertFalse(button.isEnabled)
        XCTAssertNotEqual(pane.statusText(for: identifier), "已完成")
    }

    func testNoUnregisteredControllerOwnedControlCanHideInSurface() {
        let registrations = V2SettingsPaneFactory.registrations()
        var visible = Set(registrations.map(\.controlIdentifier))
        XCTAssertTrue(V2SettingsPaneFactory.detectControllerOwnedControls(
            visibleControlIdentifiers: visible,
            registrations: registrations
        ).isEmpty)

        visible.insert("Stacio.Settings.provider.controllerOwnedSaveButton")
        XCTAssertEqual(
            V2SettingsPaneFactory.detectControllerOwnedControls(
                visibleControlIdentifiers: visible,
                registrations: registrations
            ),
            ["Stacio.Settings.provider.controllerOwnedSaveButton"]
        )
    }

    func testRegistrationValidationRejectsDuplicateAndBrokenMetadata() {
        let registrations = V2SettingsPaneFactory.registrations()
        XCTAssertFalse(registrations.isEmpty)
        XCTAssertThrowsError(try V2SettingsPaneFactory.validate(registrations: registrations + [registrations[0]])) {
            XCTAssertEqual(
                $0 as? V2SettingsWindowError,
                .duplicateControlRegistration(registrations[0].controlIdentifier)
            )
        }

        XCTAssertThrowsError(try V2SettingsPaneFactory.validate(registrations: [
            V2SettingsControlRegistration(
                controlIdentifier: "broken.projection",
                kind: .readOnlyProjection(registryID: "x", source: "", updatedAt: nil)
            )
        ])) {
            XCTAssertEqual(
                $0 as? V2SettingsWindowError,
                .readOnlyProjectionMissingMetadata("broken.projection")
            )
        }
    }

    func testPaneUsesNativeGroupedFormNotCardWall() throws {
        let pane = V2SettingsPaneFactory.makeRegistryDrivenPane(
            registry: try makeRegistry(),
            actionRegistry: try makeActionRegistry()
        )
        XCTAssertTrue(pane is NSScrollView)
        XCTAssertTrue((pane as? NSScrollView)?.documentView is NSStackView)
        XCTAssertEqual(pane.accessibilityIdentifier(), "Stacio.Settings.v2Pane")
    }

    private func findView(identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let match = findView(identifier: identifier, in: child) { return match }
        }
        return nil
    }
}
