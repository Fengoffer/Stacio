import AppKit
import CoreText

enum DeviceMetricValueFormatter {
    static func bytesPerSecond(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var scaled = max(value, 0)
        var index = 0
        while scaled >= 1024, index < units.count - 1 {
            scaled /= 1024
            index += 1
        }
        // Keep the dashboard readable and consistent with the existing metric cards:
        // one decimal for normal values, with two decimals only below one unit.
        let number = scaled < 1 ? String(format: "%.2f", scaled) : scaled >= 100 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)
        return "\(number) \(units[index])"
    }

    static func bytes(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        return bytesPerSecond(value).replacingOccurrences(of: "/s", with: "")
    }
}

public struct DeviceMetricHistorySample: Equatable, Sendable {
    public let date: Date
    public let value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

public enum DeviceMetricHistoryGranularity: String, CaseIterable, Sendable {
    case minute
    case hour
    case day

    public var title: String {
        switch self {
        case .minute: return "分钟"
        case .hour: return "小时"
        case .day: return "天"
        }
    }

    fileprivate var interval: TimeInterval {
        switch self {
        case .minute: return 60
        case .hour: return 3600
        case .day: return 86400
        }
    }

    fileprivate var window: TimeInterval {
        switch self {
        case .minute: return 3600
        case .hour: return 86400
        case .day: return 7 * 86400
        }
    }
}

public final class DeviceMetricHistoryDetailViewController: NSViewController {
    private let resourceTitle: String
    private var allSamples: [DeviceMetricHistorySample]
    private var pendingHistorySamples: [DeviceMetricHistorySample]?
    private let accentColor: NSColor
    private let unit: String
    private let deviceName: String?
    private let deviceAddress: String?
    private let logo: NSImage?
    private let granularityControl = NSSegmentedControl(labels: DeviceMetricHistoryGranularity.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let rangeSlider = DeviceMetricRangeSlider()
    private let rangeLabel = NSTextField(labelWithString: "暂无历史数据")
    private let chartView = DeviceMetricHistoryChartView()
    private let downloadButton = NSButton(title: "下载图片", target: nil, action: nil)
    private var granularity: DeviceMetricHistoryGranularity = .minute
    private var hasInitializedRange = false
    private var timeRangeEditorOverlay: DeviceMetricTimeRangeEditorOverlay?
    private var rangeLower = 0.0
    private var rangeUpper = 1.0

    public init(
        resourceTitle: String,
        samples: [DeviceMetricHistorySample],
        accentColor: NSColor,
        unit: String = "",
        deviceName: String? = nil,
        deviceAddress: String? = nil
    ) {
        self.resourceTitle = resourceTitle
        self.allSamples = samples.sorted { $0.date < $1.date }
        self.accentColor = accentColor
        self.unit = unit
        self.deviceName = deviceName
        self.deviceAddress = deviceAddress
        self.logo = Self.loadLogo()
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 620, height: 450)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func loadView() {
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .withinWindow
        root.state = .active

        let titleText = unit.isEmpty ? resourceTitle + "历史资源使用" : "\(resourceTitle)历史资源使用（\(unit)）"
        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.toolTip = titleText
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString: "拖动选择时间范围 · 双击滑块编辑时间 · 悬停曲线查看数值")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        granularityControl.selectedSegment = DeviceMetricHistoryGranularity.allCases.firstIndex(of: granularity) ?? 0
        granularityControl.target = self
        granularityControl.action = #selector(granularityChanged(_:))
        granularityControl.translatesAutoresizingMaskIntoConstraints = false
        granularityControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        granularityControl.setAccessibilityIdentifier("Stacio.Metrics.history.granularity")

        rangeSlider.target = self
        rangeSlider.action = #selector(rangeChanged(_:))
        rangeSlider.onDoubleClick = { [weak self] point in self?.presentTimeRangeEditor(at: point) }
        rangeSlider.onTrackingEnded = { [weak self] in self?.applyPendingHistorySamples() }
        rangeSlider.translatesAutoresizingMaskIntoConstraints = false
        rangeSlider.setAccessibilityIdentifier("Stacio.Metrics.history.range")
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        rangeLabel.textColor = .secondaryLabelColor
        rangeLabel.alignment = .center
        rangeLabel.translatesAutoresizingMaskIntoConstraints = false

        chartView.accentColor = accentColor
        chartView.unit = unit
        chartView.translatesAutoresizingMaskIntoConstraints = false
        chartView.setAccessibilityIdentifier("Stacio.Metrics.history.chart")
        downloadButton.bezelStyle = .rounded
        downloadButton.target = self
        downloadButton.action = #selector(download(_:))
        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        downloadButton.setAccessibilityIdentifier("Stacio.Metrics.history.download")

        root.addSubview(title); root.addSubview(subtitle); root.addSubview(granularityControl)
        root.addSubview(rangeSlider); root.addSubview(rangeLabel); root.addSubview(chartView); root.addSubview(downloadButton)
        let chartHeight = chartView.heightAnchor.constraint(equalToConstant: 270)
        chartHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), title.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            title.trailingAnchor.constraint(lessThanOrEqualTo: granularityControl.leadingAnchor, constant: -12),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor), subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            granularityControl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), granularityControl.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            rangeSlider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), rangeSlider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), rangeSlider.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16), rangeSlider.heightAnchor.constraint(equalToConstant: 28),
            rangeLabel.leadingAnchor.constraint(equalTo: rangeSlider.leadingAnchor), rangeLabel.trailingAnchor.constraint(equalTo: rangeSlider.trailingAnchor), rangeLabel.topAnchor.constraint(equalTo: rangeSlider.bottomAnchor, constant: 4),
            chartView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), chartView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), chartView.topAnchor.constraint(equalTo: rangeLabel.bottomAnchor, constant: 12), chartHeight,
            downloadButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), downloadButton.topAnchor.constraint(equalTo: chartView.bottomAnchor, constant: 10), downloadButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        view = root
        updateVisibleData()
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        rangeSlider.endTracking()
        dismissTimeRangeEditor()
        chartView.clearHover()
    }

    public var visibleSamplesForTesting: [DeviceMetricHistorySample] { chartView.samples }
    public var rangeTextForTesting: String { rangeLabel.stringValue }
    public var selectedRangeForTesting: (lower: Double, upper: Double) { (rangeLower, rangeUpper) }

    var exportTimeRangeText: String {
        guard let range = chartView.selectedTimeRange else { return "暂无历史数据" }
        let mode = granularity == .minute ? "按分钟范围显示 · 原始采样" : "按\(granularity.title)聚合"
        return "时间范围：\(Self.exportDateText(range.start)) – \(Self.exportDateText(range.end)) · \(mode)"
    }

    public func exportPNGDataForTesting() -> Data? { makePNGData() }

    public func setRangeForTesting(lower: Double, upper: Double) {
        rangeSlider.setRange(lower: lower, upper: upper)
        rangeChanged(rangeSlider)
    }

    func updateHistorySamples(_ samples: [DeviceMetricHistorySample]) {
        // Keep the pointer-to-date mapping stable throughout a drag. Retain
        // only the newest refresh and apply it once the interaction finishes.
        guard !rangeSlider.isTrackingRange else {
            pendingHistorySamples = samples
            return
        }
        let previousFirst = allSamples.first?.date
        let previousLast = allSamples.last?.date
        allSamples = Self.sortedSamples(samples)
        // Follow incoming samples only while the full range is selected.
        // A narrowed range represents dates, not percentages of a growing log.
        if rangeLower > 0 || rangeUpper < 1,
           let previousFirst, let previousLast, previousLast > previousFirst,
           let first = allSamples.first?.date, let last = allSamples.last?.date, last > first {
            let previousSpan = previousLast.timeIntervalSince(previousFirst)
            let start = previousFirst.addingTimeInterval(rangeLower * previousSpan)
            let end = previousFirst.addingTimeInterval(rangeUpper * previousSpan)
            let span = last.timeIntervalSince(first)
            rangeLower = start.timeIntervalSince(first) / span
            rangeUpper = end.timeIntervalSince(first) / span
        }
        updateVisibleData()
    }

    private func applyPendingHistorySamples() {
        guard let samples = pendingHistorySamples else { return }
        pendingHistorySamples = nil
        updateHistorySamples(samples)
    }

    @objc private func granularityChanged(_ sender: NSSegmentedControl) {
        granularity = DeviceMetricHistoryGranularity.allCases[safe: sender.selectedSegment] ?? .minute
        updateVisibleData()
    }

    @objc private func rangeChanged(_ sender: DeviceMetricRangeSlider) {
        rangeLower = sender.lowerValue
        rangeUpper = sender.upperValue
        updateVisibleData()
    }

    private func updateVisibleData() {
        chartView.aggregationTitle = granularity == .minute ? "分钟范围 · 原始采样" : "\(granularity.title)均值"
        guard let first = allSamples.first, let last = allSamples.last else {
            chartView.samples = []
            chartView.selectedTimeRange = nil
            chartView.maximumValue = 1
            rangeLower = 0
            rangeUpper = 1
            rangeSlider.setRange(lower: 0, upper: 1)
            rangeLabel.stringValue = "暂无历史数据"
            dismissTimeRangeEditor()
            return
        }
        let span = max(last.date.timeIntervalSince(first.date), 0)
        if !hasInitializedRange {
            hasInitializedRange = true
            if span > granularity.window {
                rangeLower = max(0, 1 - granularity.window / span)
                rangeUpper = 1
            }
        }
        rangeLower = min(max(rangeLower, 0), 1)
        rangeUpper = min(max(rangeUpper, rangeLower), 1)
        rangeSlider.setRange(lower: rangeLower, upper: rangeUpper)
        let start = first.date.addingTimeInterval(rangeLower * span)
        let end = first.date.addingTimeInterval(rangeUpper * span)
        chartView.selectedTimeRange = DateInterval(start: start, end: end)
        let lowerIndex = lowerBound(in: allSamples, date: start)
        let upperIndex = upperBound(in: allSamples, date: end)
        let visible = lowerIndex < upperIndex ? allSamples[lowerIndex..<upperIndex] : allSamples[0..<0]
        let aggregated = aggregate(visible, granularity: granularity)
        chartView.samples = aggregated
        chartView.maximumValue = max(aggregated.map(\.value).max() ?? 1, 1)
        rangeLabel.stringValue = "\(Self.dateText(start, includeSeconds: granularity == .minute))  –  \(Self.dateText(end, includeSeconds: granularity == .minute)) · \(visible.count) 个采样点"
    }

    private func presentTimeRangeEditor(at point: NSPoint) {
        guard let editor = makeTimeRangeEditor() else { return }
        dismissTimeRangeEditor()
        chartView.clearHover()
        chartView.isHoverEnabled = false
        let overlay = DeviceMetricTimeRangeEditorOverlay(frame: view.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onDismiss = { [weak self] in self?.dismissTimeRangeEditor() }
        editor.onCancel = overlay.onDismiss
        editor.onApply = { [weak self] start, end in
            guard let self else { return }
            // Resolve against current history: polling may have extended or
            // pruned it since the user started editing these absolute dates.
            if let first = self.allSamples.first, let last = self.allSamples.last {
                let span = max(last.date.timeIntervalSince(first.date), 1)
                self.rangeLower = min(max(min(start, end).timeIntervalSince(first.date) / span, 0), 1)
                self.rangeUpper = min(max(max(start, end).timeIntervalSince(first.date) / span, self.rangeLower), 1)
                self.updateVisibleData()
            }
            self.dismissTimeRangeEditor()
        }
        let anchor = rangeSlider.convert(point, to: view)
        let sliderRect = rangeSlider.convert(rangeSlider.bounds, to: view)
        editor.frame = NSRect(
            x: min(max(anchor.x - editor.frame.width / 2, 12), view.bounds.width - editor.frame.width - 12),
            y: max(12, sliderRect.minY - editor.frame.height - 6),
            width: editor.frame.width, height: editor.frame.height
        )
        overlay.addSubview(editor)
        view.addSubview(overlay)
        timeRangeEditorOverlay = overlay
        // Keep the editor in the same window as the transient history popover.
        // A modal window or a second popover can dismiss that parent on focus.
        let fraction = (point.x - 12) / max(rangeSlider.bounds.width - 24, 1)
        view.window?.makeFirstResponder(abs(fraction - rangeUpper) < abs(fraction - rangeLower) ? editor.endPicker : editor.startPicker)
    }

    private func dismissTimeRangeEditor() {
        guard let overlay = timeRangeEditorOverlay else { return }
        view.window?.makeFirstResponder(nil)
        overlay.removeFromSuperview()
        timeRangeEditorOverlay = nil
        chartView.isHoverEnabled = true
    }

    func makeTimeRangeEditor() -> DeviceMetricTimeRangeEditorView? {
        guard let first = allSamples.first, let last = allSamples.last else { return nil }
        let start = first.date.addingTimeInterval(rangeLower * last.date.timeIntervalSince(first.date))
        let end = first.date.addingTimeInterval(rangeUpper * last.date.timeIntervalSince(first.date))
        return DeviceMetricTimeRangeEditorView(start: start, end: end, bounds: DateInterval(start: first.date, end: last.date))
    }

    private static func sortedSamples(_ samples: [DeviceMetricHistorySample]) -> [DeviceMetricHistorySample] {
        guard samples.count > 1 else { return samples }
        var previous = samples[0].date
        var isSorted = true
        for sample in samples.dropFirst() {
            if sample.date < previous {
                isSorted = false
                break
            }
            previous = sample.date
        }
        return isSorted ? samples : samples.sorted { $0.date < $1.date }
    }

    private func lowerBound(in samples: [DeviceMetricHistorySample], date: Date) -> Int {
        var lower = 0
        var upper = samples.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if samples[middle].date < date { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    private func upperBound(in samples: [DeviceMetricHistorySample], date: Date) -> Int {
        var lower = 0
        var upper = samples.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if samples[middle].date <= date { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    private func aggregate(_ samples: ArraySlice<DeviceMetricHistorySample>, granularity: DeviceMetricHistoryGranularity) -> [DeviceMetricHistorySample] {
        guard let origin = samples.first?.date else { return [] }
        // The minute view is a one-hour inspection window, not a request to
        // average away the samples collected inside each minute. Preserve the
        // original timestamps so the hover guide can report the exact second
        // and the corresponding measurement. Longer ranges still aggregate
        // to keep the chart responsive.
        if granularity == .minute {
            return Array(samples)
        }
        var buckets: [Int: [DeviceMetricHistorySample]] = [:]
        for sample in samples {
            let index = Int(floor(sample.date.timeIntervalSince(origin) / granularity.interval))
            buckets[index, default: []].append(sample)
        }
        return buckets.keys.sorted().compactMap { key in
            guard let values = buckets[key], values.isEmpty == false else { return nil }
            return DeviceMetricHistorySample(date: values[values.count / 2].date, value: values.map(\.value).reduce(0, +) / Double(values.count))
        }
    }

    @objc private func download(_ sender: NSButton) {
        guard let data = makePNGData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(resourceTitle)-资源历史.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "保存资源历史图片失败"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "确定")
                alert.runModal()
            }
        }
    }

    private func makePNGData() -> Data? {
        let metadataFont = NSFont.systemFont(ofSize: 18)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let metadataAttributes: [NSAttributedString.Key: Any] = [
            .font: metadataFont,
            .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1),
            .paragraphStyle: paragraph
        ]
        var metadata = [String]()
        if let deviceName, deviceName.isEmpty == false { metadata.append("设备：\(deviceName)") }
        if let deviceAddress, deviceAddress.isEmpty == false { metadata.append("地址：\(deviceAddress)") }
        metadata.append("导出时间：\(Self.exportDateText(Date()))")
        let metadataWidth: CGFloat = 1360
        let singleLineMetadata = metadata.joined(separator: "  ·  ")
        let metadataText = NSString(string:
            NSString(string: singleLineMetadata).size(withAttributes: metadataAttributes).width <= metadataWidth
                ? singleLineMetadata : metadata.joined(separator: "\n")
        )
        let metadataHeight = max(22, ceil(metadataText.boundingRect(
            with: NSSize(width: metadataWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: metadataAttributes
        ).height))
        // Let long host names and connection addresses wrap without clipping
        // the export timestamp or taking space away from the resource chart.
        let extraHeaderHeight = metadataHeight - 22
        let size = NSSize(width: 1600, height: 900 + extraHeaderHeight)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        let logoRect = NSRect(x: 56, y: 790 + extraHeaderHeight, width: 58, height: 58)
        logo?.draw(in: logoRect)
        let brandFont = NSFont(name: "Lack-Regular", size: 34) ?? NSFont.systemFont(ofSize: 34, weight: .semibold)
        let brandBaseline = logoRect.midY - (brandFont.ascender + brandFont.descender) / 2
        NSString(string: "Stacio").draw(at: NSPoint(x: 128, y: brandBaseline), withAttributes: [.font: brandFont, .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)])
        let titleFont = NSFont.systemFont(ofSize: 34, weight: .semibold)
        let exportUnit = chartView.displayUnit
        let exportTitle = unit.isEmpty || exportUnit == unit ? resourceTitle : "\(resourceTitle)（\(exportUnit)）"
        let title = NSString(string: exportTitle)
        let titleWidth = title.size(withAttributes: [.font: titleFont]).width
        title.draw(at: NSPoint(x: (size.width - titleWidth) / 2, y: 804 + extraHeaderHeight), withAttributes: [.font: titleFont, .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)])
        metadataText.draw(
            with: NSRect(x: 120, y: 765, width: metadataWidth, height: metadataHeight),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: metadataAttributes
        )
        NSString(string: exportTimeRangeText).draw(
            at: NSPoint(x: 120, y: 728),
            withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1)]
        )
        let graph = NSRect(x: 125, y: 150, width: 1370, height: 560)
        chartView.drawExport(in: graph)
        image.unlockFocus()
        return image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
    }

    private static func dateText(_ date: Date, includeSeconds: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = includeSeconds ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func exportDateText(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"; return formatter.string(from: date)
    }

    private static func loadLogo() -> NSImage? {
        if let url = resourceURL(name: "lack-regular-2", fileExtension: "otf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        for name in ["stacio-logo", "Stacio-logo"] {
            if let url = resourceURL(name: name, fileExtension: "png"), let image = NSImage(contentsOf: url) { return image }
        }
        return NSImage(named: NSImage.applicationIconName)
    }

    private static func resourceURL(name: String, fileExtension: String) -> URL? {
        let bundles = [
            Bundle(for: DeviceMetricHistoryDetailViewController.self),
            Bundle.main
        ]
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: fileExtension) { return url }
            if let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Fonts") { return url }
            if let nestedBundleURL = bundle.url(forResource: "Stacio_StacioApp", withExtension: "bundle"),
               let nestedBundle = Bundle(url: nestedBundleURL),
               let url = nestedBundle.url(forResource: name, withExtension: fileExtension)
                    ?? nestedBundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Fonts") {
                return url
            }
            if let resourceURL = bundle.resourceURL {
                let url = resourceURL.appendingPathComponent("\(name).\(fileExtension)")
                if FileManager.default.fileExists(atPath: url.path) { return url }
                let fontURL = resourceURL.appendingPathComponent("Fonts").appendingPathComponent("\(name).\(fileExtension)")
                if FileManager.default.fileExists(atPath: fontURL.path) { return fontURL }
            }
        }
        return nil
    }
}

