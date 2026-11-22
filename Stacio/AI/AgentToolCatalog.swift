import Foundation
import StacioAgentBridge

enum AgentToolCatalog {
 static let terminalCommand = "execute_terminal_command"
 static let configurationPrepare = "prepare_configuration_file"
 static let configurationWrite = "install_configuration_file"
 static let getTerminalOutput = "get_terminal_output"
 static let listTerminals = "list_terminals"

 struct Definition {
 var name: String
 var title: String
 }

 static let definitions: [Definition] = [
 Definition(name: configurationPrepare, title: "准备配置草稿"),
 Definition(name: configurationWrite, title: "写入配置文件"),
 Definition(name: terminalCommand, title: "执行命令"),
 Definition(name: getTerminalOutput, title: "读取终端输出"),
 Definition(name: listTerminals, title: "列出终端")
 ]

 static func definition(named name: String) -> Definition? {
 return definitions.first { $0.name == name }
 }

 static var toolSchemas: [[String: Any]] {
 return [
 [
 "type": "function",
 "function": [
 "name": terminalCommand,
 "description": "在已连接的终端会话中执行一条命令并返回输出与退出码。命令必须是非交互的：不要启动分页器、编辑器、REPL或持续日志。",
 "parameters": [
 "type": "object",
 "properties": [
 "command": ["type": "string", "description": "当前终端可直接输入的最简原生命令，不添加外层 shell 或状态标记"],
 "purpose_zh": ["type": "string", "description": "用一句简体中文准确说明这条实际命令会做什么。复合命令要包含主要操作和可能的修改，供用户审批前阅读。"],
 "terminal_id": ["type": "string", "description": "目标终端标识；省略时使用当前活动的终端"]
 ],
 "required": ["command", "purpose_zh"]
 ]
 ]
 ],
 [
 "type": "function",
 "function": [
 "name": configurationPrepare,
 "description": "在目标主机创建私有草稿并返回 source 和 expected_sha256。以这份草稿为基础编辑，首次创建时草稿为空。",
 "parameters": ["type": "object", "properties": ["path": ["type": "string"], "sudo": ["type": "boolean"], "purpose_zh": ["type": "string"], "terminal_id": ["type": "string"]], "required": ["path", "purpose_zh"]]
 ]
 ],
 [
 "type": "function",
 "function": [
 "name": configurationWrite,
 "description": "将目标主机上已准备的普通文件写入配置路径。已有配置先备份并验证，首次创建的新文件权限为 0600。恢复时用实际备份文件作为 source。",
 "parameters": ["type": "object", "properties": [
 "path": ["type": "string", "description": "配置文件绝对路径"],
 "expected_sha256": ["type": "string", "description": "准备草稿时返回的原始摘要或 absent"],
 "source": ["type": "string", "description": "目标主机上的暂存文件或恢复副本绝对路径"],
 "sudo": ["type": "boolean", "description": "执行是否需要 sudo"],
 "purpose_zh": ["type": "string"], "terminal_id": ["type": "string"]
 ], "required": ["path", "source", "expected_sha256", "purpose_zh"]]
 ]
 ],
 [
 "type": "function",
 "function": [
 "name": getTerminalOutput,
 "description": "读取终端最近输出的文本快照。",
 "parameters": [
 "type": "object",
 "properties": ["terminal_id": ["type": "string", "description": "目标终端标识"]]
 ]
 ]
 ],
 [
 "type": "function",
 "function": [
 "name": listTerminals,
 "description": "列出可用终端会话的标识、标题和当前目录。",
 "parameters": ["type": "object", "properties": [:]]
 ]
 ]
 ]
 }

 static func command(fromArguments raw: String) -> String? {
 guard let data = raw.data(using: .utf8) else { return nil }
 guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
 guard let command = object["command"] as? String else { return nil }
 let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
 return trimmed.isEmpty ? nil : command
 }

 static func terminalID(fromArguments raw: String) -> String? {
 guard let data = raw.data(using: .utf8) else { return nil }
 guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
 return object["terminal_id"] as? String
 }

 static func commandPurpose(fromArguments raw: String) -> String? {
     guard let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let purpose = object["purpose_zh"] as? String else { return nil }
     let singleLine = purpose.components(separatedBy: .controlCharacters).joined(separator: " ")
         .split(whereSeparator: \.isWhitespace).joined(separator: " ")
     guard !singleLine.isEmpty else { return nil }
     return singleLine.count <= 120 ? singleLine : String(singleLine.prefix(119)) + "…"
 }
}

