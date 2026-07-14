import Foundation

public struct GraphicsRuntimeStartRequest: Equatable {
    public let protocolName: String
    public let adapterPath: String
    public let arguments: [String]
    public let host: String
    public let port: UInt16

    public init(
        protocolName: String,
        adapterPath: String,
        arguments: [String],
        host: String,
        port: UInt16
    ) {
        self.protocolName = protocolName
        self.adapterPath = adapterPath
        self.arguments = arguments
        self.host = host
        self.port = port
    }
}

public enum GraphicsRuntimePresentation: Equatable {
    case diagnostic
    case externalClient(String)
    case embeddedSurface
}

public struct GraphicsRuntimeStatus: Equatable {
    public let runtimeID: String
    public let status: String
    public let diagnostic: String
    public let attachment: GraphicsRuntimeAttachment?
    public let presentation: GraphicsRuntimePresentation

    public init(
        runtimeID: String,
        status: String,
        diagnostic: String,
        attachment: GraphicsRuntimeAttachment? = nil,
        presentation: GraphicsRuntimePresentation = .diagnostic
    ) {
        self.runtimeID = runtimeID
        self.status = status
        self.diagnostic = diagnostic
        self.attachment = attachment
        self.presentation = presentation
    }
}

public protocol GraphicsRuntimeManaging {
    func start(request: GraphicsRuntimeStartRequest) throws -> GraphicsRuntimeStatus
    func stop(runtimeID: String) -> GraphicsRuntimeStatus
}

public struct GraphicsAdapterLaunchHandle: Equatable {
    public let processIdentifier: Int32

    public init(processIdentifier: Int32) {
        self.processIdentifier = processIdentifier
    }
}

public protocol GraphicsAdapterLaunching {
    @discardableResult
    func launchAdapter(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> GraphicsAdapterLaunchHandle
    func terminateAdapter(processIdentifier: Int32)
}

public enum GraphicsAdapterLaunchError: Error, Equatable {
    case immediateFailure(exitCode: Int32, output: String)

    var exitCode: Int32 {
        switch self {
        case .immediateFailure(let exitCode, _):
            return exitCode
        }
    }

    var output: String {
        switch self {
        case .immediateFailure(_, let output):
            return output
        }
    }
}

public enum GraphicsRuntimeError: Error, Equatable, LocalizedError {
    case adapterOutsideBundle(String)
    case unsupportedProtocol(String)

    public var errorDescription: String? {
        switch self {
        case .adapterOutsideBundle(let path):
            return "图形适配器必须位于 Stacio.app/Contents/Adapters 内：\(path)"
        case .unsupportedProtocol(let protocolName):
            return "不支持的图形会话协议：\(protocolName)"
        }
    }
}

public final class ProcessGraphicsAdapterLauncher: GraphicsAdapterLaunching {
    private var processes: [Int32: Process] = [:]
    private let lock = NSLock()
    private let immediateFailureProbeInterval: TimeInterval
    private let appLog: StacioLogWriting?

    public init(
        immediateFailureProbeInterval: TimeInterval = 1.0,
        appLog: StacioLogWriting? = StacioLogStore.shared
    ) {
        self.immediateFailureProbeInterval = immediateFailureProbeInterval
        self.appLog = appLog
    }

    @discardableResult
    public func launchAdapter(
        executablePath: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> GraphicsAdapterLaunchHandle {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in
                override
            }
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] terminatedProcess in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            self?.appLog?.append(
                level: terminatedProcess.terminationStatus == 0 ? .info : .error,
                category: "Graphics",
                message: "graphics.adapter.terminated process=\(terminatedProcess.processIdentifier) status=\(terminatedProcess.terminationStatus)"
            )
            self?.removeProcess(processIdentifier: terminatedProcess.processIdentifier)
        }
        try process.run()

        let handle = GraphicsAdapterLaunchHandle(processIdentifier: process.processIdentifier)
        if waitForImmediateExit(process) {
            let output = Self.collectedOutput(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
            if process.terminationStatus != 0 {
                throw GraphicsAdapterLaunchError.immediateFailure(
                    exitCode: process.terminationStatus,
                    output: output
                )
            }
        } else {
            drain(stdoutPipe, streamName: "stdout", processIdentifier: handle.processIdentifier, arguments: arguments)
            drain(stderrPipe, streamName: "stderr", processIdentifier: handle.processIdentifier, arguments: arguments)
        }
        store(process, processIdentifier: handle.processIdentifier)
        if !process.isRunning {
            removeProcess(processIdentifier: handle.processIdentifier)
        }
        return handle
    }

