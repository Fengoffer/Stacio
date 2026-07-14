import AppKit
import ObjectiveC
import XCTest
@testable import StacioApp
import StacioCoreBindings

@MainActor
final class DeviceMetricsDashboardViewControllerTests: XCTestCase {
    func testDisplayFormatterDerivesDiskReadWriteRateFromSnapshotCounters() throws {
        let previous = DeviceMetricsSnapshot(
            sampledAtMs: 1_000,
            system: DeviceSystemInfo(
                hostname: "worker-01",
                currentUser: "deploy",
                architecture: "x86_64",
                operatingSystem: "Ubuntu 25.10",
                uptimeSeconds: 1_210_200,
                kernelRelease: "6.8.0-64-generic",
                cpuModel: "Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz"
            ),
            cpu: DeviceCpuSample(totalTicks: 100, idleTicks: 80),
            cpuCores: [
                DeviceCpuSample(totalTicks: 100, idleTicks: 80),
                DeviceCpuSample(totalTicks: 100, idleTicks: 50)
            ],
            memory: DeviceMemorySample(totalBytes: 1_000, availableBytes: 600),
            networkInterfaces: [],
            diskIo: DeviceDiskIoSample(readBytes: 1_000, writeBytes: 2_000),
            disks: []
        )
        let current = DeviceMetricsSnapshot(
            sampledAtMs: 3_000,
            system: DeviceSystemInfo(
                hostname: "worker-01",
                currentUser: "deploy",
                architecture: "x86_64",
                operatingSystem: "Ubuntu 25.10",
                uptimeSeconds: 1_210_200,
                kernelRelease: "6.8.0-64-generic",
                cpuModel: "Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz"
            ),
            cpu: DeviceCpuSample(totalTicks: 200, idleTicks: 120),
            cpuCores: [
                DeviceCpuSample(totalTicks: 200, idleTicks: 140),
                DeviceCpuSample(totalTicks: 200, idleTicks: 60)
            ],
            memory: DeviceMemorySample(totalBytes: 1_000, availableBytes: 500),
            networkInterfaces: [],
            diskIo: DeviceDiskIoSample(readBytes: 5_096, writeBytes: 10_192),
            disks: []
        )

        let display = DeviceMetricsDisplayFormatter.displaySnapshot(current: current, previous: previous)

        XCTAssertEqual(display.system.hostname, "worker-01")
        XCTAssertEqual(display.system.currentUser, "deploy")
        XCTAssertEqual(display.system.architecture, "x86_64")
        XCTAssertEqual(display.system.operatingSystem, "Ubuntu 25.10")
        XCTAssertEqual(display.system.uptimeText, "14天")
        XCTAssertEqual(display.system.kernelVersion, "6.8.0-64-generic")
        XCTAssertEqual(display.system.cpuModel, "Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz")
        XCTAssertEqual(display.cpuCoreUsages.count, 2)
        XCTAssertEqual(display.cpuCoreUsages[0].usage ?? -1, 0.40, accuracy: 0.001)
        XCTAssertEqual(display.cpuCoreUsages[1].usage ?? -1, 0.90, accuracy: 0.001)
        let diskIO = try XCTUnwrap(display.diskIO)
        XCTAssertEqual(diskIO.readBytesPerSecond, 2_048, accuracy: 0.001)
        XCTAssertEqual(diskIO.writeBytesPerSecond, 4_096, accuracy: 0.001)
    }

    func testInspectorDoesNotExposeDeviceMetricsDashboardSection() throws {
        let inspector = InspectorViewController()

        inspector.loadView()

        XCTAssertEqual(inspector.sectionLabelsForTesting, ["文件", "隧道", "浏览器", "诊断", "宏", "历史命令", "AI"])
        XCTAssertFalse(inspector.sectionLabelsForTesting.contains(L10n.Inspector.metrics))
        XCTAssertEqual(inspector.sectionControlForTesting.segmentCount, inspector.sectionLabelsForTesting.count)
        XCTAssertNil(inspector.deviceMetricsViewController)
        inspector.selectSectionForTesting(inspector.sectionControlForTesting.segmentCount)
        XCTAssertEqual(inspector.selectedTabLabel, "文件")
    }