private final class DeviceMetricTimeRangeEditorOverlay: NSView {
    var onDismiss: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

final class DeviceMetricTimeRangeEditorView: NSVisualEffectView {
    let startPicker = NSDatePicker()
    let endPicker = NSDatePicker()
    var onApply: ((Date, Date) -> Void)?
    var onCancel: (() -> Void)?

    init(start: Date, end: Date, bounds interval: DateInterval) {
        super.init(frame: NSRect(x: 0, y: 0, width: 344, height: 210))
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        let dropShadow = NSShadow()
        dropShadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        dropShadow.shadowBlurRadius = 14
        dropShadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow = dropShadow
        setAccessibilityIdentifier("Stacio.Metrics.history.timeEditor")

        let title = NSTextField(labelWithString: "时间范围")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "输入日期与时间（精确到秒）")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let labels = [NSTextField(labelWithString: "开始"), NSTextField(labelWithString: "结束")]
        for picker in [startPicker, endPicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
            picker.minDate = interval.start
            picker.maxDate = interval.end
            picker.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            picker.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        startPicker.dateValue = start
        endPicker.dateValue = end
        startPicker.setAccessibilityIdentifier("Stacio.Metrics.history.startDate")
        endPicker.setAccessibilityIdentifier("Stacio.Metrics.history.endDate")
        let apply = NSButton(title: "应用", target: self, action: #selector(applyRange(_:)))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        apply.setAccessibilityIdentifier("Stacio.Metrics.history.applyTimeRange")
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelRange(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityIdentifier("Stacio.Metrics.history.cancelTimeRange")
        for child in [title, subtitle, labels[0], labels[1], startPicker, endPicker, apply, cancel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            startPicker.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 17),
            endPicker.topAnchor.constraint(equalTo: startPicker.bottomAnchor, constant: 14),
            startPicker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 58),
            endPicker.leadingAnchor.constraint(equalTo: startPicker.leadingAnchor),
            startPicker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            endPicker.trailingAnchor.constraint(equalTo: startPicker.trailingAnchor),
            labels[0].leadingAnchor.constraint(equalTo: title.leadingAnchor),
            labels[0].centerYAnchor.constraint(equalTo: startPicker.centerYAnchor),
            labels[1].leadingAnchor.constraint(equalTo: title.leadingAnchor),
            labels[1].centerYAnchor.constraint(equalTo: endPicker.centerYAnchor),
            apply.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            apply.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            cancel.trailingAnchor.constraint(equalTo: apply.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: apply.centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
    override var mouseDownCanMoveWindow: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    @objc private func cancelRange(_ sender: NSButton) { onCancel?() }
    @objc private func applyRange(_ sender: NSButton) {
        // Commit the actively edited date component before reading the values.
        guard window?.makeFirstResponder(nil) != false else { return }
        onApply?(startPicker.dateValue, endPicker.dateValue)
    }
}

final class DeviceMetricHistoryChartView: NSView {
    var samples: [DeviceMetricHistorySample] = [] { didSet { needsDisplay = true } }
    var selectedTimeRange: DateInterval? { didSet { needsDisplay = true } }
    var maximumValue: Double = 1 { didSet { needsDisplay = true } }
    var accentColor: NSColor = .systemBlue { didSet { needsDisplay = true } }
    var unit: String = "" { didSet { needsDisplay = true } }
    var aggregationTitle = "" { didSet { needsDisplay = true } }
    var isHoverEnabled = true { didSet { if !isHoverEnabled { clearHover() } } }
    private var pointerLocation: NSPoint?
    private var pointerTrackingArea: NSTrackingArea?
    private let hoverDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    struct HoverSnapshot {
        let sample: DeviceMetricHistorySample
        let point: NSPoint
        let guideX: CGFloat
        let timeText: String
        let valueText: String
    }

    var displayUnit: String {
        guard unit == "B/s" || unit == "B" else { return unit }
        return bytesUnit(for: maximumValue)
    }

    var displayedMaximum: Double { maximumValue / displayScale }

    var timeRange: DateInterval? {
        if let selectedTimeRange { return selectedTimeRange }
        guard let first = samples.first, let last = samples.last else { return nil }
        return DateInterval(start: first.date, end: last.date)
    }

    var plotRect: NSRect { graphRect(in: bounds, exporting: false) }

    private func graphRect(in rect: NSRect, exporting: Bool) -> NSRect {
        if exporting { return rect.insetBy(dx: 88, dy: 42) }
        return NSRect(x: rect.minX + 54, y: rect.minY + 32,
                      width: max(rect.width - 66, 1), height: max(rect.height - 56, 1))
    }

    private func point(for sample: DeviceMetricHistorySample, in graph: NSRect, range: DateInterval) -> NSPoint {
        let fraction = range.duration > 0 ? sample.date.timeIntervalSince(range.start) / range.duration : 0.5
        let value = min(max(sample.value / max(maximumValue, .leastNonzeroMagnitude), 0), 1)
        return NSPoint(x: graph.minX + graph.width * fraction, y: graph.minY + graph.height * value)
    }

    func plotPoints(in graph: NSRect) -> [NSPoint] {
        guard let range = timeRange else { return [] }
        return samples.map { point(for: $0, in: graph, range: range) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        guard isHoverEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        pointerLocation = plotRect.contains(point) ? point : nil
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { clearHover() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        clearHover()
    }
    func clearHover() { pointerLocation = nil; needsDisplay = true }

    var hoverSnapshot: HoverSnapshot? {
        guard isHoverEnabled, let pointerLocation, plotRect.contains(pointerLocation),
              let range = timeRange, !samples.isEmpty else { return nil }
        let date = range.start.addingTimeInterval(range.duration * (pointerLocation.x - plotRect.minX) / plotRect.width)
        // Snap to a displayed sample, so the guide, marker and tooltip all
        // describe the same point. Never invent a measurement by interpolation.
        var lower = 0
        var upper = samples.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if samples[middle].date < date { lower = middle + 1 } else { upper = middle }
        }
        let index: Int
        if lower == 0 { index = 0 }
        else if lower == samples.count { index = samples.count - 1 }
        else {
            index = date.timeIntervalSince(samples[lower - 1].date) <= samples[lower].date.timeIntervalSince(date) ? lower - 1 : lower
        }
        let sample = samples[index]
        guard range.contains(sample.date), sample.value.isFinite else { return nil }
        let text: String
        switch unit {
        case "%": text = String(format: "%.2f%%", sample.value * 100)
        case "B/s": text = DeviceMetricValueFormatter.bytesPerSecond(sample.value)
        case "B": text = DeviceMetricValueFormatter.bytes(sample.value)
        default: text = String(format: "%.2f", sample.value) + (unit.isEmpty ? "" : " " + unit)
        }
        return HoverSnapshot(sample: sample, point: point(for: sample, in: plotRect, range: range), guideX: pointerLocation.x,
                             timeText: hoverDateFormatter.string(from: date), valueText: text)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawChart(in: bounds, labelColor: .secondaryLabelColor, exporting: false)
        if let snapshot = hoverSnapshot { drawHover(snapshot) }
    }

    func drawExport(in rect: NSRect) {
        // Exports use the same chart styling with fixed contrast on white,
        // and never include the transient pointer or its tooltip.
        drawChart(in: rect, labelColor: NSColor(calibratedWhite: 0.35, alpha: 1), exporting: true)
    }

    private func drawChart(in rect: NSRect, labelColor: NSColor, exporting: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let graph = graphRect(in: rect, exporting: exporting)
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: exporting ? 12 : 10, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: labelColor]
        context.saveGState()
        let ink = exporting ? NSColor.black : NSColor.labelColor
        // Only horizontal value guides. Each one has a matching label;
        // time ticks below the axis keep the curve free of a heavy lattice.
        for index in 0...4 {
            let fraction = Double(index) / 4
            let y = graph.minY + graph.height * fraction
            context.setStrokeColor(ink.withAlphaComponent(index == 0 ? 0.2 : 0.09).cgColor)
            context.setLineWidth(0.75)
            context.move(to: CGPoint(x: graph.minX, y: y))
            context.addLine(to: CGPoint(x: graph.maxX, y: y))
            context.strokePath()
            let value = displayedMaximum * fraction
            let text = NSString(string: value == 0 ? "0" : String(format: displayedMaximum >= 100 ? "%.0f" : "%.1f", value))
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: graph.minX - size.width - 10, y: y - size.height / 2), withAttributes: attributes)
        }
        if !displayUnit.isEmpty {
            NSString(string: displayUnit).draw(at: NSPoint(x: rect.minX + 4, y: graph.maxY + 10), withAttributes: attributes)
        }
        let points = plotPoints(in: graph)
        if let first = points.first, let last = points.last {
            let curve = CGMutablePath()
            curve.move(to: first)
            for point in points.dropFirst() { curve.addLine(to: point) }
            if points.count > 1 {
                let area = curve.mutableCopy()!
                area.addLine(to: NSPoint(x: last.x, y: graph.minY))
                area.addLine(to: NSPoint(x: first.x, y: graph.minY))
                area.closeSubpath()
                context.saveGState()
                context.addPath(area)
                context.clip()
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                             colors: [accentColor.withAlphaComponent(0.12).cgColor, accentColor.withAlphaComponent(0.01).cgColor] as CFArray,
                                             locations: [0, 1]) {
                    context.drawLinearGradient(gradient, start: NSPoint(x: 0, y: graph.maxY), end: NSPoint(x: 0, y: graph.minY), options: [])
                }
                context.restoreGState()
            }
            context.addPath(curve)
            context.setStrokeColor(accentColor.cgColor)
            context.setLineWidth(exporting ? 2.5 : 2)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.strokePath()
            if points.count == 1 {
                context.setFillColor(accentColor.cgColor)
                context.fillEllipse(in: CGRect(x: first.x - 3, y: first.y - 3, width: 6, height: 6))
            }
        }
        if let range = timeRange {
            let formatter = DateFormatter()
            let span = range.duration
            formatter.dateFormat = span <= 120 ? "HH:mm:ss" : span <= 86400 ? "HH:mm" : span <= 7 * 86400 ? "MM-dd HH:mm" : "yyyy-MM-dd"
            let labelWidth = max(
                NSString(string: formatter.string(from: range.start)).size(withAttributes: attributes).width,
                NSString(string: formatter.string(from: range.end)).size(withAttributes: attributes).width,
                span <= 86400 ? NSString(string: "00:00:00").size(withAttributes: attributes).width : 0
            )
            let count = span > 0 ? min(max(Int(graph.width / (labelWidth + 24)), 2), exporting ? 12 : 7) : 1
            if span > 0, span / Double(count - 1) < 60 { formatter.dateFormat = "HH:mm:ss" }
            for index in 0..<count {
                let fraction = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0.5
                let x = graph.minX + graph.width * fraction
                let text = NSString(string: formatter.string(from: range.start.addingTimeInterval(span * fraction)))
                let width = text.size(withAttributes: attributes).width
                context.setStrokeColor(ink.withAlphaComponent(0.2).cgColor)
                context.move(to: NSPoint(x: x, y: graph.minY))
                context.addLine(to: NSPoint(x: x, y: graph.minY - 4))
                context.strokePath()
                text.draw(at: NSPoint(x: min(max(x - width / 2, graph.minX), graph.maxX - width), y: graph.minY - 22), withAttributes: attributes)
            }
        }
        context.restoreGState()
    }

