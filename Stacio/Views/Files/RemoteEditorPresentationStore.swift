import AppKit

public struct RemoteEditorScreenIdentity: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let localizedName: String
    public let frame: NSRect

    public init(displayID: UInt32, localizedName: String, frame: NSRect) {
        self.displayID = displayID
        self.localizedName = localizedName
        self.frame = frame
    }
}

public protocol RemoteEditorPresentationStoring: AnyObject {
    func sidecarTargetWidth() -> CGFloat?
    func saveSidecarTargetWidth(_ width: CGFloat)
    func floatingFrame() -> NSRect?
    func saveFloatingFrame(_ frame: NSRect)
    func screenIdentity() -> RemoteEditorScreenIdentity?
    func saveScreenIdentity(_ identity: RemoteEditorScreenIdentity?)
}

public final class UserDefaultsRemoteEditorPresentationStore: RemoteEditorPresentationStoring {
    public static let defaultSidecarWidth: CGFloat = 680
    public static let minimumPersistedSidecarWidth: CGFloat = 480
    public static let maximumPersistedSidecarWidth: CGFloat = 4_096

    static let floatingFrameKey = "Stacio.RemoteEditorWindow.frame.v1"
    static let screenKey = "Stacio.RemoteEditorWindow.screen.v1"

    private let defaults: UserDefaults
    private let sidecarWidthKey: String

    public init(
        defaults: UserDefaults = .standard,
        frameAutosaveName: NSWindow.FrameAutosaveName
    ) {
        self.defaults = defaults
        sidecarWidthKey = "Stacio.WorkbenchEditorSidecar.width.\(frameAutosaveName)"
    }

    public func sidecarTargetWidth() -> CGFloat? {
        guard let number = defaults.object(forKey: sidecarWidthKey) as? NSNumber else {
            return nil
        }
        let width = CGFloat(number.doubleValue)
        return Self.isValidSidecarWidth(width) ? width : nil
    }

    public func saveSidecarTargetWidth(_ width: CGFloat) {
        guard Self.isValidSidecarWidth(width) else { return }
        defaults.set(Double(width), forKey: sidecarWidthKey)
    }

    public func floatingFrame() -> NSRect? {
        guard let encoded = defaults.string(forKey: Self.floatingFrameKey) else {
            return nil
        }
        let frame = NSRectFromString(encoded)
        return Self.isValidFrame(frame) ? frame : nil
    }

    public func saveFloatingFrame(_ frame: NSRect) {
        guard Self.isValidFrame(frame) else { return }
        defaults.set(NSStringFromRect(frame), forKey: Self.floatingFrameKey)
    }

    public func screenIdentity() -> RemoteEditorScreenIdentity? {
        guard let data = defaults.data(forKey: Self.screenKey),
              let identity = try? JSONDecoder().decode(RemoteEditorScreenIdentity.self, from: data),
              Self.isValidFrame(identity.frame)
        else {
            return nil
        }
        return identity
    }

    public func saveScreenIdentity(_ identity: RemoteEditorScreenIdentity?) {
        guard let identity else {
            defaults.removeObject(forKey: Self.screenKey)
            return
        }
        guard Self.isValidFrame(identity.frame),
              let data = try? JSONEncoder().encode(identity)
        else { return }
        defaults.set(data, forKey: Self.screenKey)
    }

    var sidecarWidthKeyForTesting: String {
        sidecarWidthKey
    }

    private static func isValidSidecarWidth(_ width: CGFloat) -> Bool {
        width.isFinite
            && (minimumPersistedSidecarWidth...maximumPersistedSidecarWidth).contains(width)
    }

    private static func isValidFrame(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.size.width.isFinite
            && frame.size.height.isFinite
            && frame.size.width > 0
            && frame.size.height > 0
    }
}
