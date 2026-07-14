import AppKit
import XCTest
@testable import StacioApp
import StacioCoreBindings

@MainActor
final class MultiExecCoordinatorTests: XCTestCase {
    func testTargetPreviewTreatsTrimmedProductionEnvironmentAsProduction() {
        let rows = MultiExecTargetPreviewRow.rows(for: [
            MultiExecTarget(
                id: "term_prod",
                label: "生产 API",
                environment: " Production ",
                enabled: true
            )
        ])

        XCTAssertEqual(rows.map(\.requiresProductionConfirmation), [true])
        XCTAssertEqual(rows.map(\.environmentLabel), [L10n.MultiExec.production])
    }

    func testSessionSelectionTargetsStartAtTopOfScrollView() throws {
        let form = MultiExecSessionSelectionForm(targets: [
            MultiExecTarget(id: "term_one", label: "172.16.10.250", environment: "development", enabled: true),
            MultiExecTarget(id: "term_two", label: "172.16.10.250", environment: "development", enabled: true)
        ])
        form.view.frame = NSRect(x: 0, y: 0, width: 520, height: 180)
        form.view.layoutSubtreeIfNeeded()

        let firstCheckbox = try XCTUnwrap(
            form.view.firstSubview(withIdentifier: "Stacio.MultiExec.sessionTarget.term_one") as? NSButton
        )
        let scrollView = try XCTUnwrap(firstCheckbox.enclosingScrollView)
        let checkboxFrameInClip = firstCheckbox.convert(firstCheckbox.bounds, to: scrollView.contentView)
        let clipBounds = scrollView.contentView.bounds
        let topGap = scrollView.contentView.isFlipped
            ? checkboxFrameInClip.minY - clipBounds.minY
            : clipBounds.maxY - checkboxFrameInClip.maxY

        XCTAssertLessThanOrEqual(topGap, 12)
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