    private func drawHover(_ snapshot: HoverSnapshot) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.4).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.move(to: NSPoint(x: snapshot.guideX, y: plotRect.minY))
        context.addLine(to: NSPoint(x: snapshot.guideX, y: plotRect.maxY))
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        context.setFillColor(accentColor.cgColor)
        context.setStrokeColor(NSColor.controlBackgroundColor.cgColor)
        context.setLineWidth(2)
        context.addEllipse(in: NSRect(x: snapshot.point.x - 4, y: snapshot.point.y - 4, width: 8, height: 8))
        context.drawPath(using: .fillStroke)
        context.restoreGState()

        let timeAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let value = snapshot.valueText + (aggregationTitle.isEmpty ? "" : " · " + aggregationTitle)
        let width = max(NSString(string: snapshot.timeText).size(withAttributes: timeAttributes).width,
                        NSString(string: value).size(withAttributes: valueAttributes).width) + 24
        let height: CGFloat = 56
        var x = snapshot.guideX + 12
        if x + width > bounds.maxX - 4 { x = snapshot.guideX - width - 12 }
        let y = snapshot.point.y + height + 12 <= bounds.maxY - 4 ? snapshot.point.y + 12 : snapshot.point.y - height - 12
        let bubble = NSRect(x: max(bounds.minX + 4, x), y: min(max(bounds.minY + 4, y), bounds.maxY - height - 4), width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 8, yRadius: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
        let border = NSBezierPath(roundedRect: bubble, xRadius: 8, yRadius: 8)
        border.lineWidth = 0.5
        border.stroke()
        NSString(string: snapshot.timeText).draw(at: NSPoint(x: bubble.minX + 12, y: bubble.maxY - 22), withAttributes: timeAttributes)
        NSString(string: value).draw(at: NSPoint(x: bubble.minX + 12, y: bubble.minY + 9), withAttributes: valueAttributes)
    }

