import AppKit
import QuartzCore
import XCTest
@testable import StacioApp

@MainActor
final class ActivityShimmerLabelTests: XCTestCase {
    private func mount(_ view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func gradient(in label: ActivityShimmerLabel) throws -> CAGradientLayer {
        try XCTUnwrap(label.layer?.sublayers?.compactMap { $0 as? CAGradientLayer }.first)
    }

    private func assertVisibleShimmer(
        _ label: ActivityShimmerLabel,
        text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let gradient = try gradient(in: label)
        let mask = try XCTUnwrap(gradient.mask as? CATextLayer, file: file, line: line)
        XCTAssertTrue(gradient.superlayer === label.layer, file: file, line: line)
        XCTAssertFalse(gradient.isHidden, file: file, line: line)
        XCTAssertGreaterThan(gradient.frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(gradient.frame.height, 0, file: file, line: line)
        XCTAssertGreaterThan(mask.frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(mask.frame.height, 0, file: file, line: line)
        XCTAssertEqual(mask.string as? String, text, file: file, line: line)
        XCTAssertTrue(label.isShimmering, file: file, line: line)
        XCTAssertTrue(label.hasRunningShimmerAnimationForTesting, file: file, line: line)
        XCTAssertEqual(label.textColor, .clear, file: file, line: line)
        XCTAssertEqual(
            label.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            .clear,
            file: file,
            line: line
        )
    }

    func testShimmerInstallsRunningAnimation() throws {
        let label = ActivityShimmerLabel(labelWithString: "执行中")
        let window = mount(label)
        defer { withExtendedLifetime(window) {} }
        label.setShimmering(true)
        try assertVisibleShimmer(label, text: "执行中")
    }

    func testShimmerEnabledBeforeMountAttachesAfterLayout() throws {
        let label = ActivityShimmerLabel(frame: .zero)
        label.stringValue = "执行中"
        label.setShimmering(true)
        XCTAssertNil(label.window)
        XCTAssertFalse(label.hasRunningShimmerAnimationForTesting)

        let window = mount(label)
        defer { withExtendedLifetime(window) {} }
        try assertVisibleShimmer(label, text: "执行中")
    }

    func testShimmerClearsAnimationAndRestoresColour() throws {
        let label = ActivityShimmerLabel(labelWithString: "执行中")
        label.textColor = .secondaryLabelColor
        let window = mount(label)
        defer { withExtendedLifetime(window) {} }
        label.setShimmering(true)
        label.setShimmering(false)
        XCTAssertFalse(label.isShimmering)
        XCTAssertFalse(label.hasRunningShimmerAnimationForTesting)
        XCTAssertTrue(try gradient(in: label).isHidden)
        XCTAssertEqual(label.textColor, .secondaryLabelColor)
        XCTAssertEqual(
            label.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            .secondaryLabelColor
        )
    }

    func testRepeatedEnableRefreshesAttributedTextWithoutDuplicatingGradient() throws {
        let label = ActivityShimmerLabel(labelWithString: "执行中")
        label.textColor = .secondaryLabelColor
        let window = mount(label)
        defer { withExtendedLifetime(window) {} }
        label.setShimmering(true)
        let firstGradient = try gradient(in: label)
        label.attributedStringValue = NSAttributedString(
            string: "正在等待输出",
            attributes: [.foregroundColor: NSColor.labelColor]
        )
        label.setShimmering(true)
        try assertVisibleShimmer(label, text: "正在等待输出")
        XCTAssertTrue(try gradient(in: label) === firstGradient)
        XCTAssertEqual(label.layer?.sublayers?.filter { $0 is CAGradientLayer }.count, 1)
        XCTAssertEqual(firstGradient.animationKeys(), ["stacio.shimmer"])
        label.setShimmering(false)
        XCTAssertEqual(label.textColor, .secondaryLabelColor)
    }

    func testShimmerStopsWhileDetachedAndResumesWhenMountedAgain() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 160))
        let label = ActivityShimmerLabel(labelWithString: "执行中")
        label.frame = NSRect(x: 10, y: 10, width: 120, height: 20)
        container.addSubview(label)
        let window = mount(container)
        defer { withExtendedLifetime(window) {} }
        label.setShimmering(true)
        try assertVisibleShimmer(label, text: "执行中")
        label.removeFromSuperview()
        XCTAssertFalse(label.hasRunningShimmerAnimationForTesting)
        container.addSubview(label)
        container.layoutSubtreeIfNeeded()
        try assertVisibleShimmer(label, text: "执行中")
    }

