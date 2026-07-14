import Foundation

public enum GraphicsPixelFormat: Equatable {
    case bgra8Unorm
}

public struct GraphicsFrame: Equatable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixelFormat: GraphicsPixelFormat
    public let pixels: Data

    public init(width: Int, height: Int, bytesPerRow: Int, pixelFormat: GraphicsPixelFormat, pixels: Data) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.pixels = pixels
    }
}

public struct GraphicsPointerBitmap: Equatable {
    public let width: Int
    public let height: Int
    public let hotspotX: Int
    public let hotspotY: Int
    public let rgbaPixels: Data

    public init(width: Int, height: Int, hotspotX: Int, hotspotY: Int, rgbaPixels: Data) {
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.rgbaPixels = rgbaPixels
    }
}

public enum GraphicsMouseButton: UInt8, Equatable {
    case left = 0
    case middle = 1
    case right = 2
    case x1 = 3
    case x2 = 4
}

public enum GraphicsInputEvent: Equatable {
    case resize(width: Int, height: Int, scaleFactor: Double)
    case mouseMoved(x: Int, y: Int)
    case mouseButton(button: GraphicsMouseButton, isPressed: Bool, x: Int, y: Int)
    case scroll(deltaX: Int, deltaY: Int, x: Int, y: Int)
    case key(scancode: UInt16, isExtended: Bool, isPressed: Bool)
    case fileDrop(paths: [String], x: Int, y: Int)
    case clipboardTextPaste(String)
    case close
}

public protocol EmbeddedGraphicsSession: AnyObject {
    var onFrame: ((GraphicsFrame) -> Void)? { get set }
    var onPointerPosition: ((_ x: Int, _ y: Int) -> Void)? { get set }
    var onPointerVisibilityChanged: ((_ isVisible: Bool) -> Void)? { get set }
    var onPointerBitmap: ((GraphicsPointerBitmap) -> Void)? { get set }
    func start() throws
    func stop()
    func sendInput(_ event: GraphicsInputEvent)
}

public enum GraphicsRuntimeAttachmentKind: Equatable {
    case embeddedGraphics
}

public final class GraphicsRuntimeAttachment: Equatable {
    public let runtimeID: String
    public let kind: GraphicsRuntimeAttachmentKind
    public let session: EmbeddedGraphicsSession

    public init(runtimeID: String, kind: GraphicsRuntimeAttachmentKind, session: EmbeddedGraphicsSession) {
        self.runtimeID = runtimeID
        self.kind = kind
        self.session = session
    }

    public static func == (lhs: GraphicsRuntimeAttachment, rhs: GraphicsRuntimeAttachment) -> Bool {
        lhs.runtimeID == rhs.runtimeID && lhs.kind == rhs.kind
    }
}