    private var displayScale: Double {
        if unit == "%" { return 0.01 }
        guard unit == "B/s" || unit == "B" else { return 1 }
        switch bytesUnit(for: maximumValue) {
        case "KB/s", "KB": return 1024
        case "MB/s", "MB": return 1024 * 1024
        case "GB/s", "GB": return 1024 * 1024 * 1024
        case "TB/s", "TB": return 1024 * 1024 * 1024 * 1024
        default: return 1
        }
    }

    private func bytesUnit(for value: Double) -> String {
        let suffix = unit == "B" ? "" : "/s"
        switch max(value, 0) {
        case 1_099_511_627_776.0...: return "TB\(suffix)"
        case 1_073_741_824.0...: return "GB\(suffix)"
        case 1_048_576.0...: return "MB\(suffix)"
        case 1_024.0...: return "KB\(suffix)"
        default: return "B\(suffix)"
        }
    }
}

private final class DeviceMetricRangeSlider: NSControl {
    var lowerValue: Double = 0 { didSet { lowerValue = min(max(lowerValue, 0), upperValue); needsDisplay = true } }
    var upperValue: Double = 1 { didSet { upperValue = max(min(upperValue, 1), lowerValue); needsDisplay = true } }
    private var activeHandle: Handle?
    private var dragStartX: CGFloat?
    private var dragOffsetX: CGFloat = 0
    var onDoubleClick: ((NSPoint) -> Void)?
    var onTrackingEnded: (() -> Void)?
    var isTrackingRange: Bool { activeHandle != nil }

