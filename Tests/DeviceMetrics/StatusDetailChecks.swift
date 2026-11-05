import AppKit

// The presentation callback receives the real resource identity; only the
// unrelated app-wide threshold settings are substituted in this harness.
enum DeviceMetricsAlertMetric { case cpuUsage, memoryUsage, diskUsage, networkIO, diskIO }

@main
struct StatusDetailChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let controller = DeviceMetricsStatusDetailViewController()
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let kib: UInt64 = 1_024
        let mib: UInt64 = 1_048_576
        let gib: UInt64 = 1_073_741_824
        let detailedMemory = DeviceMemoryDisplayUsage(
            usedBytes: 6 * gib, totalBytes: 10 * gib, availableBytes: 4 * gib,
            freeBytes: gib, buffersBytes: gib, cachedBytes: 3 * gib,
            swapTotalBytes: 4 * gib, swapFreeBytes: gib
        )
        let processes: [DeviceProcessDisplayInfo] = (1...12).map { index in
            let name = index == 12
                ? "/very/long/path/to/process-with-a-name-that-must-not-hide-percentages"
                : "worker-\(index)"
            let cpu: Double = index == 12 ? 0.535 : Double(index) / 40
            return DeviceProcessDisplayInfo(pid: UInt32(index), name: name, cpuFraction: cpu,
                                            memoryFraction: Double(index) / 100,
                                            residentBytes: UInt64(index) * 64 * mib)
        }
        func snapshot(
            cores: [DeviceCPUCoreDisplayUsage] = [],
            memory: DeviceMemoryDisplayUsage = detailedMemory,
            networks: [DeviceNetworkDisplayRate] = [],
            disks: [DeviceDiskDisplayUsage] = [],
            diskIO: DeviceDiskIODisplayRate? = nil,
            processes: [DeviceProcessDisplayInfo] = processes,
            sshLatencyMilliseconds: Double? = nil
        ) -> DeviceMetricsDisplaySnapshot {
            .init(cpuUsage: 0.42, cpuCoreUsages: cores, memory: memory,
                  networks: networks, disks: disks, diskIO: diskIO, processes: processes,
                  sshLatencyMilliseconds: sshLatencyMilliseconds)
        }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        func fields() -> [NSTextField] { descendants(controller.view).compactMap { $0 as? NSTextField } }
        func bars() -> [DeviceMetricsDetailBar] { descendants(controller.view).compactMap { $0 as? DeviceMetricsDetailBar } }
        func coreBars() -> [DeviceMetricsDetailBar] {
            bars().filter {
                $0.accessibilityIdentifier().hasPrefix("Stacio.Metrics.detail.cpu.")
                    && !$0.accessibilityIdentifier().contains(".process.")
            }
        }
        func cpuProcessIDs() -> [String] {
            bars().map { $0.accessibilityIdentifier() }.filter { $0.contains("cpu.process.") }
        }
        func memoryProcessIDs() -> [String] {
            bars().map { $0.accessibilityIdentifier() }.filter { $0.contains("memory.process.") }
        }
        func latencyField() -> NSTextField {
            fields().first { $0.accessibilityIdentifier() == "Stacio.Metrics.detail.network.latency" }!
        }
        func memoryProcessBytesField(_ pid: UInt32) -> NSTextField? {
            fields().first {
                $0.accessibilityIdentifier() == "Stacio.Metrics.detail.memory.process.\(pid).bytes"
            }
        }
        func bar(_ id: String) -> DeviceMetricsDetailBar {
            guard let result = bars().first(where: { $0.accessibilityIdentifier() == "Stacio.Metrics.detail.\(id)" }) else {
                preconditionFailure("missing bar \(id)")
            }
            return result
        }
        func near(_ actual: Double, _ expected: Double, _ message: String) {
            precondition(abs(actual - expected) < 0.000_001, "\(message): \(actual), expected \(expected)")
        }
        func scrollView() -> NSScrollView {
            descendants(controller.view).compactMap { $0 as? NSScrollView }.first!
        }
        func requireVisible(_ node: NSView, in scroll: NSScrollView, _ message: String) {
            let clip = scroll.contentView
            let bounds = node.superview!.convert(node.alignmentRect(forFrame: node.frame), to: clip)
            precondition(bounds.minY >= clip.bounds.minY - 1 && bounds.maxY <= clip.bounds.maxY + 1,
                         "\(message): \(bounds) / \(clip.bounds)")
        }
        func checkHorizontalLayout() {
            let clip = scrollView().contentView
            for node in descendants(scrollView().documentView!) where node is NSTextField || node is DeviceMetricsDetailBar {
                let bounds = node.superview!.convert(node.alignmentRect(forFrame: node.frame), to: clip)
                precondition(bounds.width > 0 && bounds.height > 0, "zero-size content \(node)")
                precondition(bounds.minX >= -1 && bounds.maxX <= clip.bounds.width + 1,
                             "content exceeds the viewport horizontally: \(bounds), viewport \(clip.bounds)")
                if let field = node as? NSTextField, field.lineBreakMode != .byTruncatingTail,
                   field.lineBreakMode != .byTruncatingMiddle, field.maximumNumberOfLines == 1 {
                    precondition(field.frame.width + 1 >= field.intrinsicContentSize.width,
                                 "untruncated text compressed: \(field.stringValue) \(field.frame) / \(field.intrinsicContentSize)")
                }
            }
        }
        func render(_ title: String, _ sample: DeviceMetricsDisplaySnapshot?,
                    maximumContentHeight: CGFloat = .greatestFiniteMagnitude, contentWidth: CGFloat? = nil) {
            controller.update(title: title, detail: "diagnostic \(title)", snapshot: sample,
                              maximumContentHeight: maximumContentHeight, contentWidth: contentWidth) { value, _ in
                value >= 0.9 ? .systemRed : value >= 0.8 ? .systemOrange : .systemGreen
            }
            window.setContentSize(controller.preferredContentSize)
            controller.view.layoutSubtreeIfNeeded()
            checkHorizontalLayout()
        }
        func screenshot(_ name: String) throws {
            let view = controller.view
            view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                preconditionFailure("cannot capture real AppKit surface")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                preconditionFailure("cannot encode AppKit screenshot")
            }
            let path = "/tmp/stacio-status-detail-\(name).png"
            try png.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT: \(path)")
        }

        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            controller.view.appearance = NSAppearance(named: appearance)
            let cores = [0.27, 0.82, 0.95, 0.42].enumerated().map { DeviceCPUCoreDisplayUsage(index: $0.offset, usage: $0.element) }
            render("CPU", snapshot(cores: cores))
            precondition(coreBars().count == 4)
            near(bar("cpu.0").segments[0].fraction, 0.27, "CPU fraction")
            precondition(bar("cpu.0").segments[0].color == .systemGreen)
            precondition(bar("cpu.1").segments[0].color == .systemOrange)
            precondition(bar("cpu.2").segments[0].color == .systemRed)
            let cpuWidths = coreBars().map { $0.frame.width }
            precondition(cpuWidths.allSatisfy { abs($0 - cpuWidths[0]) < 1 }, "CPU columns differ in width")
            precondition(cpuProcessIDs() == (3...12).reversed().map { "Stacio.Metrics.detail.cpu.process.\($0)" },
                         "CPU Top10 must be sorted and bounded")
            precondition(fields().contains { $0.stringValue == "53.5%" }, "CPU process share must use all four cores")
            near(bar("cpu.process.12").segments[0].fraction, 0.535, "CPU number and bar must use the same capacity")
            precondition(bar("cpu.process.12").segments[0].color == .systemGreen,
                         "process colors must use the same whole-machine capacity as the bar")
            precondition(!fields().contains { $0.stringValue.contains("单核") || $0.stringValue.contains("整机") },
                         "CPU detail must only show the normalized percentage without scale labels")
            precondition(fields().filter { $0.accessibilityIdentifier().hasSuffix(".usage") }.count == 10)
            precondition(!fields().contains { $0.accessibilityIdentifier().hasSuffix(".capacity") },
                         "CPU rows must not retain a second percentage line")
            precondition(controller.preferredContentSize.width == 440)
            try screenshot("cpu-\(suffix)")

            render("内存", snapshot())
            let ram = bar("memory.ram")
            precondition(ram.segments.count == 4)
            for (actual, expected) in zip(ram.segments.map(\.fraction), [0.5, 0.1, 0.3, 0.1]) {
                near(actual, expected, "non-overlapping RAM segment")
            }
            near(bar("memory.swap").segments[0].fraction, 0.75, "swap fraction")
            let top = bars().compactMap { $0.accessibilityIdentifier() }.filter { $0.contains("memory.process.") }
            precondition(top == (3...12).reversed().map { "Stacio.Metrics.detail.memory.process.\($0)" }, "Top10 not sorted and bounded")
            let percentage = fields().first { $0.stringValue == "12.0%" }!
            precondition(percentage.frame.width >= percentage.intrinsicContentSize.width)
            precondition(memoryProcessBytesField(12)?.stringValue == DeviceMetricValueFormatter.bytes(Double(12 * 64 * mib)),
                         "memory Top10 omitted the process resident size")
            precondition(fields().filter {
                $0.accessibilityIdentifier().hasPrefix("Stacio.Metrics.detail.memory.process.")
                    && $0.accessibilityIdentifier().hasSuffix(".bytes")
            }.count == 10, "every memory Top10 row must expose its RSS value")
            precondition(controller.preferredContentSize.width == 440)
            let memoryScroll = scrollView()
            let memoryDocument = memoryScroll.documentView!
            precondition(memoryDocument.bounds.height > memoryScroll.contentView.bounds.height,
                         "two-line memory Top10 fixture must require scrolling")
            memoryScroll.contentView.scroll(to: NSPoint(
                x: 0,
                y: memoryDocument.bounds.height - memoryScroll.contentView.bounds.height
            ))
            memoryScroll.reflectScrolledClipView(memoryScroll.contentView)
            requireVisible(memoryProcessBytesField(3)!, in: memoryScroll,
                           "last RSS row is unreachable at the default 440-point width")
            try screenshot("memory-\(suffix)")

            let disks = [DeviceDiskDisplayUsage(mountPath: "/", usedBytes: 27 * gib, totalBytes: 100 * gib),
                         .init(mountPath: "/vol1", usedBytes: 82 * gib, totalBytes: 100 * gib),
                         .init(mountPath: "/very/long/mount/path/with/a/long-name", usedBytes: 95 * gib, totalBytes: 100 * gib)]
            render("磁盘", snapshot(disks: disks))
            precondition(bars().count == 3)
            precondition(bar("disk.0").segments[0].color == .systemGreen)
            precondition(bar("disk.1").segments[0].color == .systemOrange)
            precondition(bar("disk.2").segments[0].color == .systemRed)
            try screenshot("disk-\(suffix)")
            render("磁盘读写", snapshot(disks: disks,
                                       diskIO: .init(readBytesPerSecond: 12_345_678, writeBytesPerSecond: 987_654)))
            let read = fields().first { $0.accessibilityIdentifier() == "Stacio.Metrics.detail.diskIO.read" }!
            let write = fields().first { $0.accessibilityIdentifier() == "Stacio.Metrics.detail.diskIO.write" }!
            precondition(read.stringValue == DeviceMetricValueFormatter.bytesPerSecond(12_345_678) && read.textColor == .systemGreen)
            precondition(write.stringValue == DeviceMetricValueFormatter.bytesPerSecond(987_654) && write.textColor == .systemCyan)
            precondition(fields().contains { $0.stringValue == "↓ 读取" })
            precondition(fields().contains { $0.stringValue == "↑ 写入" })
            precondition(bars().count == disks.count, "disk I/O detail must retain mounted-disk usage")
            try screenshot("disk-io-\(suffix)")

            let networks = [DeviceNetworkDisplayRate(interfaceName: "bridge-with-a-very-long-interface-name", receiveBytesPerSecond: 0, transmitBytesPerSecond: 0),
                            .init(interfaceName: "enp2s0", receiveBytesPerSecond: 43_700, transmitBytesPerSecond: 109_900)]
            render("上传", snapshot(networks: networks, sshLatencyMilliseconds: 4.2))
            let download = fields().first { $0.accessibilityIdentifier() == "Stacio.Metrics.detail.network.enp2s0.download" }!
            let upload = fields().first { $0.accessibilityIdentifier() == "Stacio.Metrics.detail.network.enp2s0.upload" }!
            precondition(download.stringValue == "↓ \(DeviceMetricValueFormatter.bytesPerSecond(43_700))" && download.textColor == .systemGreen)
            precondition(upload.stringValue == "↑ \(DeviceMetricValueFormatter.bytesPerSecond(109_900))" && upload.textColor == .systemCyan)
            precondition(download.convert(download.bounds, to: controller.view).maxX < upload.convert(upload.bounds, to: controller.view).minX)
            precondition(latencyField().stringValue.contains("4.2") && latencyField().stringValue.contains("ms"))
            precondition(latencyField().textColor == .systemPurple)
            try screenshot("network-\(suffix)")
        }

        // RSS is an independently collected value, not a capacity estimate
        // derived from memoryFraction. Keep unavailable and exact-zero values
        // distinguishable, then ensure a refresh replaces the old rows.
        let rssProcesses: [DeviceProcessDisplayInfo] = [
            .init(pid: 102, name: "small-real-rss", cpuFraction: 0.2, memoryFraction: 0.0014,
                  residentBytes: 512 * kib),
            .init(pid: 103, name: "large-real-rss", cpuFraction: 0.3, memoryFraction: 0.092,
                  residentBytes: 1_503_238_553),
            .init(pid: 104, name: "rss-unavailable", cpuFraction: 0.1, memoryFraction: 0.08,
                  residentBytes: nil),
            .init(pid: 105, name: "rss-zero", cpuFraction: 0.05, memoryFraction: 0.07,
                  residentBytes: 0),
            .init(pid: 107, name: "larger-subprecision-rss", cpuFraction: 0.15, memoryFraction: 0.0011,
                  residentBytes: 768 * kib),
            .init(pid: 108, name: "rss-unavailable-low", cpuFraction: 0.04, memoryFraction: 0.03,
                  residentBytes: nil),
            .init(pid: 109, name: "rss-unavailable-stable", cpuFraction: 0.03, memoryFraction: 0.03,
                  residentBytes: nil)
        ]
        render("内存", snapshot(processes: rssProcesses))
        precondition(fields().filter { $0.stringValue == "0.1%" }.count == 2
                     && fields().contains { $0.stringValue == "9.2%" },
                     "memory Top10 lost its percentage values when RSS was added")
        precondition(memoryProcessIDs() == [103, 107, 102, 105, 104, 108, 109].map {
            "Stacio.Metrics.detail.memory.process.\($0)"
        }, "memory Top10 must sort known RSS descending, keep zero before unknown, then use %MEM and PID")
        precondition(memoryProcessBytesField(102)?.stringValue == DeviceMetricValueFormatter.bytes(Double(512 * kib)))
        precondition(memoryProcessBytesField(107)?.stringValue == DeviceMetricValueFormatter.bytes(Double(768 * kib)),
                     "subprecision percentages must still sort by their exact RSS values")
        precondition(memoryProcessBytesField(103)?.stringValue == DeviceMetricValueFormatter.bytes(1_503_238_553))
        precondition(memoryProcessBytesField(104)?.stringValue == "--")
        precondition(memoryProcessBytesField(105)?.stringValue == DeviceMetricValueFormatter.bytes(0))
        precondition(memoryProcessBytesField(102)?.stringValue
                     != DeviceMetricValueFormatter.bytes(Double(detailedMemory.totalBytes) * 0.0014),
                     "small RSS was incorrectly derived from memory percentage")
        precondition(memoryProcessBytesField(103)?.stringValue
                     != DeviceMetricValueFormatter.bytes(Double(detailedMemory.totalBytes) * 0.092),
                     "large RSS was incorrectly derived from memory percentage")

        let refreshedRSSProcesses: [DeviceProcessDisplayInfo] = [
            .init(pid: 103, name: "large-real-rss", cpuFraction: 0.3, memoryFraction: 0.092,
                  residentBytes: 256 * mib),
            .init(pid: 106, name: "new-zero-rss", cpuFraction: 0.1, memoryFraction: 0.05,
                  residentBytes: 0)
        ]
        render("内存", snapshot(processes: refreshedRSSProcesses))
        precondition(memoryProcessBytesField(103)?.stringValue == DeviceMetricValueFormatter.bytes(Double(256 * mib)),
                     "refresh retained the previous RSS value")
        precondition(memoryProcessBytesField(106)?.stringValue == DeviceMetricValueFormatter.bytes(0))
        for removedPID: UInt32 in [102, 104, 105] {
            precondition(memoryProcessBytesField(removedPID) == nil,
                         "refresh retained removed memory process \(removedPID)")
        }

        render("CPU", snapshot(processes: rssProcesses))
        precondition(cpuProcessIDs().count == rssProcesses.count,
                     "RSS support changed the CPU process ranking")
        precondition(cpuProcessIDs() == [103, 102, 107, 104, 105, 108, 109].map {
            "Stacio.Metrics.detail.cpu.process.\($0)"
        }, "CPU process ranking must remain independent from RSS ordering")
        precondition(!fields().contains {
            $0.accessibilityIdentifier().hasPrefix("Stacio.Metrics.detail.memory.process.")
                && $0.accessibilityIdentifier().hasSuffix(".bytes")
        }, "CPU detail leaked the memory RSS column")
        precondition(!fields().contains {
            [DeviceMetricValueFormatter.bytes(Double(512 * kib)), DeviceMetricValueFormatter.bytes(1_503_238_553)].contains($0.stringValue)
        }, "CPU detail unexpectedly rendered process RSS values")

        // Large core/disk/interface inventories must remain accessible and the
        // stable resource's scroll position must survive the next sample.
        let manyCores = (0..<256).map { DeviceCPUCoreDisplayUsage(index: $0, usage: Double($0 % 100) / 100) }
        render("CPU", snapshot(cores: manyCores))
        precondition(coreBars().count == 256)
        precondition(controller.preferredContentSize.height <= 544)
        let scroll = scrollView()
        precondition(scroll.documentView!.frame.height > scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        scroll.reflectScrolledClipView(scroll.contentView)
        render("CPU", snapshot(cores: manyCores))
        near(scroll.contentView.bounds.origin.y, 200, "same metric scroll retention")
        render("CPU", snapshot(cores: [.init(index: 0, usage: nil), .init(index: 1, usage: 0.2)]))
        precondition(coreBars().count == 2 && fields().contains { $0.stringValue == "--" })
        near(scroll.contentView.bounds.origin.y,
             max(0, scroll.documentView!.bounds.height - scroll.contentView.bounds.height),
             "shrunk content scroll clamp")
        render("CPU", snapshot())
        precondition(coreBars().count == 1 && bar("cpu.total").segments[0].fraction == 0.42)
        precondition(cpuProcessIDs().count == 10, "missing core details must not hide process usage")
        render("CPU", snapshot(processes: [
            .init(pid: 3, name: "third", cpuFraction: 0.216, memoryFraction: 0),
            .init(pid: 2, name: "second", cpuFraction: 0.6, memoryFraction: 0),
            .init(pid: 1, name: "first", cpuFraction: 0.216, memoryFraction: 0)
        ]))
        precondition(cpuProcessIDs() == [2, 1, 3].map { "Stacio.Metrics.detail.cpu.process.\($0)" },
                     "equal CPU usage must retain a stable PID order")
        render("CPU", snapshot(processes: []))
        precondition(cpuProcessIDs().isEmpty && fields().contains { $0.stringValue == "暂无进程数据" },
                     "empty CPU samples retained the previous process list")

        let eightCores = (0..<8).map { DeviceCPUCoreDisplayUsage(index: $0, usage: 0.8) }
        render("CPU", snapshot(cores: eightCores, processes: [
            .init(pid: 201, name: "six-cores", cpuFraction: 0.75, memoryFraction: 0),
            .init(pid: 202, name: "warming-up", cpuFraction: 0, memoryFraction: 0, hasCPUUsage: false)
        ]))
        precondition(fields().contains { $0.stringValue == "75.0%" })
        precondition(!fields().contains { $0.stringValue.contains("600") || $0.stringValue.contains("整机") })
        near(bar("cpu.process.201").segments[0].fraction, 0.75, "six of eight cores must show 75%")
        let pending = fields().first { $0.accessibilityIdentifier() == "Stacio.Metrics.detail.cpu.process.202.usage" }!
        precondition(pending.stringValue == "--", "first sample must not pretend the process is idle")
        near(bar("cpu.process.202").segments[0].fraction, 0, "unavailable samples cannot show CPU activity")
        precondition(bar("cpu.process.202").accessibilityValue() as? String == "--")

        render("CPU", snapshot(cores: eightCores, processes: [
            .init(pid: 202, name: "now-measured", cpuFraction: 0.2, memoryFraction: 0)
        ]))
        precondition(cpuProcessIDs() == ["Stacio.Metrics.detail.cpu.process.202"])
        near(bar("cpu.process.202").segments[0].fraction, 0.2, "fresh interval must replace warm-up state")

        let manyDisks = (0..<80).map { DeviceDiskDisplayUsage(mountPath: "/vol\($0)", usedBytes: 50, totalBytes: 100) }
        render("磁盘", snapshot(disks: manyDisks))
        precondition(bars().count == 80 && scroll.documentView!.frame.height > scroll.contentView.bounds.height)
        render("磁盘", snapshot())
        precondition(bars().isEmpty && fields().contains { $0.stringValue == "暂无已挂载磁盘" })
        let manyNetworks = (0..<100).map { DeviceNetworkDisplayRate(interfaceName: "veth\($0)", receiveBytesPerSecond: 100, transmitBytesPerSecond: 200) }
        render("下载", snapshot(networks: manyNetworks))
        precondition(fields().filter { $0.accessibilityIdentifier().hasSuffix(".download") }.count == 100)
        precondition(scroll.documentView!.frame.height > scroll.contentView.bounds.height)
        render("下载", snapshot())
        precondition(fields().contains { $0.stringValue == "暂无网络接口数据" })
        precondition(!fields().contains { $0.stringValue.hasPrefix("veth") })
        precondition(latencyField().stringValue == "--", "unknown latency must not reuse the previous sample")
        render("下载", snapshot(sshLatencyMilliseconds: 123.4))
        precondition(latencyField().stringValue.contains("123.4"), "latency must remain visible without interface data")
        render("下载", snapshot(sshLatencyMilliseconds: 0))
        precondition(latencyField().stringValue == "<1 ms", "a valid submillisecond RTT must not become unknown")

        render("磁盘读写", snapshot())
        precondition(fields().contains { $0.stringValue == "磁盘读写数据暂不可用" })
        precondition(fields().contains { $0.stringValue == "暂无已挂载磁盘" })
        precondition(!fields().contains { $0.accessibilityIdentifier().hasPrefix("Stacio.Metrics.detail.diskIO.") },
                     "missing I/O data must clear the previous rates")

        // A dashboard card can leave a narrow, short region above or below the
        // chart. Every resource must adapt and still let the last row be reached.
        let constrained = snapshot(cores: manyCores, networks: manyNetworks, disks: manyDisks,
                                   diskIO: .init(readBytesPerSecond: 12_345_678, writeBytesPerSecond: 987_654),
                                   sshLatencyMilliseconds: 4.2)
        for title in ["CPU", "内存", "网络 I/O", "磁盘读写"] {
            render(title, constrained, maximumContentHeight: 180, contentWidth: 280)
            precondition(controller.preferredContentSize.width == 280 && controller.preferredContentSize.height <= 180,
                         "\(title) exceeded the region available outside the charts")
            let clip = scroll.contentView
            let document = scroll.documentView!
            precondition(document.bounds.height > clip.bounds.height, "\(title) fixture must require scrolling")
            clip.scroll(to: NSPoint(x: 0, y: document.bounds.height - clip.bounds.height))
            scroll.reflectScrolledClipView(clip)
            let last = descendants(document).last { $0 is NSTextField || $0 is DeviceMetricsDetailBar }!
            let bounds = last.superview!.convert(last.alignmentRect(forFrame: last.frame), to: clip)
            precondition(bounds.minY >= clip.bounds.minY - 1 && bounds.maxY <= clip.bounds.maxY + 1,
                         "\(title) last row is not reachable in the bounded viewport: \(bounds) / \(clip.bounds)")
            if title == "内存" {
                requireVisible(memoryProcessBytesField(3)!, in: scroll,
                               "last RSS row is unreachable at the constrained 280-point width")
            }
        }

        render("内存", snapshot(memory: .init(usedBytes: 6 * gib, totalBytes: 10 * gib), processes: []))
        precondition(bar("memory.ram").segments.count == 2)
        near(bar("memory.ram").segments[0].fraction, 0.6, "missing detail fallback")
        precondition(!bars().contains { $0.accessibilityIdentifier() == "Stacio.Metrics.detail.memory.swap" })
        precondition(!fields().contains { $0.stringValue.contains("缓存") || $0.stringValue.contains("缓冲区") })
        render("内存", snapshot(memory: .init(usedBytes: 0, totalBytes: 0)))
        precondition(bars().isEmpty && fields().contains { $0.stringValue == "内存信息暂不可用" })
        render("CPU", nil)
        precondition(bars().isEmpty && fields().contains { $0.stringValue == "diagnostic CPU" })

        let invalid = DeviceMetricsDetailBar(segments: [(.nan, .systemGreen), (-2, .systemBlue), (0.8, .systemOrange), (2, .systemRed)], identifier: "validation")
        near(invalid.segments.reduce(0) { $0 + $1.fraction }, 1, "invalid fraction clamp")
        precondition(invalid.segments.allSatisfy { $0.fraction.isFinite && $0.fraction >= 0 })
        print("PASS: graphical status details render real AppKit light/dark layouts; CPU grids and multicore Top10, independent memory RSS values, RAM/swap proportions, disk usage and I/O, network directions and latency, narrow bounded viewports, reachable last rows, stable scroll offsets and empty-state replacement")
    }
}
