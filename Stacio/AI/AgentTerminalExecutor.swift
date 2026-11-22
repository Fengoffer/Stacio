import Foundation

struct AgentExecutionResult {
 var output: String
 var exitCode: Int?
 var completion: AgentCompletionState
 var errorMessage: String?
 var wasCancelled: Bool
}

/// Executes a command inside an explicitly bound terminal session.
///
/// The executor never consults window focus: it resolves the frozen runtimeID and
/// connection generation through a resolver, writes through the pane's agent input
/// path, and observes shell completion separately from the command text.
/// A generation change, a timeout, or a disconnect all end as unconfirmed.
@MainActor
final class AgentTerminalExecutor {
 struct Target: Hashable {
 var runtimeID: String
 var connectionGeneration: UInt64
 var title: String
 }

 private final class Execution {
 let runtimeID: String
 let generation: UInt64
 let completionGeneration: UInt64
 let previousPrompt: String?
 let sentCommand: String
 let outputStart: Int
 var observedCompletionGeneration: UInt64
 var lastOutputPosition: Int
 let deadline: Date
 var timer: Timer?
 var settled = false
 var output = ""
		// The continuation is owned here rather than behind a callback: the
		// deadline can fire before a caller attaches anything, and a missing
		// hook used to swallow the resume and strand the turn forever.
		var continuation: CheckedContinuation<AgentExecutionResult, Never>?

 init(runtimeID: String, generation: UInt64, completionGeneration: UInt64, previousPrompt: String?, sentCommand: String, outputStart: Int, deadline: Date) {
 self.runtimeID = runtimeID
 self.generation = generation
 self.completionGeneration = completionGeneration
 self.observedCompletionGeneration = completionGeneration
 self.previousPrompt = previousPrompt
 self.sentCommand = sentCommand
 self.outputStart = outputStart
 self.lastOutputPosition = outputStart
 self.deadline = deadline
 }
 }

 let resolver: AgentTerminalResolving
 private var active: Execution?
 private struct PendingCommand {
     let generation: UInt64
     let completionGeneration: UInt64
     let outputStart: Int
     let prompt: String?
 }
 private var pending: [String: PendingCommand] = [:]

 var commandTimeout: TimeInterval=60
 var pollInterval: TimeInterval=0.10

 init(resolver: AgentTerminalResolving) {
 self.resolver = resolver
 }

