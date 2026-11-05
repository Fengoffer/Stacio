import AppKit

enum DeviceMetricsAlertMetric { case cpuUsage, memoryUsage, diskUsage, networkIO, diskIO }

@main
struct SurfaceChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        NSApp.activate(ignoringOtherApps: true)
        func pump(_ seconds: TimeInterval = 0.2) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until { _ = RunLoop.main.run(mode: .default, before: until) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let native = GlassCapabilityEnvironment(supportsSystemGlass: true, reduceTransparency: false, increaseContrast: false)
        let oldSystem = GlassCapabilityEnvironment(supportsSystemGlass: false, reduceTransparency: false, increaseContrast: false)
        let reducedTransparency = GlassCapabilityEnvironment(supportsSystemGlass: true, reduceTransparency: true, increaseContrast: false)
        let increasedContrast = GlassCapabilityEnvironment(supportsSystemGlass: true, reduceTransparency: false, increaseContrast: true)
        let cores: [DeviceCPUCoreDisplayUsage] = [0.27, 0.82, 0.95, 0.42].enumerated().map {
            DeviceCPUCoreDisplayUsage(index: $0.offset, usage: $0.element)
        }
        var processes: [DeviceProcessDisplayInfo] = []
        for index in 1...10 {
            let name: String = index == 1 ? "java" : "worker-\(index)"
            let cpu: Double = index == 1 ? 0.535 : Double(11 - index) / 100.0
            let memory: Double = Double(11 - index) / 100.0
            let bytes: UInt64 = UInt64(11 - index) * 134_217_728
            processes.append(DeviceProcessDisplayInfo(pid: UInt32(index), name: name, cpuFraction: cpu,
                                                       memoryFraction: memory, residentBytes: bytes))
        }
        let sample = DeviceMetricsDisplaySnapshot(cpuUsage: 0.57,
            cpuCoreUsages: cores,
            memory: .init(usedBytes: 6_442_450_944, totalBytes: 17_179_869_184, freeBytes: 2_147_483_648,
                          buffersBytes: 536_870_912, cachedBytes: 8_053_063_680,
                          swapTotalBytes: 4_294_967_296, swapFreeBytes: 3_221_225_472),
            networks: [], disks: [], processes: processes)
        func update(_ controller: DeviceMetricsStatusDetailViewController, title: String) {
            controller.update(title: title, detail: "", snapshot: sample) { value, _ in
                value >= 0.9 ? .systemRed : value >= 0.8 ? .systemOrange : .systemGreen
            }
        }
        func requireNoCustomOutline(_ surface: NSView) {
            precondition((surface.layer?.borderWidth ?? 0) == 0, "Surface has a custom rectangular outline")
        }
        func requireRoundedMask(_ effect: NSVisualEffectView) {
            guard let mask = effect.maskImage, let data = mask.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: data) else {
                preconditionFailure("Fallback material has no renderable native mask")
            }
            precondition(mask.capInsets.top == 14 && mask.capInsets.left == 14
                         && mask.capInsets.bottom == 14 && mask.capInsets.right == 14
                         && mask.resizingMode == .stretch)
            for (x, y) in [(0, 0), (bitmap.pixelsWide - 1, 0), (0, bitmap.pixelsHigh - 1),
                           (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)] {
                precondition(bitmap.colorAt(x: x, y: y)!.alphaComponent < 0.01,
                             "Fallback backdrop mask leaves an opaque corner")
            }
            precondition(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.alphaComponent > 0.99)
            precondition(effect.blendingMode == .behindWindow && effect.material == .popover)
            requireNoCustomOutline(effect)
        }

        // Popovers own their effect, outline and arrow. Their content root must
        // remain transparent regardless of glass/accessibility capability.
        for environment in [native, oldSystem, reducedTransparency, increasedContrast] {
            let popover = DeviceMetricsStatusDetailViewController(surfaceEnvironment: environment)
            update(popover, title: "CPU")
            precondition(!popover.view.isOpaque && !(popover.view is NSVisualEffectView))
            if #available(macOS 26.0, *) { precondition(!(popover.view is NSGlassEffectView)) }
            precondition(!descendants(popover.view).contains { $0 is NSVisualEffectView },
                         "Popover contents added a duplicate material inside AppKit's own surface")
            precondition(popover.view.layer?.backgroundColor?.alpha ?? 0 == 0)
            requireNoCustomOutline(popover.view)
        }

        // macOS 14 and accessibility fallbacks retain a rounded native effect
        // mask; a layer corner alone does not mask behind-window material.
        for environment in [oldSystem, reducedTransparency, increasedContrast] {
            let fallback = DeviceMetricsStatusDetailViewController(presentation: .floating, surfaceEnvironment: environment)
            update(fallback, title: "内存")
            guard let effect = fallback.view as? NSVisualEffectView else { preconditionFailure("Missing fallback effect") }
            requireRoundedMask(effect)
        }

        let screen = NSScreen.main!.visibleFrame
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for (environment, mode) in [(native, "native"), (oldSystem, "fallback")] {
                let controller = DeviceMetricsStatusDetailViewController(presentation: .floating, surfaceEnvironment: environment)
                update(controller, title: "CPU")
                let panel = NSPanel(contentRect: NSRect(origin: .zero, size: controller.preferredContentSize),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.appearance = NSAppearance(named: appearance)
                panel.contentViewController = controller
                panel.setContentSize(controller.preferredContentSize)
                panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.midY - panel.frame.height / 2))
                panel.orderFront(nil)
                pump(0.4)
                controller.view.layoutSubtreeIfNeeded()
                requireNoCustomOutline(controller.view)
                if mode == "native", #available(macOS 26.0, *) {
                    guard let glass = controller.view as? NSGlassEffectView else { preconditionFailure("Missing native glass") }
                    precondition(glass.cornerRadius == 14 && glass.contentView != nil)
                }
                let path = "/tmp/stacio-detail-surface-\(mode)-\(suffix).png"
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(panel.windowNumber), path]
                try capture.run()
                capture.waitUntilExit()
                precondition(capture.terminationStatus == 0, "Window-server capture failed")
                guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))) else {
                    preconditionFailure("Cannot read screenshot")
                }
                precondition(bitmap.hasAlpha && bitmap.pixelsWide >= Int(panel.frame.width), "Screenshot lost window alpha")
                let corners = [(0, 0), (bitmap.pixelsWide - 1, 0), (0, bitmap.pixelsHigh - 1),
                               (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)]
                for (x, y) in corners {
                    let color = bitmap.colorAt(x: x, y: y)!
                    precondition(color.alphaComponent < 0.05, "\(mode)/\(suffix) screenshot has an opaque/white square corner at \(x),\(y)")
                }
                precondition(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.alphaComponent > 0.2,
                             "Captured surface is empty")
                print("WINDOW SNAPSHOT: \(path) [\(bitmap.pixelsWide)x\(bitmap.pixelsHigh), transparent corners]")
                panel.orderOut(nil)
                panel.close()
                pump()
            }
        }
        print("Detail surface checks passed: transparent popovers, native radius/content slot, macOS 14/accessibility masks, no custom outline, native/fallback light/dark window-server alpha")
    }
}
