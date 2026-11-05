import AppKit

// Only the unrelated byte formatter is substituted. The parser, dashboard row
// mapping, and inventory controls are compiled directly from production.
private enum DeviceMetricValueFormatter {
    static func bytes(_ value: Double) -> String { String(Int(value)) }
}

private final class RowsHarness {
    // PRODUCTION_ROWS
}

@main
struct ProcessRowChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let harness = RowsHarness()
        for (header, fields) in [
            ("PID PPID USER STAT VSZ %VSZ CPU COMMAND", "21 1 root S 1356 1% 7 /sbin/procd --foreground"),
            ("PID PPID USER STAT VSZ %VSZ COMMAND", "21 1 root S 1356 1% /sbin/procd --foreground"),
        ] {
            let processes = DeviceMetricsInventoryParser.processes("__STACIO_PROCESS_TOP__\n" + header + "\n" + fields)
            let rows = harness.processRows(processes)
            precondition(rows.count == 1)
            let row = rows[0]
            precondition(!row.hasCPUUsage && row.tooltip.contains("CPU：不可用"))
            precondition(!row.search.contains("7.0"), "CPU core leaked into the search index")
            precondition(row.title == "/sbin/procd --foreground" && row.pid == 21)
            precondition(row.buttons.count == 4 && row.buttons.allSatisfy { !$0.isEnabled }, "Missing identity must disable mutations")
            precondition(!row.hasMemoryUsage && row.tooltip.contains("内存：--") && row.tooltip.contains("RSS：--"), "VSZ must not appear as resident memory")
        }
        let measured = DeviceMetricsInventoryParser.processes("""
        __STACIO_PROCESS_TOP__
        PID PPID USER STAT VSZ %VSZ CPU %CPU COMMAND
        22 1 root S 1356 1% 7 0.0 /sbin/idle
        23 1 root R 1356 1% 2 12.5 /sbin/worker
        """)
        let rows = harness.processRows(measured)
        precondition(rows.count == 2 && rows.allSatisfy(\.hasCPUUsage))
        precondition(rows[0].cpu == 0 && rows[0].tooltip.contains("CPU：0.0%"))
        precondition(rows[1].cpu == 12.5 && rows[1].tooltip.contains("CPU：12.5%"))
        precondition(rows[1].filter == 1 && rows[1].tone == .success)
        var identified = measured[1]
        identified.processIdentity = "100:20"
        let identifiedRow = harness.processRows([identified])[0]
        precondition(identifiedRow.buttons.allSatisfy(\.isEnabled))
        for button in identifiedRow.buttons {
            guard case let .process(_, pid, identity) = button.action else { preconditionFailure("Wrong action") }
            precondition(pid == identified.pid && identity == "100:20", "Clicked row identity must travel with every action")
        }
        let memoryPanel = DeviceMetricsInventoryPanel(segment: 1)
        memoryPanel.update([
            .init(id: "unknown", title: "unknown", subtitle: "", badge: "", tone: .normal, filter: 0, search: "", memory: 0, hasMemoryUsage: false, pid: 1),
            .init(id: "zero", title: "zero", subtitle: "", badge: "", tone: .normal, filter: 0, search: "", memory: 0, hasMemoryUsage: true, pid: 2),
            .init(id: "known", title: "known", subtitle: "", badge: "", tone: .normal, filter: 0, search: "", memory: 50, hasMemoryUsage: true, pid: 3)
        ])
        for _ in 0..<2 {
            memoryPanel.sortControl.selectedSegment = 1
            memoryPanel.sortControl.sendAction(memoryPanel.sortControl.action, to: memoryPanel.sortControl.target)
            precondition(memoryPanel.visibleRows.last?.id == "unknown", "Unknown memory stays last in both sort directions")
        }
        print("PASS: missing CPU/memory stay unavailable, process identity gates actions and survives row mapping, and unknown memory sorts last")
    }
}