    public func terminateAdapter(processIdentifier: Int32) {
        let process = process(processIdentifier: processIdentifier)
        if process?.isRunning == true {
            process?.terminate()
        }
        removeProcess(processIdentifier: processIdentifier)
    }

    private func waitForImmediateExit(_ process: Process) -> Bool {
        let deadline = Date().addingTimeInterval(immediateFailureProbeInterval)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
    }

    private func drain(
        _ pipe: Pipe,
        streamName: String,
        processIdentifier: Int32,
        arguments: [String]
    ) {
        let sensitiveValues = StacioLogStore.sensitiveArgumentValues(arguments)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty
            else {
                return
            }
            for line in output.components(separatedBy: .newlines) where !line.isEmpty {
                self.appLog?.append(
                    level: streamName == "stderr" ? .warning : .info,
                    category: "Graphics",
                    message: "graphics.adapter.output process=\(processIdentifier) stream=\(streamName) \(line)",
                    sensitiveValues: sensitiveValues
                )
            }
        }
    }

    private static func collectedOutput(stdoutPipe: Pipe, stderrPipe: Pipe) -> String {
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func store(_ process: Process, processIdentifier: Int32) {
        lock.lock()
        processes[processIdentifier] = process
        lock.unlock()
    }

    private func process(processIdentifier: Int32) -> Process? {
        lock.lock()
        let process = processes[processIdentifier]
        lock.unlock()
        return process
    }

    private func removeProcess(processIdentifier: Int32) {
        lock.lock()
        processes[processIdentifier] = nil
        lock.unlock()
    }
}

public final class DefaultGraphicsRuntimeManager: GraphicsRuntimeManaging {
    private let launcher: GraphicsAdapterLaunching
    private let bundleURL: URL
    private let appLog: StacioLogWriting?
    private var handlesByRuntimeID: [String: GraphicsAdapterLaunchHandle] = [:]
    private let handleLock = NSLock()

    public init(
        launcher: GraphicsAdapterLaunching = ProcessGraphicsAdapterLauncher(),
        bundleURL: URL = Bundle.main.bundleURL,
        appLog: StacioLogWriting? = StacioLogStore.shared
    ) {
        self.launcher = launcher
        self.bundleURL = bundleURL
        self.appLog = appLog
    }

    public func start(request: GraphicsRuntimeStartRequest) throws -> GraphicsRuntimeStatus {
        logStart(request)
        guard isSupportedGraphicsProtocol(request.protocolName) else {
            appLog?.append(
                level: .error,
                category: "Graphics",
                message: "graphics.rejected protocol=\(request.protocolName) endpoint=\(request.host):\(request.port) reason=unsupported-protocol"
            )
            throw GraphicsRuntimeError.unsupportedProtocol(request.protocolName)
        }
        guard isPackagedAdapterPath(request.adapterPath) else {
            appLog?.append(
                level: .error,
                category: "Graphics",
                message: "graphics.rejected protocol=\(request.protocolName) endpoint=\(request.host):\(request.port) reason=adapter-outside-bundle adapter=\(request.adapterPath)"
            )
            throw GraphicsRuntimeError.adapterOutsideBundle(request.adapterPath)
        }
        let runtimeID = "graphics_\(UUID().uuidString.lowercased())"
        let environment = launchEnvironment(for: request)
        let presentation = presentation(for: request)
        let diagnostic = startingDiagnostic(for: request)
        do {
            let handle = try launcher.launchAdapter(
                executablePath: request.adapterPath,
                arguments: request.arguments,
                environment: environment
            )
            store(handle: handle, runtimeID: runtimeID)
            appLog?.append(
                level: .info,
                category: "Graphics",
                message: "graphics.started protocol=\(request.protocolName) endpoint=\(request.host):\(request.port) runtime=\(runtimeID) process=\(handle.processIdentifier)"
            )
            return GraphicsRuntimeStatus(
                runtimeID: runtimeID,
                status: "running",
                diagnostic: diagnostic,
                presentation: presentation
            )
        } catch let error as GraphicsAdapterLaunchError {
            let status = GraphicsRuntimeStatus(
                runtimeID: runtimeID,
                status: "failed",
                diagnostic: launchFailureDiagnostic(
                    for: request,
                    exitCode: error.exitCode,
                    output: error.output
                )
            )
            logFailure(status, request: request)
            return status
        } catch {
            let status = GraphicsRuntimeStatus(
                runtimeID: runtimeID,
                status: "failed",
                diagnostic: launchFailureDiagnostic(
                    for: request,
                    exitCode: nil,
                    output: String(describing: error)
                )
            )
            logFailure(status, request: request)
            return status
        }
    }