 func execute(command: String, on target: Target, timeout: TimeInterval? = nil, onOutput: @escaping @MainActor (String) -> Void = { _ in }, onStart: @escaping @MainActor () -> Void) async -> AgentExecutionResult {
 guard let pane = try? resolver.resolveTerminalTarget(.runtimeID(target.runtimeID)) else {
 return AgentTerminalExecutor.failure("指定的终端 \(target.runtimeID)未找到或未登录")
 }
 guard pane.isAgentRuntimeConnected else {
 return AgentTerminalExecutor.failure("终端会话已断开，无法确认命令执行结果")
 }
 guard pane.agentRuntimeGeneration == target.connectionGeneration else {
 return AgentTerminalExecutor.failure("终端连接已更新，本次执行作废，未发送命令")
 }

 let commandText = command.replacingOccurrences(of: "\r\n", with: "\n")
 guard !commandText.unicodeScalars.contains(where: {
     CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
 }) else { return Self.failure("命令包含终端控制字符，未发送。") }
 let needsPaste = commandText.contains("\n") || commandText.contains("\t")
 guard !needsPaste || pane.agentBracketedPasteEnabled else {
     return Self.failure("当前终端不支持安全粘贴多行命令或制表符。请改用单行命令。")
 }
 pane.refreshAgentTerminalOutput()
 guard active == nil else { return Self.failure("终端正在执行命令，未发送新的输入。") }
 if let last = pending[target.runtimeID], last.generation == target.connectionGeneration {
     let tail = pane.agentOutput(since: last.outputStart, limit: 32 * 1024)
     let prompt = Self.trailingPrompt(tail, matching: last.prompt)
     guard Self.shellEnd(in: tail) != nil || (prompt != nil && (prompt == last.prompt || last.completionGeneration != pane.agentCommandCompletionGeneration)) else {
         return Self.failure("上一条命令尚未确认结束，未发送新的输入。请查看终端输出。")
     }
 }
 pending.removeValue(forKey: target.runtimeID)
 let waitBudget = timeout ?? commandTimeout
 guard waitBudget > 0 else { return Self.failure("已达到执行时限，未发送命令。") }
 let position = pane.agentOutputPosition
 let execution = Execution(
 runtimeID: target.runtimeID,
 generation: target.connectionGeneration,
 completionGeneration: pane.agentCommandCompletionGeneration,
 previousPrompt: Self.promptCandidate(pane.agentOutput(since: max(0, position - 4096), limit: 4096)),
 sentCommand: commandText,
 outputStart: position,
 deadline: waitBudget.isFinite ? Date().addingTimeInterval(waitBudget) : .distantFuture
 )
 active = execution
 onStart()

 let payload = needsPaste ? "\u{1B}[200~" + commandText + "\u{1B}[201~\r" : commandText + "\r"
 if pane.sendAgentInput(Array(payload.utf8)) == false {
 active = nil
 return AgentTerminalExecutor.failure("终端拒绝了本次输入（可能处于敏感输入保护或已断开）")
 }

		return await withCheckedContinuation { continuation in
			execution.continuation = continuation
			let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
				Task { @MainActor in
					self?.poll(execution, onOutput: onOutput)
				}
			}
			RunLoop.main.add(timer, forMode: .common)
			execution.timer = timer
			// The poll timer lives on the main run loop, so it cannot be relied on to
			// end the continuation by itself: a stalled main loop or a pane that stops
			// reporting would leave the turn running forever. This deadline runs off
			// the main queue and resumes the continuation directly.
			guard waitBudget.isFinite else { return }
			let wait = waitBudget + 2
			DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self, weak execution] in
				Task { @MainActor in
					guard let execution, execution.settled == false else { return }
					self?.settle(
						execution,
						output: execution.output,
						exitCode: nil,
						state: .unconfirmed,
						error: "等待命令输出超时，尚未确认命令结束。终端中的进程可能仍在运行，请先查询其状态，勿重复执行原命令。"
					)
					// Even without the executor, the waiter must be released.
					if execution.settled == false {
						execution.settled = true
						execution.timer?.invalidate()
						execution.timer = nil
						execution.continuation?.resume(returning: AgentTerminalExecutor.failure(
							"等待命令输出超时，尚未确认命令结束。"))
						execution.continuation = nil
					}
				}
			}
		}
 }

 private func poll(_ execution: Execution, onOutput: @MainActor (String) -> Void) {
 if execution.settled { return }
 guard let pane = try? resolver.resolveTerminalTarget(.runtimeID(execution.runtimeID)) else {
 settle(execution, output: execution.output, exitCode: nil, state: .unconfirmed, error: "终端会话已断开，无法确认命令执行结果")
 return
 }
 if pane.isAgentRuntimeConnected == false {
 settle(execution, output: execution.output, exitCode: nil, state: .unconfirmed, error: "终端会话已断开，无法确认命令执行结果")
 return
 }
 if pane.agentRuntimeGeneration != execution.generation {
 settle(execution, output: execution.output, exitCode: nil, state: .unconfirmed, error: "终端在命令执行期间重新连接，无法确认命令结果")
 return
 }

 pane.refreshAgentTerminalOutput()
 let position = pane.agentOutputPosition
 let generation = pane.agentCommandCompletionGeneration
 let shellPromptEvent = generation != execution.observedCompletionGeneration
 if position != execution.lastOutputPosition || shellPromptEvent {
 execution.lastOutputPosition = position
 execution.observedCompletionGeneration = generation
     let recent = pane.agentOutput(since: execution.outputStart, limit: 32 * 1024)
     let prompt = Self.trailingPrompt(recent, matching: execution.previousPrompt)
     let returnedPrompt = prompt != nil && (prompt == execution.previousPrompt || shellPromptEvent)
     let possibleShellEnd = recent.contains("\u{1B}]133;D")
     if possibleShellEnd || returnedPrompt {
         let retained = pane.agentOutput(since: execution.outputStart, limit: TranscriptRecorder.defaultMaximumByteCount)
         let end = possibleShellEnd ? Self.shellEnd(in: retained) : nil
         if end != nil || returnedPrompt {
             let output = Self.clean(end?.body ?? retained, command: end == nil ? execution.sentCommand : nil,
                                     trailingPrompt: end == nil ? prompt : nil)
             settle(execution, output: output, exitCode: end?.exitCode,
                    state: end?.exitCode == nil ? .unknown : .confirmed, error: nil)
             return
         }
     }
     let output = AgentTerminalExecutor.clean(recent, command: execution.sentCommand)
     if output != execution.output {
         execution.output = output
         onOutput(output)
     }
 }
 if Date() >= execution.deadline {
 settle(
 execution,
 output: execution.output,
 exitCode: nil,
 state: .unconfirmed,
 error: "等待命令输出超时，尚未确认命令结束。终端中的进程可能仍在运行，请先查询其状态，勿重复执行原命令。"
 )
 }
 }

 private func settle(_ execution: Execution, output: String, exitCode: Int?, state: AgentCompletionState, error: String?, wasCancelled: Bool = false) {
 // Idempotent: the deadline, the poll timer and cancelActive all race to end
 // the same execution, and only the first one may resume the waiter.
 guard execution.settled == false else { return }
 execution.settled = true
 execution.timer?.invalidate()
 execution.timer = nil
		if active === execution {
 self.active = nil
 if state == .unconfirmed {
     pending[execution.runtimeID] = PendingCommand(generation: execution.generation,
         completionGeneration: execution.completionGeneration, outputStart: execution.outputStart, prompt: execution.previousPrompt)
 }
 }
 let result = AgentExecutionResult(output: output, exitCode: exitCode, completion: state, errorMessage: error, wasCancelled: wasCancelled)
 execution.continuation?.resume(returning: result)
 execution.continuation = nil
 }

 static func failure(_ message: String) -> AgentExecutionResult {
 return AgentExecutionResult(output: "", exitCode: nil, completion: .unconfirmed, errorMessage: message, wasCancelled: false)
 }

 /// Cancels the active execution and sends Ctrl-C only to the terminal this task
 /// owns; other terminals are untouched.
 @discardableResult
 func cancelActive() -> Bool {
 guard let execution = active, execution.settled == false else { return false }
 let sentInterrupt: Bool
 if let pane = try? resolver.resolveTerminalTarget(.runtimeID(execution.runtimeID)),
    pane.isAgentRuntimeConnected,
    pane.agentRuntimeGeneration == execution.generation {
 sentInterrupt = pane.sendAgentInput([0x03])
 } else {
 sentInterrupt = false
 }
 let message = sentInterrupt ? "已发送中断信号" : "未能向终端发送中断信号，命令可能仍在运行。"
 settle(execution, output: execution.output, exitCode: nil, state: .unconfirmed, error: message, wasCancelled: true)
 return sentInterrupt
 }

 var hasActiveExecution: Bool { return active?.settled == false }

 struct CompletionStatus {
 var body: String
 var exitCode: Int?
 }

 private static let shellEventPattern = try! NSRegularExpression(
     pattern: #"\x1b\]133;([CD])(?:;([0-9]{1,3}))?(?:\x07|\x1b\\)"#)

 /// A prompt alone confirms neither an exit code nor success.
 private static func shellEnd(in text: String) -> CompletionStatus? {
     var outputStart: String.Index?
     for match in shellEventPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
         guard let kind = Range(match.range(at: 1), in: text),
               let event = Range(match.range, in: text) else { continue }
         if text[kind] == "C" { outputStart = event.upperBound; continue }
         guard let outputStart else { continue }
         let code = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) }
         return CompletionStatus(body: String(text[outputStart..<event.lowerBound]), exitCode: code)
     }
     return nil
 }

 private static func promptCandidate(_ text: String) -> String? {
     let visible = stripANSI(text)
     guard visible.last?.isNewline == false,
           let last = visible.split(whereSeparator: \.isNewline).last?.trimmingCharacters(in: .whitespaces) else {
         return nil
     }
     guard last.range(of: #"^\d+(?:\.\d+)?%$"#, options: .regularExpression) == nil else { return nil }
     guard !last.isEmpty, last.utf8.count <= 1024 else { return nil }
     return last
 }

 private static func trailingPrompt(_ text: String, matching previous: String?) -> String? {
     guard let last = promptCandidate(text) else { return nil }
     if last == previous { return last }
     let unix = #"^(?:[^\s@]+@[^\s@]+[: ][^\r\n]*|[\w.-]+[ ]?)?[#$%]$"#
     let windows = #"^(?:[^\s]+[ ]+)?(?:PS[ ]+)?[A-Za-z]:\\[^\r\n]*>$"#
     let device = #"^[A-Za-z0-9._-]+(?:\([^\r\n]*\))?[#>]$"#
     let bracketed = #"^\[[^\s@]+@[^\s]+\s+[^\]]+\][#$]$"#
     return last.range(of: device, options: .regularExpression) != nil || last.range(of: bracketed, options: .regularExpression) != nil || last.range(of: unix, options: .regularExpression) != nil
         || last.range(of: windows, options: .regularExpression) != nil ? last : nil
 }

 /// Drop the initial input echo only; an identical line later may be real output.
 static func clean(_ text: String, command: String?, trailingPrompt: String? = nil) -> String {
 var value = AgentTerminalExecutor.stripANSI(text)
 value = value.replacingOccurrences(of: "\r\n", with: "\n")
 value = value.replacingOccurrences(of: "\r", with: "\n")
 var lines = ArraySlice(value.components(separatedBy: "\n"))
 while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
 if let echo = command?.components(separatedBy: "\n"), lines.starts(with: echo) {
     lines.removeFirst(echo.count)
 }
 while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
 if let trailingPrompt, lines.last?.trimmingCharacters(in: .whitespaces) == trailingPrompt { lines.removeLast() }
 return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
 }

 static func stripANSI(_ text: String) -> String {
 var output = ""
 output.reserveCapacity(text.count)
 let scalars = Array(text.unicodeScalars)
 var index=0
 while index < scalars.count {
 let scalar = scalars[index]
 if scalar == "\u{1B}" {
 index += 1
 if index >= scalars.count { break }
 if scalars[index] == "[" {
 index += 1
 while index < scalars.count {
 let value = scalars[index].value
 index += 1
 if value >= 0x40, value <= 0x7E { break }
 }
 continue
 }
 if scalars[index] == "]" {
 index += 1
 while index < scalars.count {
 let value = scalars[index].value
 if value == 0x07 {
 index += 1
 break
 }
 if value == 0x1B {
 if index + 1 < scalars.count, scalars[index + 1] == "\\" {
 index += 2
 break
 }
 }
 index += 1
 }
 continue
 }
 continue
 }
 if scalar.value == 0x07 {
 index += 1
 continue
 }
 output.unicodeScalars.append(scalar)
 index += 1
 }
 return output
 }
}
