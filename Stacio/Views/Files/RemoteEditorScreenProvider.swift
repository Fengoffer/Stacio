import AppKit

public struct RemoteEditorScreenDescriptor: Equatable, Sendable {
    public let identity: RemoteEditorScreenIdentity
    public let frame: NSRect
    public let visibleFrame: NSRect

    public init(
        identity: RemoteEditorScreenIdentity,
        frame: NSRect,
        visibleFrame: NSRect
    ) {
        self.identity = identity
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

@MainActor
public protocol RemoteEditorScreenProviding: AnyObject {
    func availableScreens() -> [RemoteEditorScreenDescriptor]
    func descriptor(containing window: NSWindow?) -> RemoteEditorScreenDescriptor?
}

@MainActor
public final class AppKitRemoteEditorScreenProvider: RemoteEditorScreenProviding {
    public init() {}

    public func availableScreens() -> [RemoteEditorScreenDescriptor] {
        NSScreen.screens.compactMap(Self.descriptor)
    }

    public func descriptor(containing window: NSWindow?) -> RemoteEditorScreenDescriptor? {
        guard let screen = window?.screen ?? NSScreen.main else { return nil }
        return Self.descriptor(screen)
    }

    private static func descriptor(_ screen: NSScreen) -> RemoteEditorScreenDescriptor? {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[screenNumberKey] as? NSNumber else {
            return nil
        }
        let identity = RemoteEditorScreenIdentity(
            displayID: number.uint32Value,
            localizedName: screen.localizedName,
            frame: screen.frame
        )
        return RemoteEditorScreenDescriptor(
            identity: identity,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
    }
}

public enum RemoteEditorScreenResolver {
    public static func resolve(
        _ identity: RemoteEditorScreenIdentity?,
        screens: [RemoteEditorScreenDescriptor]
    ) -> RemoteEditorScreenDescriptor? {
        guard let identity else { return nil }
        if let exact = screens.first(where: { $0.identity.displayID == identity.displayID }) {
            return exact
        }
        return screens
            .filter { $0.identity.localizedName == identity.localizedName }
            .min { frameDistance($0.frame, identity.frame) < frameDistance($1.frame, identity.frame) }
    }

    public static func menuLabels(for screens: [RemoteEditorScreenDescriptor]) -> [String] {
        let counts = Dictionary(grouping: screens, by: { $0.identity.localizedName })
            .mapValues(\.count)
        let sorted = screens.sorted(by: screenGeometryOrder)
        var ordinals: [UInt32: Int] = [:]
        var nextOrdinalByName: [String: Int] = [:]
        for screen in sorted {
            let name = screen.identity.localizedName
            guard counts[name, default: 0] > 1 else { continue }
            let ordinal = nextOrdinalByName[name, default: 0] + 1
            nextOrdinalByName[name] = ordinal
            ordinals[screen.identity.displayID] = ordinal
        }
        return screens.map { screen in
            let name = screen.identity.localizedName
            guard let ordinal = ordinals[screen.identity.displayID] else { return name }
            return "显示器 \(ordinal) - \(name)"
        }
    }

    public static func clamp(
        _ frame: NSRect,
        to visibleFrame: NSRect,
        minimumSize: NSSize
    ) -> NSRect {
        guard isValidPhysicalFrame(visibleFrame) else { return frame }

        let requestedWidth = frame.width.isFinite && frame.width > 0
            ? frame.width
            : minimumSize.width
        let requestedHeight = frame.height.isFinite && frame.height > 0
            ? frame.height
            : minimumSize.height
        let minimumWidth = minimumSize.width.isFinite && minimumSize.width > 0
            ? minimumSize.width
            : 1
        let minimumHeight = minimumSize.height.isFinite && minimumSize.height > 0
            ? minimumSize.height
            : 1
        let width = min(visibleFrame.width, max(minimumWidth, requestedWidth))
        let height = min(visibleFrame.height, max(minimumHeight, requestedHeight))
        let requestedX = frame.origin.x.isFinite ? frame.origin.x : visibleFrame.minX
        let requestedY = frame.origin.y.isFinite ? frame.origin.y : visibleFrame.minY
        let x = min(max(requestedX, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(requestedY, visibleFrame.minY), visibleFrame.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func frameDistance(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let values = [
            lhs.minX - rhs.minX,
            lhs.minY - rhs.minY,
            lhs.width - rhs.width,
            lhs.height - rhs.height
        ]
        return values.reduce(0) { $0 + ($1 * $1) }
    }

    private static func screenGeometryOrder(
        _ lhs: RemoteEditorScreenDescriptor,
        _ rhs: RemoteEditorScreenDescriptor
    ) -> Bool {
        if lhs.frame.minX != rhs.frame.minX {
            return lhs.frame.minX < rhs.frame.minX
        }
        if lhs.frame.minY != rhs.frame.minY {
            return lhs.frame.minY < rhs.frame.minY
        }
        return lhs.identity.displayID < rhs.identity.displayID
    }

    private static func isValidPhysicalFrame(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }
}
