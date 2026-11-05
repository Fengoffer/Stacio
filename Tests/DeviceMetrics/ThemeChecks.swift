import AppKit

// Only the app-wide palette is substituted. The dashboard's traversal and
// role-resolution methods and inventory UI are compiled from production.
private enum StacioDesignSystem {
    struct Theme {
        let primaryTextColor = NSColor.labelColor
        let secondaryTextColor = NSColor.secondaryLabelColor
        let accentColor = NSColor.controlAccentColor
        let successColor = NSColor.systemGreen
        let dangerColor = NSColor.systemRed
    }
    static let theme = Theme()
    static func refreshDynamicLayerColors(in view: NSView) { }
    static func resolvedColor(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        return resolved
    }
}

// PRODUCTION_ROLE

private final class ThemeHarness {
    final class Chart {
        var invalidations = 0
        func invalidateForEffectiveAppearanceChange() { invalidations += 1 }
    }
    var isViewLoaded = true
    let view: NSView
    var overviewSections: [NSView] = []
    let cpuLineChart = Chart()
    let memoryLineChart = Chart()
    let networkIOLineChart = Chart()
    let diskIOLineChart = Chart()
    init(view: NSView) { self.view = view }
    func refreshMetricsSurfaceColors(in view: NSView, appearance: NSAppearance) { }
    func invalidateDiskPieViewsForAppearanceChange(in view: NSView) { }
    // PRODUCTION_METHODS
}

@main
struct ThemeChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        let panel = DeviceMetricsInventoryPanel(segment: 3)
        panel.frame = root.bounds
        root.addSubview(panel)
        let rows: [DeviceMetricsInventoryPanel.Row] = [
            .init(id: "active", title: "api.service", subtitle: "API service", badge: "active", tone: .success, filter: 1, search: "api"),
            .init(id: "failed", title: "ups.service", subtitle: "UPS service", badge: "failed", tone: .warning, filter: 2, search: "ups"),
        ]
        panel.update(rows)
        panel.layoutSubtreeIfNeeded()
        panel.table.layoutSubtreeIfNeeded()
        guard let activeCell = panel.table.view(atColumn: 0, row: 0, makeIfNecessary: true),
              let failedCell = panel.table.view(atColumn: 0, row: 1, makeIfNecessary: true)
        else { preconditionFailure("inventory cells were not created") }
        func labels(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
        }
        guard let active = labels(in: activeCell).first(where: { $0.stringValue == "active" }),
              let failed = labels(in: failedCell).first(where: { $0.stringValue == "failed" }),
              let title = labels(in: activeCell).first(where: { $0.stringValue == "api.service" })
        else { preconditionFailure("inventory text was not created") }
        precondition(activeCell.isDescendant(of: panel) && failedCell.isDescendant(of: panel))
        let titleColor = title.textColor
        let searchColor = panel.searchField.textColor
        let overview = NSTextField(labelWithString: "CPU threshold exceeded")
        overview.tag = DeviceMetricsTextColorRole.danger.rawValue
        root.addSubview(overview)
        let harness = ThemeHarness(view: root)
        let retainedOverview = NSView()
        let retainedTitle = NSTextField(labelWithString: "System")
        retainedTitle.tag = DeviceMetricsTextColorRole.primary.rawValue
        retainedOverview.addSubview(retainedTitle)
        let retainedThreshold = NSTextField(labelWithString: "High CPU")
        retainedThreshold.tag = DeviceMetricsTextColorRole.danger.rawValue
        retainedOverview.addSubview(retainedThreshold)
        harness.overviewSections = [retainedOverview]
        root.addSubview(retainedOverview)
        harness.refreshThemeForEffectiveAppearanceChange(appearance: NSAppearance(named: .aqua)!)
        retainedOverview.removeFromSuperview()

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            let appearance = NSAppearance(named: appearanceName)!
            root.appearance = appearance
            harness.refreshThemeForEffectiveAppearanceChange(appearance: appearance)
            precondition(active.textColor == .systemGreen, "active badge lost its success color")
            precondition(failed.textColor == .systemOrange, "failed badge lost its warning color")
            precondition(title.textColor == titleColor, "inventory title color was overridden")
            precondition(panel.searchField.textColor == searchColor, "search text color was overridden")
            precondition(overview.textColor == harness.color(for: .danger, appearance: appearance), "overview threshold role was not refreshed")
            precondition(retainedOverview.superview == nil, "overview must be off-tree during appearance changes")
            precondition(retainedTitle.textColor == harness.color(for: .primary, appearance: appearance), "detached overview title kept the old appearance")
            precondition(retainedThreshold.textColor == harness.color(for: .danger, appearance: appearance), "detached threshold lost its semantic color")
            root.addSubview(retainedOverview)
            precondition(harness.overviewSections[0] === retainedOverview && retainedTitle.superview === retainedOverview)
            precondition(retainedTitle.textColor == harness.color(for: .primary, appearance: appearance), "reattached overview title has the wrong appearance")
            retainedOverview.removeFromSuperview()

            // Stable service/container snapshots deliberately retain their cells.
            // A refresh must not be needed to recover correct semantic colors.
            panel.update(rows)
            precondition(panel.table.view(atColumn: 0, row: 0, makeIfNecessary: true) === activeCell)
            precondition(active.textColor == .systemGreen && failed.textColor == .systemOrange)
            precondition(title.textColor == titleColor && panel.searchField.textColor == searchColor)
        }
        precondition(harness.cpuLineChart.invalidations == 4 && harness.memoryLineChart.invalidations == 4)
        print("PASS: inventory semantic colors survive light/dark changes; retained overview titles and threshold roles refresh while off-tree without replacing controls")
    }
}