    public func stop(runtimeID: String) -> GraphicsRuntimeStatus {
        if let handle = removeHandle(runtimeID: runtimeID) {
            launcher.terminateAdapter(processIdentifier: handle.processIdentifier)
        }
        appLog?.append(
            level: .info,
            category: "Graphics",
            message: "graphics.stopped runtime=\(runtimeID)"
        )
        return GraphicsRuntimeStatus(
            runtimeID: runtimeID,
            status: "closed",
            diagnostic: L10n.Graphics.adapterStopped
        )
    }

    private func isPackagedAdapterPath(_ path: String) -> Bool {
        let adaptersURL = bundleURL
            .appendingPathComponent("Contents/Adapters", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let adapterURL = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let adaptersPath = adaptersURL.path
        let adapterPath = adapterURL.path
        return adapterPath.hasPrefix("\(adaptersPath)/")
            && adapterPath.count > adaptersPath.count + 1
    }

    private func launchFailureDiagnostic(
        for request: GraphicsRuntimeStartRequest,
        exitCode: Int32?,
        output: String
    ) -> String {
        L10n.Graphics.adapterLaunchFailed(
            request.protocolName,
            exitCode: exitCode,
            output: redactedDiagnosticOutput(output, arguments: request.arguments)
        )
    }

    private func redactedDiagnosticOutput(_ output: String, arguments: [String]) -> String {
        var sanitized = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for value in sensitiveArgumentValues(arguments) where !value.isEmpty {
            sanitized = sanitized.replacingOccurrences(of: value, with: "<redacted>")
        }
        let maxLength = 1_200
        if sanitized.count > maxLength {
            let end = sanitized.index(sanitized.startIndex, offsetBy: maxLength)
            sanitized = "\(sanitized[..<end])\n..."
        }
        return sanitized
    }

    private func startingDiagnostic(for request: GraphicsRuntimeStartRequest) -> String {
        L10n.Graphics.adapterStarting(request.protocolName)
    }

    private func presentation(for request: GraphicsRuntimeStartRequest) -> GraphicsRuntimePresentation {
        .diagnostic
    }

    private func launchEnvironment(for request: GraphicsRuntimeStartRequest) -> [String: String] {
        [:]
    }

    private func isSupportedGraphicsProtocol(_ protocolName: String) -> Bool {
        switch protocolName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "VNC":
            return true
        default:
            return false
        }
    }

    private func logStart(_ request: GraphicsRuntimeStartRequest) {
        appLog?.append(
            level: .info,
            category: "Graphics",
            message: [
                "graphics.start",
                "protocol=\(request.protocolName)",
                "endpoint=\(request.host):\(request.port)",
                "adapter=\(request.adapterPath)",
                "arguments=\(StacioLogStore.redactedArguments(request.arguments).joined(separator: " "))"
            ].joined(separator: " "),
            sensitiveValues: sensitiveArgumentValues(request.arguments)
        )
    }

    private func logFailure(_ status: GraphicsRuntimeStatus, request: GraphicsRuntimeStartRequest) {
        appLog?.append(
            level: .error,
            category: "Graphics",
            message: "graphics.failed protocol=\(request.protocolName) endpoint=\(request.host):\(request.port) runtime=\(status.runtimeID) diagnostic=\(status.diagnostic)",
            sensitiveValues: sensitiveArgumentValues(request.arguments)
        )
    }

    private func sensitiveArgumentValues(_ arguments: [String]) -> [String] {
        var values: [String] = []
        var shouldCaptureNext = false
        for argument in arguments {
            if shouldCaptureNext {
                values.append(argument)
                shouldCaptureNext = false
                continue
            }
            if argument == "--password" || argument == "-p" || argument == "--gw-pass" {
                shouldCaptureNext = true
            }
        }
        return values
    }

    private func store(handle: GraphicsAdapterLaunchHandle, runtimeID: String) {
        handleLock.lock()
        handlesByRuntimeID[runtimeID] = handle
        handleLock.unlock()
    }

    private func removeHandle(runtimeID: String) -> GraphicsAdapterLaunchHandle? {
        handleLock.lock()
        let handle = handlesByRuntimeID.removeValue(forKey: runtimeID)
        handleLock.unlock()
        return handle
    }
}