    func testTerminalArtifactRunningRepeatedApplyAndCompletion() throws {
        let card = TerminalArtifactView()
        let running = TerminalArtifactPresentation(liveTail: nil, exitCode: nil, durationSeconds: nil)
        // Production calls apply before the card joins the transcript's window.
        card.apply(running, expanded: false)
        let window = mount(card)
        defer { withExtendedLifetime(window) {} }
        let label = try XCTUnwrap(descendant(of: card, label: "执行状态") as? ActivityShimmerLabel)
        try assertVisibleShimmer(label, text: "执行中")
        let firstGradient = try gradient(in: label)

        card.apply(running, expanded: false)
        card.layoutSubtreeIfNeeded()
        try assertVisibleShimmer(label, text: "执行中")
        XCTAssertTrue(try gradient(in: label) === firstGradient)
        XCTAssertEqual(label.layer?.sublayers?.filter { $0 is CAGradientLayer }.count, 1)

        card.apply(
            TerminalArtifactPresentation(liveTail: "done", exitCode: 0, durationSeconds: 2),
            expanded: false
        )
        XCTAssertEqual(label.stringValue, "已结束")
        XCTAssertFalse(label.isShimmering)
        XCTAssertFalse(label.hasRunningShimmerAnimationForTesting)
        XCTAssertTrue(firstGradient.isHidden)
        XCTAssertEqual(label.textColor, .secondaryLabelColor)
    }

    func testTerminalArtifactCompletionWithoutExitCodeStopsShimmer() throws {
        let card = TerminalArtifactView()
        let window = mount(card)
        defer { withExtendedLifetime(window) {} }
        card.apply(
            TerminalArtifactPresentation(liveTail: nil, exitCode: nil, durationSeconds: nil),
            expanded: false
        )
        let label = try XCTUnwrap(descendant(of: card, label: "执行状态") as? ActivityShimmerLabel)
        card.apply(
            TerminalArtifactPresentation(
                liveTail: nil,
                exitCode: nil,
                durationSeconds: nil,
                hasTerminalState: true,
                stateLabel: "已取消"
            ),
            expanded: false
        )
        XCTAssertEqual(label.stringValue, "已取消")
        XCTAssertFalse(label.isShimmering)
        XCTAssertFalse(label.hasRunningShimmerAnimationForTesting)
        XCTAssertEqual(label.textColor, .secondaryLabelColor)
    }

    func testTerminalArtifactNonRunningStatusWithoutTerminalTraceStopsShimmer() throws {
        let card = TerminalArtifactView()
        let window = mount(card)
        defer { withExtendedLifetime(window) {} }
        let label = try XCTUnwrap(descendant(of: card, label: "执行状态") as? ActivityShimmerLabel)
        for status in ["未执行", "未完成", "已完成", "排队", "评估中", "等待批准", "重启后已失效"] {
            card.apply(
                TerminalArtifactPresentation(liveTail: nil, exitCode: nil, durationSeconds: nil),
                expanded: false
            )
            card.apply(
                TerminalArtifactPresentation(
                    liveTail: nil,
                    exitCode: nil,
                    durationSeconds: nil,
                    hasTerminalState: false,
                    stateLabel: status
                ),
                expanded: false
            )
            XCTAssertEqual(label.stringValue, status)
            XCTAssertFalse(label.isShimmering, status)
            XCTAssertFalse(label.hasRunningShimmerAnimationForTesting, status)
            XCTAssertEqual(label.textColor, .secondaryLabelColor, status)
        }
    }

    private func descendant(of view: NSView, label: String) -> NSView? {
        if view.accessibilityLabel() == label { return view }
        for child in view.subviews {
            if let match = descendant(of: child, label: label) { return match }
        }
        return nil
    }
}
