import AppKit
import XCTest
@testable import StacioApp

@MainActor
final class SessionSidebarSessionFormTests: XCTestCase {
    func testAgentAuthHidesPrivateKeyAndSecretRows() throws {
        let form = SessionSidebarSessionForm(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )

        form.selectAuthModeForTesting(.agent)

        XCTAssertTrue(form.privateKeyRowIsHiddenForTesting)
        XCTAssertTrue(form.credentialSecretRowIsHiddenForTesting)
    }

    func testPasswordAuthShowsOnlyPasswordSecretRow() throws {
        let form = SessionSidebarSessionForm(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )

        form.selectAuthModeForTesting(.password)

        XCTAssertTrue(form.privateKeyRowIsHiddenForTesting)
        XCTAssertFalse(form.credentialSecretRowIsHiddenForTesting)
        XCTAssertEqual(form.secretLabelForTesting, "密码")
    }

    func testPrivateKeyAuthShowsPrivateKeyAndPassphraseRows() throws {
        let form = SessionSidebarSessionForm(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )

        form.selectAuthModeForTesting(.privateKey)

        XCTAssertFalse(form.privateKeyRowIsHiddenForTesting)
        XCTAssertFalse(form.credentialSecretRowIsHiddenForTesting)
        XCTAssertEqual(form.secretLabelForTesting, "口令")
    }

    func testSessionEditorFieldsUseStandardMacControlHeightAndNativeBezel() {
        let form = SessionSidebarSessionForm(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )

        XCTAssertGreaterThanOrEqual(form.textFieldHeightsForTesting.min() ?? 0, 28)
        XCTAssertTrue(form.textFieldsUseNativeBezelForTesting)
        XCTAssertTrue(form.editableTextFieldsUseReadableInsetsForTesting)
        XCTAssertGreaterThanOrEqual(form.authPopupHeightForTesting, 30)
    }

    func testSessionEditorFieldsUseSystemTextFieldBezelInsteadOfCustomPaintedBoxes() {
        let form = SessionSidebarSessionForm(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )

        XCTAssertTrue(form.textFieldsUseSystemRoundedBezelForTesting)
        XCTAssertFalse(form.textFieldsUseCustomLayerBackgroundForTesting)
        XCTAssertFalse(form.textFieldsUseCustomLayerBorderForTesting)
        XCTAssertTrue(form.textFieldsFollowSystemAppearanceForTesting)
    }

    func testSessionEditorUsesKeyboardNavigationOrderAcrossVisibleFields() {
        let form = SessionSidebarSessionForm(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )

        XCTAssertEqual(
            form.keyViewLoopIdentifiersForTesting,
            [
                "Stacio.SessionEditor.name",
                "Stacio.SessionEditor.host",
                "Stacio.SessionEditor.port",
                "Stacio.SessionEditor.username",
                "Stacio.SessionEditor.auth",
                "Stacio.SessionEditor.secret",
                "Stacio.SessionEditor.tags",
                "Stacio.SessionEditor.tagColorPreset.0",
                "Stacio.SessionEditor.tagColorPreset.1",
                "Stacio.SessionEditor.tagColorPreset.2",
                "Stacio.SessionEditor.tagColorPreset.3",
                "Stacio.SessionEditor.tagColorPreset.4",
                "Stacio.SessionEditor.tagColorPreset.5",
                "Stacio.SessionEditor.tagColorCustom"
            ]
        )
    }

    func testTagColorPresetButtonsUseMacMinimumHitArea() {
        let form = SessionSidebarSessionForm(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )

        XCTAssertTrue(form.tagColorPresetButtonsUseMinimumHitAreaForTesting)
    }

    func testSessionEditorUsesMacFormSpacingWithReadableLabelAndInputRelationship() {
        let form = SessionSidebarSessionForm(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )

        XCTAssertGreaterThanOrEqual(form.labelColumnWidthForTesting, 82)
        XCTAssertGreaterThanOrEqual(form.fieldColumnWidthForTesting, 240)
        XCTAssertLessThanOrEqual(form.fieldColumnWidthForTesting, 260)
        XCTAssertGreaterThanOrEqual(form.formColumnSpacingForTesting, 14)
        XCTAssertGreaterThanOrEqual(form.formRowSpacingForTesting, 11)
        XCTAssertTrue(form.formLabelsUseTrailingAlignmentForTesting)
    }

    func testSessionEditorLabelsAndFieldsShareAStableVisualCenter() {
        let form = SessionSidebarSessionForm(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )

        XCTAssertTrue(form.formRowsUseCenterYPlacementForTesting, "Rows should center labels and controls vertically.")
        XCTAssertTrue(form.formLabelsHaveStableControlHeightForTesting, "Labels should reserve the same height as text fields.")
        XCTAssertTrue(form.formLabelsUseFieldAlignedVerticalCenterForTesting, "Labels should stay single-line and trailing aligned.")
    }

