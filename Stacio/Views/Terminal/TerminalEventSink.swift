import Foundation

public struct TerminalResizeEvent: Equatable {
    public let runtimeID: String
    public let cols: Int
    public let rows: Int

    public init(runtimeID: String, cols: Int, rows: Int) {
        self.runtimeID = runtimeID
        self.cols = cols
        self.rows = rows
    }
}

public struct TerminalInputEvent: Equatable {
    public let runtimeID: String
    public let bytes: [UInt8]

    public init(runtimeID: String, bytes: [UInt8]) {
        self.runtimeID = runtimeID
        self.bytes = bytes
    }
}

public protocol TerminalEventSink: AnyObject {
    func terminalDidResize(runtimeID: String, cols: Int, rows: Int) throws
    func terminalDidProduceOutput(runtimeID: String, bytes: [UInt8]) throws
    func terminalDidReceiveInput(runtimeID: String, bytes: [UInt8]) throws
    func terminalDidClose(runtimeID: String) throws
}

enum TerminalResizeValidator {
    static func shouldForward(cols: Int, rows: Int) -> Bool {
        sanitized(cols: cols, rows: rows) != nil
    }

    static func sanitized(cols: Int, rows: Int) -> (cols: UInt32, rows: UInt32)? {
        guard let safeCols = UInt32(exactly: cols),
              let safeRows = UInt32(exactly: rows),
              safeCols > 0,
              safeRows > 0
        else {
            return nil
        }
        return (safeCols, safeRows)
    }
}

public final class CoreBridgeTerminalEventSink: TerminalEventSink {
    public init() {}

    public func terminalDidResize(runtimeID: String, cols: Int, rows: Int) throws {
        guard let sanitized = TerminalResizeValidator.sanitized(cols: cols, rows: rows) else {
            return
        }
        _ = try CoreBridge.recordTerminalResize(runtimeID: runtimeID, cols: sanitized.cols, rows: sanitized.rows)
    }

    public func terminalDidProduceOutput(runtimeID: String, bytes: [UInt8]) throws {
        try CoreBridge.recordTerminalOutput(runtimeID: runtimeID, bytes: bytes)
    }

    public func terminalDidReceiveInput(runtimeID: String, bytes: [UInt8]) throws {
        try CoreBridge.writeTerminalInput(runtimeID: runtimeID, bytes: bytes)
    }

    public func terminalDidClose(runtimeID: String) throws {
        _ = try CoreBridge.closeTerminalRuntime(runtimeID: runtimeID)
    }
}
