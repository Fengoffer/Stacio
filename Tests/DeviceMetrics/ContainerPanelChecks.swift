import AppKit

struct RemoteCommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

private final class PortRowHarness {
    // PORT_ROW_METHOD
}

@main
struct ContainerPanelChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let panel = DeviceMetricsInventoryPanel(segment: 4)
        let container = ManagedContainerInfo(id: "aaaa", name: "docker-app", image: "app", status: "running", isRunning: true, isPaused: false)
        let row = DeviceMetricsInventoryPanel.Row(id: "aaaa", title: "docker-app", subtitle: "app", badge: "运行中", tone: .success, filter: 1, search: "docker-app")
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        let authorize = descendants(panel).compactMap { $0 as? NSButton }.first { $0.title == "sudo 提权" }!
        func containsMessage(_ text: String, in view: NSView) -> Bool {
            descendants(view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(text) }
        }
        panel.update([row])
        panel.setFailure(DeviceMetricsInventoryError.partialContainerInventory([container], "Podman：权限不足", requiresAuthorization: true))
        precondition(panel.visibleRows.count == 1 && panel.countLabel.stringValue == "1 个容器（部分）")
        precondition(!authorize.isHidden)
        panel.setBusy(true)
        precondition(!authorize.isEnabled, "global authorization work must disable duplicate authorization clicks")
        panel.setLoading(true)
        precondition(!authorize.isEnabled)
        panel.setBusy(false)
        precondition(authorize.isEnabled, "ordinary loading does not suppress the authorization affordance")
        panel.setLoading(false)
        precondition(descendants(panel).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Podman：权限不足") })
        panel.setFailure(DeviceMetricsInventoryError.commandFailed("容器停止失败"))
        precondition(panel.countLabel.stringValue.contains("部分") && !authorize.isHidden)
        precondition(descendants(panel).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Podman：权限不足") && $0.stringValue.contains("容器停止失败") })
        panel.setFailure(DeviceMetricsInventoryError.partialContainerInventory([container], "Podman：未启动", requiresAuthorization: false))
        precondition(authorize.isHidden && panel.countLabel.stringValue.contains("部分"))
        panel.update([row])
        precondition(panel.countLabel.stringValue == "1 个容器" && authorize.isHidden)

        // Cross-tab authorization removes only obsolete permission messages;
        // existing partial container data stays marked until fresh data arrives.
        panel.setFailure(DeviceMetricsInventoryError.partialContainerInventory([container], "旧权限提示", requiresAuthorization: true))
        panel.clearAuthorizationFailure()
        precondition(panel.visibleRows == [row] && panel.countLabel.stringValue == "1 个容器（部分）")
        precondition(authorize.isHidden && !containsMessage("旧权限提示", in: panel))
        panel.setFailure(DeviceMetricsInventoryError.commandFailed("保留网络错误"))
        panel.clearAuthorizationFailure()
        precondition(containsMessage("保留网络错误", in: panel) && panel.countLabel.stringValue.contains("部分"))
        panel.setFailure(DeviceMetricsInventoryError.partialContainerInventory([container], "引擎未启动", requiresAuthorization: false))
        panel.setFailure(DeviceMetricsInventoryError.authorizationRequired("服务操作需要权限"))
        panel.clearAuthorizationFailure()
        precondition(containsMessage("引擎未启动", in: panel) && !containsMessage("服务操作需要权限", in: panel))
        precondition(panel.countLabel.stringValue.contains("部分") && authorize.isHidden)
        panel.update([])
        panel.setFailure(DeviceMetricsInventoryError.partialContainerInventory([], "空列表权限提示", requiresAuthorization: true))
        panel.clearAuthorizationFailure()
        precondition(panel.visibleRows.isEmpty && panel.countLabel.stringValue == "0 个容器（部分）")
        precondition(containsMessage("容器列表尚不完整", in: panel) && !containsMessage("没有容器", in: panel))
        panel.update([row])
        precondition(panel.countLabel.stringValue == "1 个容器" && !containsMessage("引擎未启动", in: panel))

        let portPanel = DeviceMetricsInventoryPanel(segment: 2)
        let portAuthorize = descendants(portPanel).compactMap { $0 as? NSButton }.first { $0.title == "sudo 提权" }!
        let ports = [
            ManagedPortInfo(id: "tcp:80", protocolName: "TCP", address: "0.0.0.0", port: 80, processName: "", pid: nil),
            ManagedPortInfo(id: "tcp:22", protocolName: "TCP", address: "0.0.0.0", port: 22, processName: "sshd", pid: 121),
        ]
        let portRows = PortRowHarness().portRows(ports)
        precondition(portRows.map(\.title) == ["0.0.0.0:22", "0.0.0.0:80"])
        precondition(portRows[0].subtitle == "sshd · PID 121" && portRows[0].buttons.count == 1)
        precondition(!portRows[0].buttons[0].isEnabled, "A PID without process birth identity is not safe to signal")
        precondition(portRows[1].subtitle == "未返回进程信息" && portRows[1].buttons.isEmpty)
        let pidOnlyRows = PortRowHarness().portRows([ManagedPortInfo(id: "tcp:443", protocolName: "TCP", address: "0.0.0.0", port: 443, processName: "", pid: 987)])
        precondition(pidOnlyRows[0].subtitle == "PID 987" && pidOnlyRows[0].buttons.count == 1)
        var identifiedPort = ports[1]
        identifiedPort.processIdentity = "100:20"
        let identifiedPortRow = PortRowHarness().portRows([identifiedPort])[0]
        precondition(identifiedPortRow.buttons[0].isEnabled)
        precondition(identifiedPortRow.buttons[0].action == .process(.terminate, 121, "100:20"), "Port action must retain the identity of its displayed owner")
        portPanel.update(portRows)
        portPanel.setFailure(DeviceMetricsInventoryError.partialPortInventory(ports, "进程归属查询需要权限", requiresAuthorization: true))
        precondition(portPanel.visibleRows == portRows && portPanel.countLabel.stringValue == "2 个监听")
        precondition(!portAuthorize.isHidden)
        func portMessage(containing text: String) -> String? {
            descendants(portPanel).compactMap { $0 as? NSTextField }.first { $0.stringValue.contains(text) }?.stringValue
        }
        precondition(portMessage(containing: "进程归属查询需要权限")?.hasPrefix("端口列表已更新，部分进程信息未获取。\n") == true)
        portPanel.setFailure(DeviceMetricsInventoryError.commandFailed("连接暂时中断"))
        precondition(portPanel.countLabel.stringValue == "2 个监听" && !portAuthorize.isHidden)
        let retainedMessage = portMessage(containing: "连接暂时中断")!
        precondition(retainedMessage.contains("进程归属查询需要权限") && retainedMessage.contains("部分进程信息未获取"))
        precondition(retainedMessage.hasPrefix("刷新失败，保留上次数据。\n"))
        portPanel.clearAuthorizationFailure()
        precondition(portPanel.visibleRows == portRows && portPanel.countLabel.stringValue == "2 个监听")
        precondition(portAuthorize.isHidden && portMessage(containing: "进程归属查询需要权限") == nil)
        precondition(portMessage(containing: "连接暂时中断") != nil)
        portPanel.setFailure(DeviceMetricsInventoryError.partialPortInventory(ports, "采集工具未返回归属", requiresAuthorization: false))
        precondition(portAuthorize.isHidden && portPanel.countLabel.stringValue == "2 个监听")
        portPanel.clearAuthorizationFailure()
        precondition(portMessage(containing: "采集工具未返回归属") != nil)
        portPanel.update(portRows)
        precondition(portAuthorize.isHidden && portMessage(containing: "采集工具未返回归属") == nil)
        portPanel.searchField.stringValue = "121"
        portPanel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        precondition(portPanel.visibleRows == [portRows[0]] && portPanel.countLabel.stringValue == "1 个监听")

        // Render real AppKit table cells: missing row actions must not move the
        // badge column, and two/three/four container actions share one column.
        for (segment, counts, slotCount) in [(1, [4, 4], 4), (2, [1, 0, 1, 0], 1), (3, [2, 2], 2), (4, [4, 3, 2], 4)] {
            let layoutPanel = DeviceMetricsInventoryPanel(segment: segment)
            let layoutRows = counts.enumerated().map { index, count in
                DeviceMetricsInventoryPanel.Row(id: "layout-\(index)", title: "row-\(index) long process or container name",
                    subtitle: "root · PID \(100 + index)", badge: "TCP6", tone: .normal, filter: 0, search: "row-\(index)",
                    buttons: (0..<count).map { button in
                        .init(symbol: "xmark.circle", title: "action-\(button)", action: .process(.terminate, UInt32(100 + index)))
                    })
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 580), styleMask: [.titled], backing: .buffered, defer: false)
            let root = NSView(frame: window.contentView!.bounds)
            window.contentView = root
            root.addSubview(layoutPanel)
            NSLayoutConstraint.activate([
                layoutPanel.topAnchor.constraint(equalTo: root.topAnchor),
                layoutPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                layoutPanel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
            layoutPanel.update(layoutRows)
            for width: CGFloat in [340, 680] {
                window.setContentSize(NSSize(width: width, height: 580))
                root.layoutSubtreeIfNeeded()
                layoutPanel.table.layoutSubtreeIfNeeded()
                var badgeOrigins: [CGFloat] = []
                var actionOrigins: [CGFloat] = []
                var textWidths: [CGFloat] = []
                for (index, row) in layoutPanel.visibleRows.enumerated() {
                    let cell = layoutPanel.table.view(atColumn: 0, row: index, makeIfNecessary: true)!
                    cell.layoutSubtreeIfNeeded()
                    let all = descendants(cell)
                    let badge = cell.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == row.badge }!
                    let name = all.compactMap { $0 as? NSTextField }.first { $0.stringValue == row.title }!
                    let actionGroup = cell.subviews.compactMap { $0 as? NSStackView }.first { $0.arrangedSubviews.contains { $0 is NSButton } }!
                    let badgeFrame = badge.convert(badge.bounds, to: cell)
                    let nameFrame = name.convert(name.bounds, to: cell)
                    let actionFrame = actionGroup.convert(actionGroup.bounds, to: cell)
                    let visibleButtons = all.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
                    precondition(visibleButtons.count == row.buttons.count, "empty action slots must not create controls")
                    precondition(abs(actionFrame.width - CGFloat(slotCount * 26)) < 0.5, "segment \(segment) expected action width \(slotCount * 26), got \(actionFrame), cell \(cell.frame)")
                    precondition(abs(badge.alignmentRect(forFrame: badge.frame).width - 54) < 0.5 && nameFrame.width >= 100,
                                 "segment \(segment) badge \(badgeFrame), name \(nameFrame), cell \(cell.frame)")
                    precondition(nameFrame.maxX <= badgeFrame.minX, "text and status frames must not overlap")
                    if let rightmost = visibleButtons.map({ $0.convert($0.bounds, to: cell).maxX }).max() {
                        precondition(abs(rightmost - (cell.bounds.maxX - 5)) <= 1, "segment \(segment), row \(index): rightmost action \(rightmost), group \(actionFrame), cell \(cell.bounds); available actions stay at the trailing edge")
                    }
                    badgeOrigins.append(badgeFrame.minX)
                    actionOrigins.append(actionFrame.minX)
                    textWidths.append(nameFrame.width)
                }
                for values in [badgeOrigins, actionOrigins, textWidths] {
                    precondition((values.max()! - values.min()!) < 0.5, "columns must align across different action counts")
                }
                print("LAYOUT segment=\(segment) width=\(Int(width)) badgeX=\(badgeOrigins) actionX=\(actionOrigins) titleWidth=\(textWidths)")
            }
            window.orderOut(nil)
        }
        print("PASS: partial container and port rows/count, ownership messages, retained authorization, successful recovery and safe process actions")
    }
}
