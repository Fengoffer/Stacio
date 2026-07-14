import Foundation
import StacioAgentBridge

#if canImport(Darwin)
import Darwin
#endif

let executableName = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "stacio"
if executableName == "stacio" {
    fputs("stacio is deprecated; use stacio instead.\n", stderr)
}

let arguments = Array(CommandLine.arguments.dropFirst())

do {
    let invocation = try AgentCLIParser.parseInvocation(arguments)
    let client = AgentBridgeSocketClient(
        socketPath: AgentBridgeSocketPath.resolve(explicitPath: invocation.socketPath)
    )
    var exitStatus = AgentCLITraceExitStatus()
    try client.send(request: invocation.request) { line in
        exitStatus.observe(socketLine: line)
        print(AgentCLIOutputRenderer.render(socketLine: line, mode: invocation.outputMode))
        #if canImport(Darwin)
        fflush(stdout)
        #endif
    }
    if exitStatus.exitCode != 0 {
        exit(exitStatus.exitCode)
    }
} catch {
    fputs("\(executableName): \(error.localizedDescription)\n", stderr)
    exit(2)
}
