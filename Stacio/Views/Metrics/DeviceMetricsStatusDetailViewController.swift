import AppKit

/// A single, reusable hover surface. It only renders the latest shared sample;
/// opening it never starts a remote command or a second polling timer.
@MainActor
final class DeviceMetricsStatusDetailViewController: NSViewController {
    enum Presentation { case popover, floating }
    private let presentation: Presentation
    private let surfaceEnvironment: GlassCapabilityEnvironment?
    private let titleLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let document = DeviceMetricsDetailDocumentView()
    private let body = NSStackView()
    private var bodyHeight: NSLayoutConstraint!
    private var bodyWidth: NSLayoutConstraint!
    private var currentKey: String?
    private var diagnosticText = ""
    var onHoverChanged: ((Bool) -> Void)?

    var visibleTextForTesting: String { titleLabel.stringValue + " " + diagnosticText }

    init(presentation: Presentation = .popover, surfaceEnvironment: GlassCapabilityEnvironment? = nil) {
        self.presentation = presentation
        self.surfaceEnvironment = surfaceEnvironment
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func loadView() {
        let content = DeviceMetricsDetailSurface()
        content.onHoverChanged = { [weak self] inside in self?.onHoverChanged?(inside) }
        let root = makeSurface(content: content)
        root.setAccessibilityIdentifier("Stacio.Metrics.statusBar.detailPopover")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = document
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 14
        body.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        content.addSubview(titleLabel)
        content.addSubview(scrollView)
        bodyHeight = scrollView.heightAnchor.constraint(equalToConstant: 40)
        bodyWidth = body.widthAnchor.constraint(equalToConstant: 320)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            bodyHeight,
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor),
            bodyWidth
        ])
        view = root
    }

    private func makeSurface(content: NSView) -> NSView {
        // NSPopover owns its material, outline and arrow. A second effect view
        // inside it creates an extra rectangular surface at the rounded edge.
        guard presentation == .floating else { return content }
        let radius: CGFloat = 14
        let surface = GlassCapabilityAdapter.makeInteractiveSurface(
            fallbackMaterial: .popover, cornerRadius: radius, environment: surfaceEnvironment)
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            // Use the supported content slot: arbitrary glass subviews don't
            // have a guaranteed position relative to the material's layers.
            glass.contentView = content
        } else {
            surface.addSubview(content)
            if let effect = surface as? NSVisualEffectView {
                effect.blendingMode = .behindWindow
                // A CALayer corner alone doesn't mask the backdrop material.
                // The native material mask also gives the window a round shadow.
                let side = radius * 2 + 1
                let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                    NSColor.black.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                    return true
                }
                mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
                mask.resizingMode = .stretch
                effect.maskImage = mask
            }
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            content.topAnchor.constraint(equalTo: surface.topAnchor),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        return surface
    }

    func update(title: String, detail: String, snapshot: DeviceMetricsDisplaySnapshot?,
                maximumContentHeight: CGFloat = .greatestFiniteMagnitude, contentWidth: CGFloat? = nil,
                usageColor: (Double, DeviceMetricsAlertMetric) -> NSColor) {
        loadViewIfNeeded()
        let previousOffset = currentKey == title ? scrollView.contentView.bounds.origin.y : 0
        currentKey = title
        diagnosticText = detail
        view.setAccessibilityHelp(detail)
        body.arrangedSubviews.forEach { body.removeArrangedSubview($0); $0.removeFromSuperview() }
        var width: CGFloat
        switch title {
        case "CPU": titleLabel.stringValue = "CPU 核心使用率"; width = 440
        case "内存": titleLabel.stringValue = "内存详情"; width = 440
        case "磁盘": titleLabel.stringValue = "已挂载磁盘"; width = 380
        case "上传", "下载", "网络 I/O": titleLabel.stringValue = "网络接口"; width = 400
        case "磁盘读写": titleLabel.stringValue = "磁盘读写"; width = 440
        default: titleLabel.stringValue = title; width = 360
        }
        if let contentWidth { width = max(240, contentWidth) }
        if let snapshot {
            switch title {
            case "CPU": cpu(snapshot, usageColor: usageColor)
            case "内存": memory(snapshot)
            case "磁盘": disks(snapshot.disks, usageColor: usageColor)
            case "上传", "下载", "网络 I/O": networks(snapshot.networks, latency: snapshot.sshLatencyMilliseconds)
            case "磁盘读写": diskIO(snapshot, usageColor: usageColor)
            default: addText(detail)
            }
        } else { addText(detail) }
        // Fit the document separately from the bounded viewport, so long core,
        // disk and interface lists remain reachable instead of being clipped.
        let headerHeight = ceil(titleLabel.intrinsicContentSize.height) + 46
        bodyWidth.constant = width - 40
        body.layoutSubtreeIfNeeded()
        let height = max(20, ceil(body.fittingSize.height))
        bodyHeight.constant = min(480, height, max(20, maximumContentHeight - headerHeight))
        preferredContentSize = NSSize(width: width, height: bodyHeight.constant + headerHeight)
        // The popover owns the hosted root frame. Resizing it here races
        // AppKit's deferred window sizing and can restore the previous tab's
        // small window over the new content on the next run-loop turn.
        if view.window == nil { view.setFrameSize(preferredContentSize) }
        document.setFrameSize(NSSize(width: width - 32, height: height))
        view.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(previousOffset, max(0, height - bodyHeight.constant))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func cpu(_ snapshot: DeviceMetricsDisplaySnapshot,
                     usageColor: (Double, DeviceMetricsAlertMetric) -> NSColor) {
        let cores = snapshot.cpuCoreUsages
        if cores.isEmpty {
            let fraction = snapshot.cpuUsage
            addUsageRow(name: "CPU", value: fraction.map(Self.percent) ?? "--", fraction: fraction ?? 0,
                        color: usageColor(fraction ?? 0, .cpuUsage), identifier: "cpu.total")
        }
        for start in stride(from: 0, to: cores.count, by: 4) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 12
            for core in cores[start..<min(start + 4, cores.count)] {
                let color = core.usage.map { usageColor($0, .cpuUsage) } ?? NSColor.secondaryLabelColor
                let bar = DeviceMetricsDetailBar(segments: [(core.usage ?? 0, color)], identifier: "cpu.\(core.index)")
                let column = vertical([
                    label("Core \(core.index)", color: .secondaryLabelColor), bar,
                    label(core.usage.map(Self.percent) ?? "--", color: color, size: 13)
                ], spacing: 7)
                column.alignment = .centerX
                bar.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
                row.addArrangedSubview(column)
            }
            // Keep the final partial row aligned with the preceding core grid.
            for _ in min(start + 4, cores.count)..<(start + 4) { row.addArrangedSubview(NSView()) }
            add(row)
        }
        addTopProcesses(snapshot.processes, resource: "CPU", identifier: "cpu", fraction: \.cpuFraction) {
            usageColor($0, .cpuUsage)
        }
    }

    private func memory(_ snapshot: DeviceMetricsDisplaySnapshot) {
        let memory = snapshot.memory
        let total = Double(memory.totalBytes)
        guard total > 0 else { addText("内存信息暂不可用"); return }
        let green = NSColor.systemGreen
        var parts: [(String, Double, NSColor)]
        if let free = memory.freeBytes, let buffers = memory.buffersBytes, let cache = memory.cachedBytes {
            // MemAvailable includes reclaimable pages. Do not stack the original
            // total-MemAvailable reading on top of buffers/cache (double counting).
            let f = min(Double(free), total)
            let b = min(Double(buffers), total - f)
            let c = min(Double(cache), total - f - b)
            parts = [("已用", total - f - b - c, green), ("缓冲区", b, .systemBlue),
                     ("缓存", c, .systemOrange), ("空闲", f, .tertiaryLabelColor)]
        } else {
            let used = min(Double(memory.usedBytes), total)
            parts = [("已用", used, green), ("可用", total - used, .tertiaryLabelColor)]
        }
        add(DeviceMetricsDetailBar(segments: parts.map { ($0.1 / total, $0.2) }, identifier: "memory.ram", height: 12))
        addLegends(parts)
        if let swapTotal = memory.swapTotalBytes, let swapFree = memory.swapFreeBytes {
            let free = min(swapFree, swapTotal)
            let used = swapTotal - free
            add(label("交换空间", color: .secondaryLabelColor))
            if swapTotal > 0 {
                add(DeviceMetricsDetailBar(segments: [(Double(used) / Double(swapTotal), .systemPink)], identifier: "memory.swap", height: 12))
                addLegends([("已用", Double(used), .systemPink), ("空闲", Double(free), .tertiaryLabelColor)])
                add(label("总计：\(Self.bytes(Double(swapTotal)))", color: .secondaryLabelColor, size: 11))
            } else { addText("未启用交换空间") }
        }
        addTopProcesses(snapshot.processes, resource: "内存", identifier: "memory", fraction: \.memoryFraction) { _ in green }
    }

    private func addTopProcesses(_ allProcesses: [DeviceProcessDisplayInfo], resource: String,
                                 identifier: String, fraction: KeyPath<DeviceProcessDisplayInfo, Double>,
                                 color: (Double) -> NSColor) {
        add(label("\(resource)占用前十进程", color: .secondaryLabelColor))
        let processes = allProcesses.sorted {
            if identifier == "cpu", $0.hasCPUUsage != $1.hasCPUUsage { return $0.hasCPUUsage }
            if identifier == "memory", $0.residentBytes != $1.residentBytes {
                switch ($0.residentBytes, $1.residentBytes) {
                case let (left?, right?): return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            return $0[keyPath: fraction] == $1[keyPath: fraction] ? $0.pid < $1.pid : $0[keyPath: fraction] > $1[keyPath: fraction]
        }.prefix(10)
        if processes.isEmpty { addText("暂无进程数据"); return }
        let numbers = processes.map { process in
            let number = label(identifier == "cpu" && !process.hasCPUUsage ? "--"
                : String(format: "%.1f%%", process[keyPath: fraction] * 100), color: .secondaryLabelColor, size: 11)
            number.setAccessibilityIdentifier("Stacio.Metrics.detail.\(identifier).process.\(process.pid).usage")
            return number
        }
        let amounts: [NSTextField] = identifier == "memory" ? processes.map { process in
            let text = process.residentBytes.map { Self.bytes(Double($0)) } ?? "--"
            let amount = label(text, color: .secondaryLabelColor, size: 10)
            amount.setAccessibilityIdentifier("Stacio.Metrics.detail.memory.process.\(process.pid).bytes")
            amount.setAccessibilityLabel("\(process.name)，当前驻留内存 \(text)")
            amount.toolTip = process.residentBytes.map { "当前驻留内存（RSS）：\($0) 字节" } ?? "当前采样未提供驻留内存大小"
            return amount
        } : []
        let numberWidth = max(46, ceil((numbers + amounts).map(\.intrinsicContentSize.width).max() ?? 0))
        let rows = vertical([], spacing: 8)
        for (index, pair) in zip(processes, numbers).enumerated() {
            let (process, number) = pair
            let value = process[keyPath: fraction]
            number.alignment = .right
            number.widthAnchor.constraint(equalToConstant: numberWidth).isActive = true
            let barValue: Double
            if identifier == "cpu" {
                barValue = process.hasCPUUsage ? value : 0
                number.toolTip = process.hasCPUUsage
                    ? "最近两次采样之间的 CPU 占用：\(number.stringValue)"
                    : "等待有效的连续采样；新进程或无效计数暂不显示 CPU 占用。"
            } else { barValue = value }
            let barColor = identifier == "cpu" && !process.hasCPUUsage
                ? NSColor.tertiaryLabelColor : color(barValue)
            let bar = DeviceMetricsDetailBar(segments: [(barValue, barColor)], identifier: "\(identifier).process.\(process.pid)", height: 5)
            if identifier == "cpu" {
                bar.setAccessibilityValue(number.stringValue)
                bar.toolTip = number.toolTip
            }
            let name = label(process.name, color: .labelColor, size: 11, monospaced: true)
            name.lineBreakMode = .byTruncatingTail
            name.toolTip = "\(process.name) · PID \(process.pid)"
            name.widthAnchor.constraint(equalToConstant: 126).isActive = true
            let reading: NSView
            if identifier == "memory" {
                let amount = amounts[index]
                amount.alignment = .right
                amount.widthAnchor.constraint(equalToConstant: numberWidth).isActive = true
                reading = vertical([number, amount], spacing: 2)
            } else { reading = number }
            let row = horizontal([reading, bar, name], spacing: 9)
            bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        add(rows)
    }

    private func disks(_ disks: [DeviceDiskDisplayUsage], usageColor: (Double, DeviceMetricsAlertMetric) -> NSColor) {
        if disks.isEmpty { addText("暂无已挂载磁盘"); return }
        for (index, disk) in disks.enumerated() {
            let fraction = disk.usageFraction
            let value = disk.totalBytes > 0
                ? "\(Self.bytes(Double(disk.usedBytes))) / \(Self.bytes(Double(disk.totalBytes))) (\(Self.percent(fraction)))" : "--"
            addUsageRow(name: disk.mountPath, value: value, fraction: fraction,
                        color: usageColor(fraction, .diskUsage), identifier: "disk.\(index)")
        }
    }

    private func diskIO(_ snapshot: DeviceMetricsDisplaySnapshot,
                        usageColor: (Double, DeviceMetricsAlertMetric) -> NSColor) {
        if let io = snapshot.diskIO {
            for (name, value, color, identifier) in [
                ("↓ 读取", io.readBytesPerSecond, NSColor.systemGreen, "read"),
                ("↑ 写入", io.writeBytesPerSecond, NSColor.systemCyan, "write")
            ] {
                let rate = label(DeviceMetricValueFormatter.bytesPerSecond(value), color: color)
                rate.setAccessibilityIdentifier("Stacio.Metrics.detail.diskIO.\(identifier)")
                rate.setContentCompressionResistancePriority(.required, for: .horizontal)
                add(horizontal([label(name, color: .secondaryLabelColor), NSView(), rate]))
            }
        } else { addText("磁盘读写数据暂不可用") }
        add(label("已挂载磁盘", color: .secondaryLabelColor))
        disks(snapshot.disks, usageColor: usageColor)
    }

    private func networks(_ networks: [DeviceNetworkDisplayRate], latency: Double?) {
        let latencyText = latency.map { $0 < 1 ? "<1 ms" : String(format: "%.1f ms", $0) } ?? "--"
        let latencyValue = label(latencyText, color: .systemPurple)
        latencyValue.setAccessibilityIdentifier("Stacio.Metrics.detail.network.latency")
        latencyValue.toolTip = "当前 SSH 连接的网络往返时延（TCP RTT），不包含资源采集耗时。"
        latencyValue.setContentCompressionResistancePriority(.required, for: .horizontal)
        add(horizontal([label("SSH 时延", color: .secondaryLabelColor), NSView(), latencyValue]))
        if networks.isEmpty { addText("暂无网络接口数据"); return }
        // Physical and active interfaces first; every collected interface stays
        // reachable in the scroll area, including idle bridges and tunnels.
        let sorted = networks.sorted {
            let a = $0.receiveBytesPerSecond + $0.transmitBytesPerSecond
            let b = $1.receiveBytesPerSecond + $1.transmitBytesPerSecond
            return a == b ? $0.interfaceName.localizedStandardCompare($1.interfaceName) == .orderedAscending : a > b
        }
        for network in sorted {
            let name = label(network.interfaceName, color: .secondaryLabelColor, size: 12, monospaced: true)
            name.lineBreakMode = .byTruncatingTail
            name.toolTip = network.interfaceName
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let down = label("↓ \(DeviceMetricValueFormatter.bytesPerSecond(network.receiveBytesPerSecond))", color: .systemGreen, size: 12)
            let up = label("↑ \(DeviceMetricValueFormatter.bytesPerSecond(network.transmitBytesPerSecond))", color: .systemCyan, size: 12)
            down.setContentCompressionResistancePriority(.required, for: .horizontal)
            up.setContentCompressionResistancePriority(.required, for: .horizontal)
            down.setAccessibilityIdentifier("Stacio.Metrics.detail.network.\(network.interfaceName).download")
            up.setAccessibilityIdentifier("Stacio.Metrics.detail.network.\(network.interfaceName).upload")
            add(horizontal([name, NSView(), down, up], spacing: 10))
        }
    }

    private func addUsageRow(name: String, value: String, fraction: Double, color: NSColor, identifier: String) {
        let nameLabel = label(name, color: .secondaryLabelColor, monospaced: true)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.toolTip = name
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let valueLabel = label(value, color: color)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = horizontal([nameLabel, NSView(), valueLabel])
        let bar = DeviceMetricsDetailBar(segments: [(fraction, color)], identifier: identifier)
        let column = vertical([row, bar], spacing: 7)
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        bar.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        add(column)
    }

    private func addLegends(_ parts: [(String, Double, NSColor)]) {
        // Two columns keep labels and values readable in both localizations.
        for start in stride(from: 0, to: parts.count, by: 2) {
            let row = horizontal([], spacing: 12)
            row.distribution = .fillEqually
            for part in parts[start..<min(start + 2, parts.count)] {
                let dot = label("●", color: part.2, size: 10)
                row.addArrangedSubview(horizontal([dot, label("\(part.0)：\(Self.bytes(part.1))", color: .secondaryLabelColor, size: 11), NSView()], spacing: 5))
            }
            add(row)
        }
    }

    private func add(_ child: NSView) {
        body.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }

    private func addText(_ text: String) {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.isSelectable = true
        add(field)
    }

    private func label(_ text: String, color: NSColor = .labelColor, size: CGFloat = 12, monospaced: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = monospaced ? .monospacedSystemFont(ofSize: size, weight: .regular) : .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        field.textColor = color
        field.maximumNumberOfLines = 1
        return field
    }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private static func percent(_ fraction: Double) -> String { String(format: "%.0f%%", fraction * 100) }
    private static func bytes(_ value: Double) -> String { DeviceMetricValueFormatter.bytes(value) }
}

/// Draws all segments in one pass without timers, layers or animations.
@MainActor
final class DeviceMetricsDetailBar: NSView {
    let segments: [(fraction: Double, color: NSColor)]

    init(segments: [(Double, NSColor)], identifier: String, height: CGFloat = 7) {
        var remaining = 1.0
        self.segments = segments.map { fraction, color in
            let value = fraction.isFinite ? min(max(0, fraction), remaining) : 0
            remaining -= value
            return (value, color)
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityIdentifier("Stacio.Metrics.detail.\(identifier)")
        setAccessibilityValue(self.segments.map { String(format: "%.1f%%", $0.fraction * 100) }.joined(separator: ", "))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        track.fill()
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        var x = bounds.minX
        for segment in segments {
            let width = bounds.width * segment.fraction
            segment.color.setFill()
            NSRect(x: x, y: bounds.minY, width: width, height: bounds.height).fill()
            x += width
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

private final class DeviceMetricsDetailDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class DeviceMetricsDetailSurface: NSView {
    override var isOpaque: Bool { false }
    var onHoverChanged: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}