    func testSessionEditorLabelsAndInputsAreGeometricallyAlignedAfterLayout() throws {
        let form = SessionSidebarSessionForm(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )

        form.layoutForTesting()

        XCTAssertTrue(form.formLabelAndFieldCentersAreAlignedForTesting)
        XCTAssertTrue(form.formLabelTextAndInputContentCentersAreAlignedForTesting)
        let fields = try [
            "Stacio.SessionEditor.name",
            "Stacio.SessionEditor.host",
            "Stacio.SessionEditor.port",
            "Stacio.SessionEditor.username",
            "Stacio.SessionEditor.auth",
            "Stacio.SessionEditor.secret",
            "Stacio.SessionEditor.tags"
        ].map { try XCTUnwrap(form.view.firstSubview(withIdentifier: $0)) }
        let leadingEdges = fields.map { $0.convert($0.bounds, to: form.view).minX }
        let leadingSpread = (leadingEdges.max() ?? 0) - (leadingEdges.min() ?? 0)
        XCTAssertLessThanOrEqual(leadingSpread, 8, "leading edges: \(leadingEdges)")
    }

    func testSessionEditorUsesCompactStableMacFormControls() {
        let form = SessionSidebarSessionForm(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )

        form.layoutForTesting()

        XCTAssertTrue(form.formControlsUseStableMacFormHeightForTesting)
        XCTAssertTrue(form.formLabelAndFieldCentersAreAlignedForTesting)
        XCTAssertTrue(form.formLabelTextAndInputContentCentersAreAlignedForTesting)
    }

    func testEditableFieldsKeepStandardTextEditingAffordancesForCopyAndPaste() {
        let form = SessionSidebarSessionForm(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )

        XCTAssertTrue(form.editableTextFieldsAllowSelectionForTesting)
        XCTAssertTrue(form.editableTextFieldsAcceptEditingForTesting)
        XCTAssertTrue(form.editableTextFieldsUseFieldEditorForTesting)
    }

    func testNewSessionDefaultsUsernameEmptyAndPasswordAuthSelected() throws {
        let form = SessionSidebarSessionForm(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )

        XCTAssertEqual(form.usernameValueForTesting, "")
        XCTAssertEqual(form.selectedAuthModeForTesting, .password)
        XCTAssertFalse(form.credentialSecretRowIsHiddenForTesting)
        XCTAssertEqual(form.secretLabelForTesting, "密码")
    }

    func testHostFilledFirstAutofillsEmptyNameWithoutOverwritingCustomName() {
        let form = SessionSidebarSessionForm(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )

        form.typeHostForTesting("api.example.com")

        XCTAssertEqual(form.nameValueForTesting, "api.example.com")

        form.typeNameForTesting("生产 API")
        form.typeHostForTesting("db.example.com")

        XCTAssertEqual(form.nameValueForTesting, "生产 API")
    }

    func testTagRowIncludesNativeColorChooser() {
        let form = SessionSidebarSessionForm(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )

        XCTAssertFalse(form.tagColorWellIsHiddenForTesting)
        XCTAssertFalse(form.tagColorRowIsHiddenForTesting)
        XCTAssertEqual(form.tagColorAccessibilityLabelForTesting, "标签颜色")
        XCTAssertEqual(form.tagColorSampleTextForTesting, "")
        XCTAssertEqual(form.tagColorPresetCountForTesting, 6)
        XCTAssertEqual(form.tagColorCustomWellAccessibilityIdentifierForTesting, "Stacio.SessionEditor.tagColorCustom")
    }

    func testTagColorPresetSelectionUpdatesSavedColor() throws {
        let form = SessionSidebarSessionForm(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )

        form.selectTagColorPresetForTesting(index: 3)

        XCTAssertEqual(form.selectedTagColorHexForTesting, "#FF3B30")
    }

    func testValidationFeedbackDisablesSaveWithoutShowingInitialErrorBeforeEditing() {
        let form = SessionSidebarSessionForm(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )
        let saveButton = NSButton(title: "保存", target: nil, action: nil)
        form.bindSaveButtonForTesting(saveButton)

        XCTAssertFalse(saveButton.isEnabled)
        XCTAssertEqual(form.validationMessageForTesting, "")
        XCTAssertTrue(form.validationRowIsHiddenForTesting)

        form.markEditedForTesting()

        XCTAssertFalse(saveButton.isEnabled)
        XCTAssertEqual(form.validationMessageForTesting, "名称不能为空。")
        XCTAssertFalse(form.validationRowIsHiddenForTesting)

        form.setValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "API",
                host: "api.example.com",
                port: "22",
                username: "deploy",
                authMode: .agent,
                privateKeyPath: "",
                credentialSecret: "",
                tags: ""
            )
        )

        XCTAssertTrue(saveButton.isEnabled)
        XCTAssertEqual(form.validationMessageForTesting, "")
        XCTAssertTrue(form.validationRowIsHiddenForTesting)
    }

    func testPasswordAuthAllowsBlankPasswordBeforeSaveIsEnabled() throws {
        let form = SessionSidebarSessionForm(
            existingSession: nil,
            selectedFolderID: nil,
            draftFactory: SessionSidebarSessionDraftFactory(defaultUsername: { "local" })
        )
        let saveButton = NSButton(title: "保存", target: nil, action: nil)
        form.bindSaveButtonForTesting(saveButton)

        form.setValuesForTesting(
            SessionSidebarSessionFormValues(
                name: "API",
                host: "api.example.com",
                port: "22",
                username: "",
                authMode: .password,
                privateKeyPath: "",
                credentialSecret: "",
                tags: ""
            )
        )

        XCTAssertTrue(saveButton.isEnabled)
        XCTAssertEqual(form.validationMessageForTesting, "")

        let draft = try XCTUnwrap(try form.draft())
        XCTAssertNil(draft.username)
        XCTAssertNil(draft.credentialId)
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
