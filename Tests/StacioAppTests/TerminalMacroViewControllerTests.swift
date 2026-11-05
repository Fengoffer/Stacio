import AppKit
import XCTest
@testable import StacioApp
import StacioCoreBindings

@MainActor
final class TerminalMacroViewControllerTests: XCTestCase {
    func testSearchAndGroupFiltersUseLoadedMacrosWithoutRefreshingProvider() throws {
        let metadataStore = RecordingTerminalMacroViewMetadataStore()
        try metadataStore.setMetadata(TerminalMacroMetadata(group: "部署"), forMacroID: "deploy")
        try metadataStore.setMetadata(TerminalMacroMetadata(group: "监控"), forMacroID: "watch")
        let controller = TerminalMacroViewController(
            metadataStore: metadataStore,
            macroStore: nil,
            userDefaults: UserDefaults(suiteName: "Stacio.TerminalMacroViewControllerTests.\(UUID().uuidString)")!
        )
        var refreshCount = 0
        controller.onRefreshMacros = {
            refreshCount += 1
            return [
                Self.macro(id: "deploy", name: "Deploy app", commands: ["git pull", "systemctl restart app"]),
                Self.macro(id: "watch", name: "Watch logs", commands: ["tail -n 200 app.log"]),
                Self.macro(id: "daily", name: "Daily check", commands: ["whoami"])
            ]
        }

        _ = controller.view
        XCTAssertEqual(refreshCount, 1)

        controller.setSearchQueryForTesting("tail")
        XCTAssertEqual(controller.macroNamesForTesting, ["Watch logs"])
        XCTAssertEqual(refreshCount, 1)

        controller.setSearchQueryForTesting("")
        controller.selectGroupForTesting("部署")
        XCTAssertEqual(controller.macroNamesForTesting, ["Deploy app"])
        XCTAssertEqual(controller.groupTitlesForTesting, ["全部分组", "未分组", "部署", "监控"])
        XCTAssertEqual(refreshCount, 1)
    }

    func testRunPreviewBlocksPlaybackUntilConfirmWhenDefaultSettingIsEnabled() {
        let defaults = UserDefaults(suiteName: "Stacio.TerminalMacroRunPreviewTests.\(UUID().uuidString)")!
        let previewPresenter = RecordingTerminalMacroRunPreviewPresenter()
        let controller = TerminalMacroViewController(
            metadataStore: RecordingTerminalMacroViewMetadataStore(),
            macroStore: nil,
            userDefaults: defaults,
            runPreviewPresenter: previewPresenter
        )
        var playedIDs: [String] = []
        controller.onPlayMacro = { playedIDs.append($0.id) }

        _ = controller.view
        controller.setMacros([Self.macro(id: "deploy", name: "Deploy", commands: ["whoami"])])
        controller.selectMacroRowForTesting(0)
        controller.playSelectedMacroForTesting()

        XCTAssertTrue(playedIDs.isEmpty)
        XCTAssertEqual(previewPresenter.presentedMacroIDs, ["deploy"])

        previewPresenter.confirmLastPreview()
        XCTAssertEqual(playedIDs, ["deploy"])
    }

    func testRunPreviewSettingCanDisableConfirmation() {
        let defaults = UserDefaults(suiteName: "Stacio.TerminalMacroRunPreviewTests.\(UUID().uuidString)")!
        defaults.set(false, forKey: TerminalMacroViewController.runPreviewConfirmationDefaultsKey)
        let previewPresenter = RecordingTerminalMacroRunPreviewPresenter()
        let controller = TerminalMacroViewController(
            metadataStore: RecordingTerminalMacroViewMetadataStore(),
            macroStore: nil,
            userDefaults: defaults,
            runPreviewPresenter: previewPresenter
        )
        var playedIDs: [String] = []
        controller.onPlayMacro = { playedIDs.append($0.id) }

        _ = controller.view
        controller.setMacros([Self.macro(id: "deploy", name: "Deploy", commands: ["whoami"])])
        controller.selectMacroRowForTesting(0)
        controller.playSelectedMacroForTesting()

        XCTAssertEqual(playedIDs, ["deploy"])
        XCTAssertTrue(previewPresenter.presentedMacroIDs.isEmpty)
    }

    private static func macro(id: String, name: String, commands: [String]) -> TerminalMacroRecord {
        TerminalMacroRecord(
            id: id,
            name: name,
            steps: commands.enumerated().map { index, command in
                MacroStep(order: UInt32(index + 1), input: command, delayMs: 300)
            },
            createdAt: "2026-07-03T00:00:00Z",
            updatedAt: "2026-07-03T00:00:00Z"
        )
    }
}

private final class RecordingTerminalMacroViewMetadataStore: TerminalMacroMetadataStoring {
    private var metadataByID: [String: TerminalMacroMetadata] = [:]

    func metadata(forMacroID macroID: String) throws -> TerminalMacroMetadata {
        metadataByID[macroID] ?? TerminalMacroMetadata()
    }

    func setMetadata(_ metadata: TerminalMacroMetadata, forMacroID macroID: String) throws {
        metadataByID[macroID] = metadata
    }
}

private final class RecordingTerminalMacroRunPreviewPresenter: TerminalMacroRunPreviewPresenting {
    private(set) var presentedMacroIDs: [String] = []
    private var pendingConfirmations: [() -> Void] = []

    func presentRunPreview(for macro: TerminalMacroRecord, relativeTo rect: NSRect, of view: NSView, onConfirm: @escaping () -> Void) {
        presentedMacroIDs.append(macro.id)
        pendingConfirmations.append(onConfirm)
    }

    func confirmLastPreview() {
        pendingConfirmations.removeLast()()
    }
}