/// Decides whether a tool call may run, must ask, or is refused.
enum AgentPermissionPolicy {
 /// Explain only the global constraints on the built-in assistant. A global
 /// policy never changes the permission saved on an existing conversation.
 static func globalConstraintDescription(preferences: AppSettings) -> String {
     if !preferences.aiAutoRunProposedCommands {
         return "自动审批/执行已关闭：内置助手每条命令都需确认，包括完全权限对话。"
     }
     switch preferences.agentConfirmationPolicy {
     case .requireEveryCommand:
         return "全局策略要求逐条确认，包括完全权限对话。"
     case .allowReadOnlyWithoutPrompt:
         return "保留的只读自动策略生效：内置助手的写入命令仍需确认。"
     case .allowLowRiskWithoutPrompt, .allowAllWithoutPrompt:
         return "内置助手按当前对话权限审批；更改全局策略不会切换对话权限。"
     }
 }

 enum Decision {
 case allow
 case deny(String)
 case ask(AgentApprovalRequest)
 }

 static func decide(
 invocation: AgentToolInvocation,
 mode: AgentPermissionMode,
 automation: SessionAutomationPolicy = .default,
 preferences: AppSettings = AppSettings()
 ) -> Decision {
 guard let command = invocation.command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
 return .deny("未提供终端命令")
 }
 func ask(_ reason: String, dangerous: Bool = false) -> Decision {
 .ask(AgentApprovalRequest(toolID: invocation.id, toolTitle: invocation.title, summary: command, reason: reason, isDangerous: dangerous))
 }
 let patterns = AgentCommandPatternPolicy(allowPatterns: preferences.agentCommandAllowPatterns, denyPatterns: preferences.agentCommandDenyPatterns)
 if patterns.matchedDenyPattern(for: command) != nil { return .deny("命令匹配设置中的禁止模式。") }
 switch automation.aiExecutionPolicy {
 case "disabled": return .deny("目标会话已禁用 AI 执行")
 case "commandCard": return .deny("目标会话只允许命令卡片")
 default: break
 }
 if AgentCommandSafetyPolicy.catastrophicReason(for: command) != nil {
 return ask("命令可能破坏根文件系统，必须人工确认。", dangerous: true)
 }
 let risk = AgentActionClassifier.risk(forCommand: command)
 if !preferences.aiAutoRunProposedCommands || preferences.agentConfirmationPolicy == .requireEveryCommand || mode == .supervised || automation.aiExecutionPolicy == "requireEveryCommand" {
 return ask("当前策略要求逐条审批。", dangerous: risk == .destructive)
 }
 if automation.environment == "production" {
 return ask("目标是生产环境，需人工确认。", dangerous: risk == .destructive)
 }
 if isReadOnly(command: command) { return .allow }
 if automation.aiExecutionPolicy == "readOnlyAuto" || preferences.agentConfirmationPolicy == .allowReadOnlyWithoutPrompt {
 return ask("目标会话仅允许自动执行只读命令。", dangerous: risk == .destructive)
 }
 if mode == .dangerFullAccess, risk != .destructive, isRoutineAdministration(command) { return .allow }
 if simpleWords(command) != nil, risk == .readOnly, patterns.matchedAllowPattern(for: command) != nil { return .allow }
 if let words = simpleWords(command), risk != .destructive {
 let operands = words.dropFirst().filter { !$0.hasPrefix("-") }
 if ["touch", "mkdir"].contains(words[0]), !operands.isEmpty,
 words.dropFirst().filter({ $0.hasPrefix("-") }).allSatisfy({ words[0] == "mkdir" && $0 == "-p" }),
 operands.allSatisfy({ $0.hasPrefix("/tmp/") && $0.count > 5 && !$0.split(separator: "/").contains("..") }) {
 return .allow
 }
 if mode == .dangerFullAccess, risk == .write,
 ["touch", "mkdir"].contains(words[0]), !operands.isEmpty,
 words.dropFirst().filter({ $0.hasPrefix("-") }).allSatisfy({ words[0] == "mkdir" && $0 == "-p" }),
 operands.allSatisfy({ !$0.hasPrefix("/") && $0 != "." && !$0.split(separator: "/").contains("..") }) {
 return .allow
 }

 }
 return ask("命令的影响超出自动审批范围。", dangerous: risk == .destructive)
 }

 /// Recognize routine administration by its complete argument list. Classifier
 /// risk alone cannot distinguish an unknown program from a network operation.
 private static func isRoutineAdministration(_ command: String) -> Bool {
     guard var words = simpleWords(command) else { return false }
     if words.first == "sudo" { words.removeFirst() }
     guard let program = words.first else { return false }
     let args = Array(words.dropFirst())
     func isName(_ value: String) -> Bool {
         value.range(of: #"\A[A-Za-z0-9][A-Za-z0-9_.@-]*\z"#, options: .regularExpression) != nil
     }
     switch program {
     case "apt", "apt-get":
         if args == ["update"] { return true }
         let operands = args.filter { $0 != "-y" && $0 != "--assume-yes" }
         return operands.count < args.count && operands.first == "install" && operands.count > 1 && operands.dropFirst().allSatisfy {
             isName($0) && !$0.hasSuffix("-")
         }
     case "systemctl":
         guard let action = args.first else { return false }
         let units = args.dropFirst()
         guard !units.isEmpty, units.allSatisfy(isName) else { return false }
         if ["status", "show", "cat", "is-active", "is-enabled"].contains(action) { return true }
         guard ["start", "restart", "reload", "enable"].contains(action) else { return false }
         return units.allSatisfy { unit in
             let name = unit.hasSuffix(".service") ? String(unit.dropLast(".service".count)) : unit
             return !name.isEmpty && (unit.hasSuffix(".service") || !name.contains(".")) && !name.hasPrefix("systemd-")
                 && !["reboot", "poweroff", "halt", "kexec", "shutdown", "suspend", "hibernate"].contains(name)
         }
     case "docker", "podman":
         if args == ["version"] || args == ["--version"] || args == ["info"] { return true }
         if args.first == "ps" { return args.dropFirst().allSatisfy { ["-a", "--all", "-q", "--quiet"].contains($0) } }
         return ["start", "restart", "inspect"].contains(args.first ?? "") && args.count > 1 && args.dropFirst().allSatisfy(isName)
     case "journalctl":
         var remaining = args[...]
         var hasUnit = false
         var noPager = false
         var hasLimit = false
         while let option = remaining.popFirst() {
             switch option {
             case "--no-pager": noPager = true
             case "-u", "--unit":
                 guard !hasUnit, let unit = remaining.popFirst(), isName(unit) else { return false }
                 hasUnit = true
             default:
                 if option.hasPrefix("--unit=") {
                     guard !hasUnit, isName(String(option.dropFirst(7))) else { return false }
                     hasUnit = true
                     continue
                 }
                 let value: String?
                 if option == "-n" || option == "--lines" { value = remaining.popFirst() }
                 else if option.hasPrefix("--lines=") { value = String(option.dropFirst(8)) }
                 else if option.hasPrefix("-n") { value = String(option.dropFirst(2)) }
                 else { return false }
                 guard !hasLimit, let value, value.allSatisfy({ $0.isASCII && $0.isNumber }),
                       let count = Int(value), (1...1000).contains(count) else { return false }
                 hasLimit = true
             }
         }
         return hasUnit && noPager && hasLimit
     case "ss":
         return args.allSatisfy { $0.first == "-" && $0.count > 1 && $0.dropFirst().allSatisfy("tunlpa46".contains) }
     case "sw_vers", "lsblk", "lscpu", "lsmem", "nproc", "hostnamectl", "timedatectl":
         return args.isEmpty
     case "git":
         return args == ["status"] || args == ["status", "--short"] || args == ["--version"]
     default:
         return false
     }
 }

 /// Parses literal arguments for the existing simple-command rules.
 private static func simpleWords(_ command: String) -> [String]? {
 let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:=,+-@ \t")
 guard command.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
 let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
 return words.isEmpty ? nil : words
 }

 static func isReadOnly(command: String) -> Bool {
 // Recognize complete diagnostic stages. Never classify the chain by its first program.
 let stages = command.components(separatedBy: "&&")
 if stages.count <= 8, stages.allSatisfy({ raw in
 let stage = raw.trimmingCharacters(in: .whitespaces)
 return ["cat /proc/loadavg", "uptime", "nproc", "echo '---'", "mpstat", "nproc --all"].contains(stage)
 || isBoundedTopSample(stage)
 || matchesStage(stage, pattern: #"mpstat[ \t]+-P[ \t]+ALL[ \t]+[1-5][ \t]+[1-5]"#)
 }) { return true }

 guard AgentActionClassifier.risk(forCommand: command) == .readOnly else { return false }
 let simple: Set<String> = ["ls", "pwd", "cat", "head", "tail", "wc", "grep", "cut", "sort", "uniq", "stat", "file", "df", "du", "free", "uptime", "uname", "whoami", "id", "date", "hostname", "ps", "pgrep", "lsof", "echo", "printf", "true"]
 return command.components(separatedBy: "|").allSatisfy { segment in
 guard let words = simpleWords(segment) else { return false }
 switch words[0] {
 case "date", "hostname": return words.count == 1
 case "sort": return !words.dropFirst().contains { $0.hasPrefix("-o") || $0.hasPrefix("--output") || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("o")) }
 case "systemctl": return words.count > 1 && ["status", "show", "is-active", "list-units"].contains(words[1])
 default: return simple.contains(words[0])
 }
 }
 }

 /// A bounded CPU sample can optionally pipe its output to a line limit.
 /// Each accepted filter reads stdin and prints lines without taking filenames.
 private static func isBoundedTopSample(_ command: String) -> Bool {
 let batch = #"top[ \t]+(?:-b[ \t]+-n|-bn)[ \t]*"#
 let iterations = #"(?:1(?:[ \t]+-d[ \t]*[1-5])?|[2-5][ \t]+-d[ \t]*[1-5])"#
 let width = #"(?:[ \t]+-w[ \t]*[1-9][0-9]{0,2})?"#
 let sed = #"sed[ \t]+-n[ \t]+'[1-9][0-9]{0,2}(?:,[1-9][0-9]{0,2})?p'"#
 let head = #"head[ \t]+(?:-n[ \t]*|--lines(?:=|[ \t]+))[1-9][0-9]{0,2}"#
 guard command.utf8.count <= 128 else { return false }
 let stages = command.components(separatedBy: "|")
 guard stages.count <= 2, matchesStage(stages[0], pattern: batch + iterations + width) else { return false }
 return stages.count == 1 || matchesStage(stages[1], pattern: "(?:" + head + "|" + sed + ")")
 }

 private static func matchesStage(_ stage: String, pattern: String) -> Bool {
 stage.range(of: #"\A[ \t]*"# + pattern + #"[ \t]*\z"#, options: .regularExpression) != nil
 }
}

enum AgentPrompt {
 static let systemPrompt = """
你是 Stacio内的运维助手，直接操作用户已连接的 SSH/终端会话。

规则：
1.需要读取或改变远程状态时，调用 execute_terminal_command；不要臆造命令输出。
2.命令必须是非交互的。禁止 less/more/man/vi/nano的交互模式、tail -f、journalctl -f、无参 REPL、无 -y的包安装、无 BatchMode的 ssh。
3.查询服务日志默认使用 journalctl -u 服务名 --no-pager -n 100。需要分页查看时用 cat、head、tail -n、sed -n或 --no-pager。
4.一次调用只做一件事。使用当前 Shell 可直接输入的最短命令，例如 Linux 上查看 CPU 占用可用 top -bn1 | head -n 20，一次取得负载、CPU 使用率和进程。仅有 uptime 时只报告负载，不能推算使用率。只在任务本身需要时使用管道、复合语句或子 Shell。不要为展示添加 echo 分隔符，也不要添加退出码检测、执行标记或 bash -c、sh -c、PowerShell -Command 外壳。需要连续判断时先取证据再决定下一步。
5.工具返回“退出状态未知”或“未确认”时，不要重复执行原命令，先查询进程或状态。
6.命令失败时先读输出。只有能明确修正参数时才尝试不同的命令，保留参数之间的空格。Linux 上使用 mpstat 取样的示例是 mpstat -P ALL 1 1。已有输出足以回答用户时直接总结。
7.沿用用户语言。简单任务直接调用所需工具，省略计划和逐步播报。完成后先给结果，只引用必要证据。工具要求确认时等待审批卡的结果。
8.不要声称执行了你没有通过工具执行的操作。
9.运维答复先给判断和支撑它的采样数据，只在有必要时给下一步。单次快照只能支持本次观测，不能据此断言长期健康或异常可以忽略。只在相关时提及内存、更新等旁项。
10.CPU 诊断分别说明实际执行占比、空闲和 I/O 等待。未取得核心数时不要推断单核。负载均值不能换算成 CPU 使用率。
11.重复查询当前状态时重新采样，只使用本轮结果作当前判断。用户要求对比时才引用历史数据，标明各次采样时间。
12.默认用分节报告回答 CPU 资源查询。先用一句话指出本次观测是否有 CPU 压力，再按“系统负载”“CPU 使用率”“主要进程”组织证据。解释各时间窗口的负载和用户态、内核态、等待、空闲占比与判断的关系。有进程数据时用表格列出可见的主要进程、PID、CPU% 和内存%，标明采样工具自身。内存与 Swap 已随快照取得时另列简短概况。最后说明采样范围和需要关注的现象。缺少数据时说明限制，不编造数值，不从累计 CPU 时间推断进程寿命，也不要从截断的进程列表推断所有进程的状态。用户指定格式时遵从用户要求。
13.写入或恢复系统、应用配置文件时，先调用 prepare_configuration_file，直接编辑其返回的无扩展名草稿，保留原始摘要，再调用 install_configuration_file，每次指定一个实际目标。收到 conflict 时停止旧写入并重新准备草稿，基于新内容重做修改。结束后清理本次返回的私有草稿。不得借脚本等方式绕过。按工具实际输出告知用户备份完整路径、对应的原文件和恢复步骤。备份失败即停止。新装应用沿用正常安装流程，首次创建配置无需事先备份；写入后验证配置，按应用需要确认新文件权限。
"""
}