    func testDashboardRendersRealtimeDeviceMetricsInFloatingChartPanel() throws {
        let suiteName = "StacioMetricsOverviewVisuals-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        let alertCoordinator = DeviceMetricsAlertCoordinator(
            settingsProvider: { settingsStore.snapshot() },
            notifier: NoopDeviceMetricsAlertNotifier(),
            thresholdDefaults: defaults
        )
        alertCoordinator.updateThreshold(10, for: .networkIO, settingsStore: settingsStore)
        alertCoordinator.updateThreshold(10, for: .diskIO, settingsStore: settingsStore)
        let provider = RecordingDeviceMetricsProvider(snapshot: .sample)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@172.16.10.250",
            provider: provider,
            startsPollingAutomatically: false,
            settingsStore: settingsStore,
            alertCoordinator: alertCoordinator
        )

        controller.loadView()
        controller.refreshMetricsForTesting()
        controller.view.frame = NSRect(x: 0, y: 0, width: 300, height: 790)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(provider.refreshCount, 1)
        XCTAssertTrue(controller.usesArrowCursorForTesting)
        XCTAssertEqual(controller.view.accessibilityIdentifier(), "Stacio.Metrics.dashboard.term_metrics")
        XCTAssertEqual(controller.view.layer?.cornerRadius ?? 0, 0)
        XCTAssertEqual(controller.view.layer?.backgroundColor, NSColor.clear.cgColor)
        let panel = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.codexPanel"))
        XCTAssertNotNil(panel.shadow)
        XCTAssertLessThanOrEqual(panel.shadow?.shadowBlurRadius ?? 0, 12)
        XCTAssertEqual(
            panel.layer?.backgroundColor,
            StacioDesignSystem.resolvedLayerColor(
                StacioDesignSystem.metricsFloatingSurfaceColor(for: panel),
                for: panel
            )
        )
        XCTAssertEqual(panel.layer?.cornerRadius, 7)
        XCTAssertEqual(panel.layer?.borderWidth ?? 0, 0)
        XCTAssertNil(panel.layer?.borderColor)
        let cpuTile = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.tile.CPU"))
        XCTAssertEqual(
            cpuTile.layer?.backgroundColor,
            StacioDesignSystem.resolvedLayerColor(
                StacioDesignSystem.metricsFloatingSurfaceColor(for: cpuTile),
                for: cpuTile
            )
        )
        XCTAssertEqual(cpuTile.layer?.cornerRadius, 7)
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.section.overview"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.section.network"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.section.disks"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.cpuLineChart"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.memoryLineChart"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.cpuGauge"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.memoryGauge"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("设备看板"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("root@172.16.10.250"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.section.system"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("系统"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("主机名称"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("worker-01"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("登录用户"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("deploy"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("系统架构"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("x86_64"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("操作系统"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("Ubuntu 25.10"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("运行时长"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("14天"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("内核版本"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("6.8.0-64-generic"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("概览"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("CPU"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("42%"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("8 CPU"))
        let cpuCoreButton = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.cpuCoreButton") as? NSButton)
        XCTAssertEqual(cpuCoreButton.title, "8 CPU")
        XCTAssertEqual(cpuCoreButton.cell?.lineBreakMode, .byTruncatingMiddle)
        XCTAssertEqual(cpuTile.frame.height, 104, accuracy: 0.5)
        let cpuCorePopoverText = controller.cpuCorePopoverPreviewTextSnapshotForTesting
        XCTAssertTrue(cpuCorePopoverText.hasPrefix("Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz\n"))
        XCTAssertTrue(cpuCorePopoverText.contains("CPU 核心"))
        XCTAssertTrue(cpuCorePopoverText.contains("Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz"))
        XCTAssertTrue(cpuCorePopoverText.contains("8 CPU"))
        XCTAssertTrue(cpuCorePopoverText.contains("18.2%"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("内存"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("5.0 GB / 16.0 GB"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("网络"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("↓ 下载 12.0 MB/s"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("↑ 上传 1.5 MB/s"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("下载 12.0 MB/s"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("上传 1.5 MB/s"))
        let overviewNetworkDownloadLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.overview.network.download") as? NSTextField
        )
        XCTAssertEqual(overviewNetworkDownloadLabel.font?.pointSize, 14)
        XCTAssertEqual(overviewNetworkDownloadLabel.textColor, StacioDesignSystem.theme.dangerColor)
        XCTAssertNotNil(overviewNetworkDownloadLabel.layer?.animation(forKey: "Stacio.Metrics.ioBreathingGlow"))
        let overviewNetworkUploadLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.overview.network.upload") as? NSTextField
        )
        XCTAssertEqual(overviewNetworkUploadLabel.font?.pointSize, 14)
        XCTAssertEqual(overviewNetworkUploadLabel.textColor, StacioDesignSystem.theme.successColor)
        XCTAssertNil(overviewNetworkUploadLabel.layer?.animation(forKey: "Stacio.Metrics.ioBreathingGlow"))
        let networkPicker = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.networkPicker") as? NSPopUpButton)
        XCTAssertTrue(networkPicker.isEnabled)
        XCTAssertTrue(networkPicker.item(at: 0)?.isEnabled ?? false)
        XCTAssertEqual(networkPicker.contentTintColor, StacioDesignSystem.theme.primaryTextColor)
        let networkDownloadLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.networkRate.download.ens160") as? NSTextField
        )
        XCTAssertEqual(networkDownloadLabel.stringValue, "↓ 下载 12.0 MB/s")
        XCTAssertEqual(networkDownloadLabel.textColor, StacioDesignSystem.theme.accentColor)
        XCTAssertEqual(networkDownloadLabel.font?.pointSize, 13)
        let networkUploadLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.networkRate.upload.ens160") as? NSTextField
        )
        XCTAssertEqual(networkUploadLabel.stringValue, "↑ 上传 1.5 MB/s")
        XCTAssertEqual(networkUploadLabel.textColor, StacioDesignSystem.theme.successColor)
        XCTAssertEqual(networkUploadLabel.font?.pointSize, 13)
        let networkInterfaceLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.networkInterface.ens160") as? NSTextField
        )
        XCTAssertEqual(networkInterfaceLabel.font?.pointSize, 13)
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("磁盘读写"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("↓ 读 10.0 MB/s"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("↑ 写 1.0 MB/s"))
        let overviewDiskReadLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.overview.disk.read") as? NSTextField
        )
        XCTAssertEqual(overviewDiskReadLabel.font?.pointSize, 14)
        XCTAssertEqual(overviewDiskReadLabel.textColor, StacioDesignSystem.theme.dangerColor)
        XCTAssertNotNil(overviewDiskReadLabel.layer?.animation(forKey: "Stacio.Metrics.ioBreathingGlow"))
        let overviewDiskWriteLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.overview.disk.write") as? NSTextField
        )
        XCTAssertEqual(overviewDiskWriteLabel.font?.pointSize, 14)
        XCTAssertEqual(overviewDiskWriteLabel.textColor, NSColor.systemOrange)
        XCTAssertNil(overviewDiskWriteLabel.layer?.animation(forKey: "Stacio.Metrics.ioBreathingGlow"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("/proc/diskstats"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("磁盘"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("/data"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("78%"))
        let rootDiskTitle = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.diskTitle./") as? NSTextField
        )
        XCTAssertEqual(rootDiskTitle.font?.pointSize, 13)
        XCTAssertEqual(rootDiskTitle.textColor, StacioDesignSystem.theme.accentColor)
        let rootDiskDetail = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.diskDetail./") as? NSTextField
        )
        XCTAssertEqual(rootDiskDetail.font?.pointSize, 12)
        XCTAssertEqual(rootDiskDetail.textColor, StacioDesignSystem.theme.successColor)
        let dataDiskDetail = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.diskDetail./data") as? NSTextField
        )
        XCTAssertEqual(dataDiskDetail.textColor, NSColor.systemOrange)
        controller.refreshThemeForEffectiveAppearanceChangeForTesting(appearance: controller.view.effectiveAppearance)
        let primaryTextColor = StacioDesignSystem.resolvedColor(
            StacioDesignSystem.theme.primaryTextColor,
            for: controller.view.effectiveAppearance
        )
        let successTextColor = StacioDesignSystem.resolvedColor(
            StacioDesignSystem.theme.successColor,
            for: controller.view.effectiveAppearance
        )
        let dangerTextColor = StacioDesignSystem.resolvedColor(
            StacioDesignSystem.theme.dangerColor,
            for: controller.view.effectiveAppearance
        )
        let systemHostnameLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.systemLabel.hostname") as? NSTextField
        )
        let systemHostnameValue = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.systemValue.hostname") as? NSTextField
        )
        let overviewTitle = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.section.overview.title") as? NSTextField
        )
        let networkTitle = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.section.network.title") as? NSTextField
        )
        let diskTitle = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.section.disks.title") as? NSTextField
        )
        XCTAssertEqual(systemHostnameLabel.textColor, primaryTextColor)
        XCTAssertEqual(systemHostnameValue.textColor, primaryTextColor)
        XCTAssertEqual(overviewTitle.textColor, primaryTextColor)
        XCTAssertEqual(networkTitle.textColor, primaryTextColor)
        XCTAssertEqual(diskTitle.textColor, primaryTextColor)
        XCTAssertEqual(overviewNetworkDownloadLabel.textColor, dangerTextColor)
        XCTAssertEqual(networkUploadLabel.textColor, successTextColor)
        let cpuChart = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.cpuLineChart"))
        XCTAssertGreaterThanOrEqual(cpuChart.superview?.frame.width ?? 0, 86)
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.diskPie./data"))
        XCTAssertEqual(metricsDashboardRootWidthConstraintCount(in: controller.view), 0)
        XCTAssertTrue(controller.textFieldUsesArrowCursorForTesting(accessibilityIdentifier: "Stacio.Metrics.systemValue.operatingSystem"))
        XCTAssertTrue(controller.textFieldUsesArrowCursorForTesting(accessibilityIdentifier: "Stacio.Metrics.section.overview.title"))
        XCTAssertTrue(controller.textFieldUsesArrowCursorForTesting(accessibilityIdentifier: "Stacio.Metrics.networkRate.download.ens160"))
    }

    func testDashboardOffersFullOperatingSystemPopoverWhenNameIsTruncated() throws {
        let longOperatingSystem = "Anolis OS 8.8 (RHCK) 4.19.90-372.32.1.el8.x86_64 Enterprise Linux Compatible"
        let snapshot = DeviceMetricsDisplaySnapshot(
            cpuUsage: 0.24,
            cpuCoreUsages: [
                DeviceCPUCoreDisplayUsage(index: 0, usage: 0.12),
                DeviceCPUCoreDisplayUsage(index: 1, usage: 0.36)
            ],
            system: DeviceSystemDisplayInfo(
                hostname: "legacy-node",
                currentUser: "root",
                architecture: "x86_64",
                operatingSystem: longOperatingSystem,
                uptimeText: "2小时",
                kernelVersion: "4.19.90-372.32.1.el8.x86_64",
                cpuModel: "Hygon C86 7185 32-core Processor"
            ),
            memory: DeviceMemoryDisplayUsage(usedBytes: 1_000, totalBytes: 4_000),
            networks: [],
            disks: []
        )
        let provider = RecordingDeviceMetricsProvider(snapshot: snapshot)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics_long_os",
            title: "root@legacy-node",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()
        controller.view.frame = NSRect(x: 0, y: 0, width: 190, height: 520)
        controller.view.layoutSubtreeIfNeeded()
        let osValue = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.systemValue.operatingSystem") as? NSTextField
        )
        osValue.frame.size.width = 82

        XCTAssertTrue(controller.isOperatingSystemValueTruncatedForTesting)
        let popoverText = controller.operatingSystemInfoPopoverPreviewTextSnapshotForTesting
        XCTAssertTrue(popoverText.contains("操作系统"))
        XCTAssertTrue(popoverText.contains(longOperatingSystem))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("Hygon C86 7185 32-core Processor"))
        XCTAssertTrue(
            controller.cpuCorePopoverPreviewTextSnapshotForTesting.hasPrefix(
                "Hygon C86 7185 32-core Processor\n"
            )
        )
    }

    func testOperatingSystemLabelHandlesPointerExitToDismissPopover() throws {
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics_os_hover",
            title: "root@legacy-node",
            provider: RecordingDeviceMetricsProvider(snapshot: .sample),
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()
        let osValue = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.systemValue.operatingSystem") as? NSTextField
        )
        let selector = #selector(NSResponder.mouseExited(with:))
        let labelMethod = try XCTUnwrap(class_getInstanceMethod(type(of: osValue), selector))
        let textFieldMethod = try XCTUnwrap(class_getInstanceMethod(NSTextField.self, selector))
        let labelImplementation = unsafeBitCast(
            method_getImplementation(labelMethod),
            to: UnsafeRawPointer.self
        )
        let textFieldImplementation = unsafeBitCast(
            method_getImplementation(textFieldMethod),
            to: UnsafeRawPointer.self
        )

        XCTAssertNotEqual(labelImplementation, textFieldImplementation)
    }

    func testPreferredFloatingHeightPreservesUsableLayoutForExtremelyNarrowWorkspace() throws {
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics_narrow",
            title: "root@legacy-node",
            provider: RecordingDeviceMetricsProvider(snapshot: .sample),
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()
        controller.view.frame = NSRect(x: 0, y: 0, width: 300, height: 790)
        controller.view.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.content")
        )
        _ = controller.preferredFloatingHeight(width: 300)
        let usableWidth = content.frame.width

        XCTAssertEqual(usableWidth, 280, accuracy: 0.5)
        for width in [CGFloat.zero, 1, 20] {
            let height = controller.preferredFloatingHeight(width: width)

            XCTAssertTrue(height.isFinite)
            XCTAssertEqual(height, 180, accuracy: 0.5)
            XCTAssertEqual(content.frame.width, usableWidth, accuracy: 0.5)
            let containerBounds = try XCTUnwrap(content.superview?.bounds)
            XCTAssertGreaterThanOrEqual(content.frame.minX, containerBounds.minX - 0.5)
            XCTAssertLessThanOrEqual(content.frame.maxX, containerBounds.maxX + 0.5)
        }

        let freshController = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics_narrow_fresh",
            title: "root@legacy-node",
            provider: RecordingDeviceMetricsProvider(snapshot: .sample),
            startsPollingAutomatically: false
        )
        freshController.loadView()
        freshController.refreshMetricsForTesting()
        let freshContent = try XCTUnwrap(
            freshController.view.firstSubview(withIdentifier: "Stacio.Metrics.content")
        )
        let freshHeight = freshController.preferredFloatingHeight(width: 1)

        XCTAssertTrue(freshHeight.isFinite)
        XCTAssertEqual(freshHeight, 180, accuracy: 0.5)
        XCTAssertNotEqual(freshContent.frame.width, 1)
        let freshContainerBounds = try XCTUnwrap(freshContent.superview?.bounds)
        XCTAssertGreaterThanOrEqual(freshContent.frame.minX, freshContainerBounds.minX - 0.5)
        XCTAssertLessThanOrEqual(freshContent.frame.maxX, freshContainerBounds.maxX + 0.5)
    }

    func testDashboardMarksCustomMetricDrawingsDirtyWhenAppearanceChanges() throws {
        let provider = RecordingDeviceMetricsProvider(snapshot: .sample)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@172.16.10.250",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()
        let initialInvalidationCount = controller.metricDrawingAppearanceInvalidationCountForTesting

        controller.view.viewDidChangeEffectiveAppearance()

        XCTAssertGreaterThan(controller.metricDrawingAppearanceInvalidationCountForTesting, initialInvalidationCount)
    }

    func testDashboardRefreshesPanelColorsForEffectiveAppearanceChanges() throws {
        let provider = RecordingDeviceMetricsProvider(snapshot: .sample)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@172.16.10.250",
            provider: provider,
            startsPollingAutomatically: false
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        controller.loadView()
        window.contentView = controller.view
        controller.refreshMetricsForTesting()
        let panel = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.codexPanel"))

        controller.refreshThemeForEffectiveAppearanceChangeForTesting(
            appearance: try XCTUnwrap(NSAppearance(named: .aqua))
        )
        let lightBackground = try XCTUnwrap(panel.layer?.backgroundColor)

        controller.refreshThemeForEffectiveAppearanceChangeForTesting(
            appearance: try XCTUnwrap(NSAppearance(named: .darkAqua))
        )
        let darkBackground = try XCTUnwrap(panel.layer?.backgroundColor)

        XCTAssertLessThan(darkBackground.stacioTestRelativeLuminance, lightBackground.stacioTestRelativeLuminance)
    }

    func testDashboardDefaultsToActiveNetworkInterfacesAndAllowsManualMultiSelection() throws {
        let provider = RecordingDeviceMetricsProvider(snapshot: .dense)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@172.16.10.250",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.networkPicker"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("ens160"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("veth-extra"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("docker0"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("br-e76d70614a3c"))

        controller.setSelectedNetworkInterfacesForTesting(["docker0", "ens160"])

        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("docker0"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("ens160"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("veth-extra"))
    }

    func testDashboardKeepsContainerOverlayNetworksOutOfAutomaticSelection() throws {
        let provider = RecordingDeviceMetricsProvider(snapshot: .containerOverlayNetworks)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@k8s-node",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("ens192"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("cni0"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("cali1234"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("flannel.1"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("ovn-k8s-mp0"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("tailscale0"))

        controller.setSelectedNetworkInterfacesForTesting(["ens192", "cni0", "tailscale0"])

        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("ens192"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("cni0"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("tailscale0"))
    }

    func testDashboardExplainsAutomaticallyHiddenVirtualNetworkInterfaces() throws {
        let provider = RecordingDeviceMetricsProvider(snapshot: .containerOverlayNetworks)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@centos7-docker",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("已自动隐藏 5 个虚拟网卡"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("可在网卡菜单手动显示"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("cni0"))

        controller.setSelectedNetworkInterfacesForTesting(["ens192", "cni0", "tailscale0"])

        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("已自动隐藏"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("cni0"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("tailscale0"))
    }

    func testDashboardVirtualNetworkHintWrapsToAvailableNetworkWidth() throws {
        let provider = RecordingDeviceMetricsProvider(snapshot: .containerOverlayNetworks)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@centos7-docker",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()
        controller.view.frame = NSRect(x: 0, y: 0, width: 190, height: 790)
        controller.view.layoutSubtreeIfNeeded()

        let hint = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.networkVirtualHint") as? NSTextField
        )
        XCTAssertEqual(hint.stringValue, "已自动隐藏 5 个虚拟网卡\n可在网卡菜单手动显示")
        XCTAssertEqual(hint.maximumNumberOfLines, 2)
        XCTAssertEqual(hint.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(hint.font?.pointSize, 11)
        XCTAssertGreaterThan(hint.bounds.width, 0)
        XCTAssertEqual(hint.preferredMaxLayoutWidth, hint.bounds.width, accuracy: 1)
        XCTAssertGreaterThan(hint.intrinsicContentSize.height, 20)
        XCTAssertGreaterThanOrEqual(hint.bounds.height, hint.intrinsicContentSize.height - 1)
    }

    func testDashboardExplainsInitialCpuSampleAndHiddenDiskCount() throws {
        let provider = RecordingDeviceMetricsProvider(snapshot: .initialDense)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@centos6",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("等待第二次采样"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("另有 1 个挂载点"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("/mnt/backup"))
    }

    func testDashboardReadsDisplaySettingsForNetworkDiskVisibilityAndDiskLimit() throws {
        let suiteName = "StacioMetricsDisplaySettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.deviceMetricsShowNetworkSection = false
            settings.deviceMetricsShowDiskSection = true
            settings.deviceMetricsDiskMountLimit = 2
        }
        let provider = RecordingDeviceMetricsProvider(snapshot: .dense)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@centos7",
            provider: provider,
            startsPollingAutomatically: false,
            settingsStore: settingsStore
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.section.network"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.section.disks"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("网络"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("ens160"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("/"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("/data"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("/boot"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("另有 4 个挂载点"))

        settingsStore.update { settings in
            settings.deviceMetricsShowDiskSection = false
        }
        let diskHiddenController = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics_hidden_disk",
            title: "root@centos7",
            provider: RecordingDeviceMetricsProvider(snapshot: .dense),
            startsPollingAutomatically: false,
            settingsStore: settingsStore
        )

        diskHiddenController.loadView()
        diskHiddenController.refreshMetricsForTesting()

        XCTAssertNil(diskHiddenController.view.firstSubview(withIdentifier: "Stacio.Metrics.section.network"))
        XCTAssertNil(diskHiddenController.view.firstSubview(withIdentifier: "Stacio.Metrics.section.disks"))
        XCTAssertFalse(diskHiddenController.visibleTextSnapshotForTesting.contains("磁盘"))
        XCTAssertFalse(diskHiddenController.visibleTextSnapshotForTesting.contains("/data"))
    }

    func testDashboardCanDisableAutomaticVirtualNetworkFiltering() throws {
        let suiteName = "StacioMetricsNetworkFilterSettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.deviceMetricsHideVirtualNetworkInterfaces = false
        }
        let provider = RecordingDeviceMetricsProvider(snapshot: .containerOverlayNetworks)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@centos7-docker",
            provider: provider,
            startsPollingAutomatically: false,
            settingsStore: settingsStore
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("ens192"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("cni0"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("tailscale0"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("已自动隐藏"))
    }

    func testDashboardRespectsConfiguredHistorySampleLimit() throws {
        let suiteName = "StacioMetricsHistorySettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.deviceMetricsHistorySampleCount = 3
        }
        let provider = SequenceDeviceMetricsProvider(results: [
            .success(.sample.with(cpuUsage: 0.10)),
            .success(.sample.with(cpuUsage: 0.20)),
            .success(.sample.with(cpuUsage: 0.30)),
            .success(.sample.with(cpuUsage: 0.40)),
            .success(.sample.with(cpuUsage: 0.50))
        ])
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@centos7",
            provider: provider,
            startsPollingAutomatically: false,
            settingsStore: settingsStore
        )

        controller.loadView()
        (0..<5).forEach { _ in controller.refreshMetricsForTesting() }

        XCTAssertEqual(controller.chartHistorySampleCountsForTesting.cpu, 3)
        XCTAssertEqual(controller.chartHistorySampleCountsForTesting.memory, 3)
    }

    func testDashboardShowsChineseUnavailableStateWhenMetricsFail() throws {
        let provider = RecordingDeviceMetricsProvider(error: DeviceMetricsTestError.unavailable)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@172.16.10.250",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        XCTAssertEqual(provider.refreshCount, 1)
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("采集失败"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("Linux 兼容探针"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("/proc"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("df"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("CentOS"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("Ubuntu"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("Debian"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("Alpine"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.localizedCaseInsensitiveContains("DeviceMetricsTestError"))
    }

    func testDashboardMarshalsBackgroundProviderCallbacksToMainThread() async throws {
        let provider = BackgroundQueueDeviceMetricsProvider(snapshot: .sample)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@172.16.10.250",
            provider: provider,
            startsPollingAutomatically: false
        )
        let didUpdate = expectation(description: "metrics update")
        let recorder = MainThreadUpdateRecorder(expectation: didUpdate)
        controller.metricsDidUpdate = {
            recorder.record()
        }

        controller.loadView()
        controller.refreshMetricsForTesting()

        await fulfillment(of: [didUpdate], timeout: 1.0)
        let rendered = await metricsDashboardEventually {
            controller.visibleTextSnapshotForTesting.contains("42%")
        }
        XCTAssertTrue(rendered)
        XCTAssertEqual(recorder.values, [true])
        XCTAssertEqual(provider.refreshCount, 1)
    }

    func testDashboardCanKeepLastSuccessfulMetricsWhenRefreshFails() throws {
        let suiteName = "StacioMetricsSettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.deviceMetricsRefreshIntervalSeconds = 7
            settings.deviceMetricsKeepLastSnapshotOnFailure = true
        }
        let provider = SequenceDeviceMetricsProvider(results: [
            .success(.sample),
            .failure(DeviceMetricsTestError.unavailable)
        ])
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@172.16.10.250",
            provider: provider,
            startsPollingAutomatically: false,
            settingsStore: settingsStore
        )

        controller.loadView()
        controller.refreshMetricsForTesting()
        controller.refreshMetricsForTesting()

        XCTAssertEqual(provider.refreshCount, 2)
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("42%"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("上次成功数据"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("7 秒"))
    }

    func testDashboardExplainsWhichLinuxProbeSectionFailed() throws {
        let provider = RecordingDeviceMetricsProvider(
            error: SshRuntimeError.Transport(message: "METRICS_PROBE_MISSING_MEMORY:/proc/meminfo")
        )
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@172.16.10.250",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("无法读取 /proc/meminfo"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("内存探针不可用"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("主流 Linux"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("CentOS/RHEL"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("Ubuntu"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("Alpine"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("METRICS_PROBE_MISSING_MEMORY"))
    }

    func testDashboardUsesVerticalScrollViewSoItDoesNotLockWindowHeight() throws {
        let provider = RecordingDeviceMetricsProvider(snapshot: .dense)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@172.16.10.250",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        let scrollView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.scrollView") as? NSScrollView
        )
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertLessThanOrEqual(controller.view.fittingSize.height, 360)
    }
}

private func metricsDashboardRootWidthConstraintCount(in root: NSView) -> Int {
    root.constraints.filter { constraint in
        (constraint.firstItem as? NSView) === root
            && constraint.secondItem == nil
            && (constraint.firstAttribute == .width || constraint.firstAttribute == .height)
    }.count
}

private func metricsDashboardEventually(
    timeout: TimeInterval = 1.0,
    condition: @MainActor @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

private final class RecordingDeviceMetricsProvider: DeviceMetricsProviding {
    private let snapshot: DeviceMetricsDisplaySnapshot?
    private let error: Error?
    private(set) var refreshCount = 0

    init(snapshot: DeviceMetricsDisplaySnapshot? = nil, error: Error? = nil) {
        self.snapshot = snapshot
        self.error = error
    }

    func pollDeviceMetrics(completion: @escaping (Result<DeviceMetricsDisplaySnapshot, Error>) -> Void) {
        refreshCount += 1
        if let error {
            completion(.failure(error))
            return
        }
        completion(.success(snapshot ?? .sample))
    }
}

private final class SequenceDeviceMetricsProvider: DeviceMetricsProviding {
    private var results: [Result<DeviceMetricsDisplaySnapshot, Error>]
    private(set) var refreshCount = 0

    init(results: [Result<DeviceMetricsDisplaySnapshot, Error>]) {
        self.results = results
    }

    func pollDeviceMetrics(completion: @escaping (Result<DeviceMetricsDisplaySnapshot, Error>) -> Void) {
        refreshCount += 1
        if results.isEmpty {
            completion(.failure(DeviceMetricsTestError.unavailable))
            return
        }
        completion(results.removeFirst())
    }
}

private final class BackgroundQueueDeviceMetricsProvider: DeviceMetricsProviding {
    private let snapshot: DeviceMetricsDisplaySnapshot
    private(set) var refreshCount = 0

    init(snapshot: DeviceMetricsDisplaySnapshot) {
        self.snapshot = snapshot
    }

    func pollDeviceMetrics(completion: @escaping (Result<DeviceMetricsDisplaySnapshot, Error>) -> Void) {
        refreshCount += 1
        DispatchQueue.global(qos: .utility).async { [snapshot] in
            completion(.success(snapshot))
        }
    }
}

private final class MainThreadUpdateRecorder {
    private let lock = NSLock()
    private let expectation: XCTestExpectation
    private var recordedValues: [Bool] = []

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }

    func record() {
        lock.lock()
        recordedValues.append(Thread.isMainThread)
        lock.unlock()
        expectation.fulfill()
    }
}

private enum DeviceMetricsTestError: Error {
    case unavailable
}

private extension DeviceMetricsDisplaySnapshot {
    static let sample = DeviceMetricsDisplaySnapshot(
        cpuUsage: 0.42,
        cpuCoreUsages: sampleCPUCoreUsages,
        system: sampleSystemInfo,
        memory: DeviceMemoryDisplayUsage(usedBytes: 5_368_709_120, totalBytes: 17_179_869_184),
        networks: [
            DeviceNetworkDisplayRate(interfaceName: "ens160", receiveBytesPerSecond: 12_582_912, transmitBytesPerSecond: 1_572_864)
        ],
        disks: [
            DeviceDiskDisplayUsage(mountPath: "/", usedBytes: 12_000_000_000, totalBytes: 96_000_000_000),
            DeviceDiskDisplayUsage(mountPath: "/data", usedBytes: 78_000_000_000, totalBytes: 100_000_000_000)
        ],
        diskIO: DeviceDiskIODisplayRate(readBytesPerSecond: 10_485_760, writeBytesPerSecond: 1_048_576)
    )

    static let dense = DeviceMetricsDisplaySnapshot(
        cpuUsage: 0.03,
        cpuCoreUsages: sampleCPUCoreUsages,
        system: sampleSystemInfo,
        memory: DeviceMemoryDisplayUsage(usedBytes: 788_600_000, totalBytes: 15_100_000_000),
        networks: [
            DeviceNetworkDisplayRate(interfaceName: "ens160", receiveBytesPerSecond: 1_536, transmitBytesPerSecond: 2_662),
            DeviceNetworkDisplayRate(interfaceName: "br-e76d70614a3c", receiveBytesPerSecond: 0, transmitBytesPerSecond: 0),
            DeviceNetworkDisplayRate(interfaceName: "docker0", receiveBytesPerSecond: 0, transmitBytesPerSecond: 0),
            DeviceNetworkDisplayRate(interfaceName: "veth-extra", receiveBytesPerSecond: 32, transmitBytesPerSecond: 64)
        ],
        disks: [
            DeviceDiskDisplayUsage(mountPath: "/", usedBytes: 11_900_000_000, totalBytes: 95_900_000_000),
            DeviceDiskDisplayUsage(mountPath: "/data", usedBytes: 1_800_000_000, totalBytes: 97_900_000_000),
            DeviceDiskDisplayUsage(mountPath: "/boot", usedBytes: 238_300_000, totalBytes: 1_900_000_000),
            DeviceDiskDisplayUsage(mountPath: "/var/lib/docker", usedBytes: 31_000_000_000, totalBytes: 80_000_000_000),
            DeviceDiskDisplayUsage(mountPath: "/srv/archive", usedBytes: 71_000_000_000, totalBytes: 100_000_000_000),
            DeviceDiskDisplayUsage(mountPath: "/mnt/backup", usedBytes: 180_000_000_000, totalBytes: 200_000_000_000)
        ],
        diskIO: DeviceDiskIODisplayRate(readBytesPerSecond: 1_536, writeBytesPerSecond: 2_662)
    )

    static let initialDense = DeviceMetricsDisplaySnapshot(
        cpuUsage: nil,
        cpuCoreUsages: sampleCPUCoreUsages.map { DeviceCPUCoreDisplayUsage(index: $0.index, usage: nil) },
        system: sampleSystemInfo,
        memory: DeviceMemoryDisplayUsage(usedBytes: 788_600_000, totalBytes: 15_100_000_000),
        networks: [
            DeviceNetworkDisplayRate(interfaceName: "ens160", receiveBytesPerSecond: 1_536, transmitBytesPerSecond: 2_662)
        ],
        disks: dense.disks,
        diskIO: DeviceDiskIODisplayRate(readBytesPerSecond: 0, writeBytesPerSecond: 0)
    )

    static let containerOverlayNetworks = DeviceMetricsDisplaySnapshot(
        cpuUsage: 0.08,
        cpuCoreUsages: sampleCPUCoreUsages,
        system: sampleSystemInfo,
        memory: DeviceMemoryDisplayUsage(usedBytes: 1_200_000_000, totalBytes: 8_000_000_000),
        networks: [
            DeviceNetworkDisplayRate(interfaceName: "ens192", receiveBytesPerSecond: 2_048, transmitBytesPerSecond: 4_096),
            DeviceNetworkDisplayRate(interfaceName: "cni0", receiveBytesPerSecond: 8_192, transmitBytesPerSecond: 16_384),
            DeviceNetworkDisplayRate(interfaceName: "cali1234", receiveBytesPerSecond: 16_384, transmitBytesPerSecond: 32_768),
            DeviceNetworkDisplayRate(interfaceName: "flannel.1", receiveBytesPerSecond: 32_768, transmitBytesPerSecond: 65_536),
            DeviceNetworkDisplayRate(interfaceName: "ovn-k8s-mp0", receiveBytesPerSecond: 4_096, transmitBytesPerSecond: 8_192),
            DeviceNetworkDisplayRate(interfaceName: "tailscale0", receiveBytesPerSecond: 1_024, transmitBytesPerSecond: 2_048)
        ],
        disks: sample.disks,
        diskIO: DeviceDiskIODisplayRate(readBytesPerSecond: 2_048, writeBytesPerSecond: 4_096)
    )

    func with(cpuUsage: Double?) -> DeviceMetricsDisplaySnapshot {
        DeviceMetricsDisplaySnapshot(
            cpuUsage: cpuUsage,
            cpuCoreUsages: cpuCoreUsages,
            system: system,
            memory: memory,
            networks: networks,
            disks: disks,
            diskIO: diskIO
        )
    }

    private static let sampleCPUCoreUsages: [DeviceCPUCoreDisplayUsage] = [
        0.182,
        0.182,
        0.091,
        0.048,
        0.136,
        0.087,
        0.227,
        0.227
    ].enumerated().map { index, usage in
        DeviceCPUCoreDisplayUsage(index: index, usage: usage)
    }

    private static let sampleSystemInfo = DeviceSystemDisplayInfo(
        hostname: "worker-01",
        currentUser: "deploy",
        architecture: "x86_64",
        operatingSystem: "Ubuntu 25.10",
        uptimeText: "14天",
        kernelVersion: "6.8.0-64-generic",
        cpuModel: "Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz"
    )
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
