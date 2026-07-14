import Foundation

public enum AgentCLIParserError: Error, LocalizedError, Equatable {
    case missingCommand
    case unsupportedCommand(String)
    case missingValue(String)
    case missingRunCommand
    case missingRequestID

    public var errorDescription: String? {
        switch self {
        case .missingCommand:
            return "缺少 stacio agent 子命令。"
        case .unsupportedCommand(let command):
            return "不支持的 stacio agent 命令：\(command)"
        case .missingValue(let option):
            return "\(option) 缺少参数。"
        case .missingRunCommand:
            return "缺少要执行的命令。"
        case .missingRequestID:
            return "缺少要控制的 Agent request ID。"
        }
    }
}

public enum AgentCLIOutputMode: Equatable {
    case text
    case json
}

public struct AgentCLIInvocation: Equatable {
    public let request: AgentBridgeRequest
    public let outputMode: AgentCLIOutputMode
    public let socketPath: String?

    public init(request: AgentBridgeRequest, outputMode: AgentCLIOutputMode, socketPath: String?) {
        self.request = request
        self.outputMode = outputMode
        self.socketPath = socketPath
    }
}

public enum AgentCLIParser {
    public static func parse(_ arguments: [String]) throws -> AgentBridgeRequest {
        try parseInvocation(arguments).request
    }

    public static func parseInvocation(_ arguments: [String]) throws -> AgentCLIInvocation {
        var args = arguments
        if args.first == "agent" {
            args.removeFirst()
        }

        var outputMode = AgentCLIOutputMode.text
        var socketPath: String?
        optionLoop: while let first = args.first {
            switch first {
            case "--json":
                outputMode = .json
                args.removeFirst()
            case "--text":
                outputMode = .text
                args.removeFirst()
            case "--socket":
                args.removeFirst()
                guard let value = args.first else {
                    throw AgentCLIParserError.missingValue("--socket")
                }
                socketPath = value
                args.removeFirst()
            default:
                break optionLoop
            }
        }

        guard let command = args.first else {
            throw AgentCLIParserError.missingCommand
        }
        args.removeFirst()

        switch command {
        case "sessions":
            let options = try parseSessionOptions(
                args,
                inheritedOutputMode: outputMode,
                inheritedSocketPath: socketPath
            )
            return AgentCLIInvocation(
                request: AgentBridgeRequest(
                    id: UUID().uuidString,
                    actor: cliActor(),
                    action: .listSessions
                ),
                outputMode: options.outputMode,
                socketPath: options.socketPath
            )
        case "run":
            return try parseRun(args, outputMode: outputMode, socketPath: socketPath)
        case "pause":
            return try parseControl(
                args,
                outputMode: outputMode,
                socketPath: socketPath,
                action: AgentAction.pauseTask
            )
        case "cancel":
            return try parseControl(
                args,
                outputMode: outputMode,
                socketPath: socketPath,
                action: AgentAction.cancelTask
            )
        case "takeover", "take-over":
            return try parseControl(
                args,
                outputMode: outputMode,
                socketPath: socketPath,
                action: AgentAction.takeOverTask
            )
        default:
            throw AgentCLIParserError.unsupportedCommand(command)
        }
    }

    private static func parseControl(
        _ arguments: [String],
        outputMode inheritedOutputMode: AgentCLIOutputMode,
        socketPath inheritedSocketPath: String?,
        action: (String) -> AgentAction
    ) throws -> AgentCLIInvocation {
        var requestID: String?
        var outputMode = inheritedOutputMode
        var socketPath = inheritedSocketPath
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--request", "--request-id":
                requestID = try value(after: argument, in: arguments, index: &index)
            case "--json":
                outputMode = .json
            case "--text":
                outputMode = .text
            case "--socket":
                socketPath = try value(after: argument, in: arguments, index: &index)
            default:
                if argument.hasPrefix("--") {
                    throw AgentCLIParserError.unsupportedCommand(argument)
                }
                requestID = argument
            }
            index += 1
        }

        guard let requestID,
              requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            throw AgentCLIParserError.missingRequestID
        }
        return AgentCLIInvocation(
            request: AgentBridgeRequest(
                id: UUID().uuidString,
                actor: cliActor(),
                action: action(requestID)
            ),
            outputMode: outputMode,
            socketPath: socketPath
        )
    }

    private static func parseRun(
        _ arguments: [String],
        outputMode inheritedOutputMode: AgentCLIOutputMode,
        socketPath inheritedSocketPath: String?
    ) throws -> AgentCLIInvocation {
        var target: AgentTarget = .currentTerminal
        var command: String?
        var outputMode = inheritedOutputMode
        var socketPath = inheritedSocketPath
        var follow = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--target":
                let value = try value(after: argument, in: arguments, index: &index)
                if value == "current" {
                    target = .currentTerminal
                } else {
                    target = .runtimeID(value)
                }
            case "--runtime":
                target = .runtimeID(try value(after: argument, in: arguments, index: &index))
            case "--session":
                target = .sessionID(try value(after: argument, in: arguments, index: &index))
            case "--command":
                command = try value(after: argument, in: arguments, index: &index)
            case "--follow":
                follow = true
            case "--json":
                outputMode = .json
            case "--text":
                outputMode = .text
            case "--socket":
                socketPath = try value(after: argument, in: arguments, index: &index)
            case "--":
                let tail = arguments.dropFirst(index + 1)
                command = tail.joined(separator: " ")
                index = arguments.count
                continue
            default:
                if argument.hasPrefix("--") {
                    throw AgentCLIParserError.unsupportedCommand(argument)
                }
                command = arguments.dropFirst(index).joined(separator: " ")
                index = arguments.count
                continue
            }
            index += 1
        }

        guard let command, command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AgentCLIParserError.missingRunCommand
        }
        return AgentCLIInvocation(
            request: AgentBridgeRequest(
                id: UUID().uuidString,
                actor: cliActor(),
                action: .runCommand(
                    AgentRunCommandRequest(target: target, command: command, follow: follow)
                )
            ),
            outputMode: outputMode,
            socketPath: socketPath
        )
    }

    private static func parseSessionOptions(
        _ arguments: [String],
        inheritedOutputMode: AgentCLIOutputMode,
        inheritedSocketPath: String?
    ) throws -> (outputMode: AgentCLIOutputMode, socketPath: String?) {
        var outputMode = inheritedOutputMode
        var socketPath = inheritedSocketPath
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--json" {
                outputMode = .json
            } else if argument == "--text" {
                outputMode = .text
            } else if argument == "--socket" {
                socketPath = try value(after: argument, in: arguments, index: &index)
            }
            index += 1
        }
        return (outputMode, socketPath)
    }

    private static func value(after option: String, in arguments: [String], index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw AgentCLIParserError.missingValue(option)
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    private static func cliActor() -> AgentActor {
        AgentActor(
            kind: .externalCLI,
            name: ProcessInfo.processInfo.processName.isEmpty ? "stacio" : ProcessInfo.processInfo.processName,
            processID: ProcessInfo.processInfo.processIdentifier
        )
    }
}