    func endTracking() {
        let wasTracking = isTrackingRange
        activeHandle = nil
        dragStartX = nil
        dragOffsetX = 0
        if wasTracking { onTrackingEnded?() }
    }

    private enum Handle { case lower, upper, coincident }

    func setRange(lower: Double, upper: Double) {
        // Widen first so moving both bounds beyond the old upper handle does
        // not clamp the new lower handle to the previous selection.
        upperValue = 1
        lowerValue = lower
        upperValue = upper
    }

    override var isContinuous: Bool {
        get { true }
        set { _ = newValue }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 12, y: bounds.midY - 3, width: max(bounds.width - 24, 1), height: 6)
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let selected = NSRect(x: track.minX + track.width * CGFloat(lowerValue), y: track.minY, width: track.width * CGFloat(upperValue - lowerValue), height: track.height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: selected, xRadius: 3, yRadius: 3).fill()
        for value in [lowerValue, upperValue] {
            let center = NSPoint(x: track.minX + track.width * CGFloat(value), y: track.midY)
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)).fill()
            NSColor.separatorColor.setStroke()
            let knob = NSBezierPath(ovalIn: NSRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)); knob.lineWidth = 1; knob.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            endTracking()
            onDoubleClick?(convert(event.locationInWindow, from: nil))
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        dragStartX = point.x
        activeHandle = nearestHandle(to: point)
        let handleValue = activeHandle == .upper ? upperValue : lowerValue
        let handleX = 12 + max(bounds.width - 24, 1) * CGFloat(handleValue)
        // Grabbing a knob off-center must not move it until the mouse moves.
        // This also preserves the selection on the first click of a double-click.
        dragOffsetX = abs(point.x - handleX) <= 9 ? point.x - handleX : 0
        if activeHandle != .coincident { updateValue(with: event) }
    }

    override func mouseDragged(with event: NSEvent) { updateValue(with: event) }
    override func mouseUp(with event: NSEvent) {
        updateValue(with: event)
        endTracking()
    }

    private func nearestHandle(to point: NSPoint) -> Handle {
        let track = NSRect(x: 12, y: bounds.midY - 3, width: max(bounds.width - 24, 1), height: 6)
        let lowerX = track.minX + track.width * CGFloat(lowerValue)
        let upperX = track.minX + track.width * CGFloat(upperValue)
        if lowerValue == upperValue {
            if abs(point.x - lowerX) <= 9 { return .coincident }
            return point.x < lowerX ? .lower : .upper
        }
        return abs(point.x - lowerX) <= abs(point.x - upperX) ? .lower : .upper
    }

    private func updateValue(with event: NSEvent) {
        guard let activeHandle else { return }
        let point = convert(event.locationInWindow, from: nil)
        let track = NSRect(x: 12, y: bounds.midY - 3, width: max(bounds.width - 24, 1), height: 6)
        let value = min(max(Double((point.x - dragOffsetX - track.minX) / track.width), 0), 1)
        switch activeHandle {
        case .lower: lowerValue = min(value, upperValue)
        case .upper: upperValue = max(value, lowerValue)
        case .coincident:
            // Once the handles meet, the drag direction chooses which edge
            // to expand instead of permanently selecting the lower handle.
            guard let dragStartX else { return }
            if point.x < dragStartX {
                self.activeHandle = .lower
                lowerValue = min(value, upperValue)
            } else if point.x > dragStartX {
                self.activeHandle = .upper
                upperValue = max(value, lowerValue)
            }
        }
        sendAction(action, to: target)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
