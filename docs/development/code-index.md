# Stacio 代码索引文档

版本：v0.5
日期：2026-07-31
状态：BLE Console v1、macOS CoreBluetooth adapter、保存会话路由、Windows BLE-first contract 与 Remote Text Editor UI 稳定性基线已进入实现

## 1. 顶层目录

| 路径 | 责任 |
| --- | --- |
| `Package.swift` | SwiftPM 工程入口；`StacioApp` 显式链接 `IOKit` 和 `CoreBluetooth`，后续发布阶段可再引入 Xcode archive 配置。 |
| `Stacio.xcodeproj/` | 后续发布、签名和公证阶段的 Xcode 工程或生成配置。 |
| `Stacio/` | Swift/AppKit macOS app。 |
| `StacioCore/` | Rust Core library。 |
| `docs/` | 产品、设计、架构、开发、排障文档。 |
| `tests/fixtures/` | SSH、SCP/Files、导入测试样例。 |
| `scripts/` | 构建、签名、公证、诊断脚本；本地打包入口见 `scripts/package-app.sh`，会生成含蓝牙用途说明的 `Info.plist`，把 `stacio` CLI helper 打入 `Contents/Helpers/stacio`，把 VNC bundled adapter 打入 `Contents/Adapters/vnc`；非 GUI bundle smoke 见 `scripts/smoke-local-app.sh`，可选 GUI 启动窗口 smoke 见 `scripts/smoke-launch-window.sh`，核心本地门禁见 `scripts/accept-core-feature.sh --run-local`。 |

## 2. Swift App 索引

| 路径 | 责任 |
| --- | --- |
| `Stacio/App/StacioApplication.swift` | app 入口和 lifecycle。 |
| `Stacio/App/AppDelegate.swift` | menu、window restoration、app events。 |
| `Stacio/App/StacioPaths.swift` | macOS Application Support 路径、`Stacio.sqlite` 数据库 URL 和 Agent Bridge socket 路径创建。 |
| `Stacio/Windows/WorkbenchWindowController.swift` | 主窗口和三栏 split view；`openSavedSession` 区分 SSH、SCP、SFTP、Telnet、Serial、Console、Shell、Browser、File 和 VNC，FTP 明确拒绝并引导 SFTP；Console 读取并校验 `config_json`、要求当前 macOS peripheral binding、调用独立 `ConsoleSessionStarting`，从不进入 Serial starter；成功启动后 best-effort 标记 `last_opened_at`。 |
| `Stacio/Views/Sidebar/SessionSidebarViewController.swift` | 会话 source-list、搜索、Quick Connect、导入入口、saved session New/Edit/Delete、folder/session 渲染和 session open callback；Console 使用原生 `antenna.radiowaves.left.and.right` symbol，Serial 保持 `cable.connector`。 |
| `Stacio/Views/Sidebar/SessionSidebarStore.swift` | `SessionSidebarStoring` 与 CoreBridge-backed SQLite session/folder list/create/update/delete adapter。 |
| `Stacio/Views/Sidebar/SessionSidebarSessionManagement.swift` | AppKit 原生 saved session editor、auth mode 表单、draft factory 和删除确认；包含独立 Console form mode，使用只读 BLE endpoint、固定隐藏端口 `0`、无 credential 字段，并与 Serial 设备发现保持隔离。 |
| `Stacio/Views/Sidebar/SessionSidebarCredentialSaving.swift` | Sidebar credential 保存边界；先写 Rust/SQLite credential metadata，再用 `KeychainCredentialStore` 写入 Stacio 本地凭据库，返回 `CredentialRecord.id` 给 session；凭据库写失败时 best-effort 删除 metadata。 |
| `Stacio/Views/Workspace/TerminalWorkspaceController.swift` | terminal tabs、split panes。 |
| `Stacio/Views/Workspace/WorkspaceViewController.swift` | 本地 shell、远程 SSH/Telnet/Serial/Console terminal、SCP/SFTP 文件、Browser、Local File 和 VNC tabs hosting；Console pane 复用终端输入、Macro、Agent 和 MultiExec，保持 Files、Tunnels、device dashboard、SSH upload-drop 与 remote OS probe 禁用。 |
| `Stacio/Views/Dialogs/SessionSettingsViewController.swift` | 新建/编辑 saved session 设置；Console 模式嵌入 BLE editor，只有扫描并确认 device/profile 后新会话才可保存；持久化 `protocol=console`、可读 endpoint、`port=0` 和经过 Core 序列化的 Console v1 config，不写 SSH automation。 |
| `Stacio/Views/Terminal/TerminalView.swift` | 原生 terminal NSView hosting。 |
| `Stacio/Views/Inspector/InspectorViewController.swift` | Files、Transfers、Tunnels、Logs、AI tabs；Files/Tunnels 共享当前 live SSH session context；Transfers tab 创建 persistent `TransferQueueCoordinator` 并恢复历史；Tunnels tab 注入 CoreBridge-backed profile store；文件编辑器 toolbar 的 AI 按钮会切到右侧 AI 面板并填入当前远程文本文件问题。 |
| `Stacio/Views/Files/FilesViewController.swift` | 远程文件面板；托管内嵌 Remote Edit editor，并把编辑器生成的 AI 文件上下文问题向 Inspector 转发。 |
| `Stacio/Views/Files/RemoteFilesPaneViewController.swift` | Workspace 内的 SCP/FTP saved-session 文件 pane；持有 `FilesCoordinator`，SCP 打开时用当前 SSH context 加载远端目录，FTP 打开时用 `FTPLiveSessionContext` 显示内置 FTP engine label；Workspace 内嵌编辑器同样转发 AI 文件问题。 |
| `Stacio/Views/Transfers/TransferQueueViewController.swift` | 传输队列。 |
| `Stacio/Views/Tunnels/TunnelsViewController.swift` | tunnel profile 表格、Add/Edit/Delete 管理按钮和 Start/Stop 状态控制；通过 `TunnelRuntimeBridging` 调用 CoreBridge tunnel runtime，不调用本机 `ssh`；`TunnelLiveSessionContext` 携带 SSH config、resolved secret 和 trusted fingerprint。 |
| `Stacio/Views/Tunnels/TunnelProfileManagement.swift` | `TunnelProfileStoring`、CoreBridge-backed SQLite store、AppKit 原生 profile editor 和删除确认；profile 管理只保存 `TunnelProfile`，不保存 secret 或系统命令。 |
| `Stacio/Views/Dialogs/` | host key、危险操作、导入预览 sheets。 |
| `Stacio/Services/FilesCoordinator.swift` | Swift Files coordinator；调用 remote listing bridge 并更新 `FilesViewController`，可通过当前 `TunnelLiveSessionContext` 加载 SCP/SSH remote directory，也可通过 `FTPLiveSessionContext` 加载 FTP directory；SCP 上传/下载进入 SCP queue，FTP 上传/下载进入内置 FTP queue，目录浏览、新建、重命名、删除走内置 FTP control channel；Remote Edit 本地副本丢失时阻止上传并显示重新打开远程文件的恢复提示；FTP Remote Edit 通过内置 FTP 队列下载缓存副本并保存回原远端路径。 |
| `Stacio/Services/RemoteEditCache.swift` | Remote Edit 本地缓存；按 runtime/session/remote path 隔离缓存文件，生成回传原路径的 SCP upload job，检测本地副本是否晚于远端 modifiedAt，批量列出全部或指定 runtime/session 的已变化本地副本；同一路径重新打开时只保留当前 tracked item，并在缓存路径逃逸或本地副本丢失时抛 typed error。 |
| `Stacio/Views/Files/RemoteTextEditorViewController.swift` | Monaco-backed Remote Edit 文本编辑器；以 Swift 文档状态为 source of truth，使用 page generation、`ready -> workspaceReady` 两阶段握手、原生加载遮罩、有限自动恢复和合并布局处理 WebKit/Monaco 生命周期；跟随终端主题/字体设置，维护多文档 dirty 状态，并可把当前文件名、远端路径、语言和 12,000 字符以内内容摘要发送给右侧 AI 助手；该入口只生成问题，不直接修改远端文件。 |
| `Stacio/Services/QuickConnectCoordinator.swift` | Quick Connect 编排：调用 Rust parser，将目标转换为 agent-auth `SshConnectionConfig`，再进入 Workbench 远程 SSH session starter。 |
| `Stacio/Services/RemoteSSHSessionCoordinator.swift` | 远程 SSH 会话启动编排：构建受信任 `TunnelLiveSessionContext`、启动 embedded live shell runtime、写入 `TunnelLiveSessionStore`、打开 Workspace 远程终端 pane。 |
| `Stacio/Services/TelnetSessionCoordinator.swift` | 远程 Telnet 会话启动编排：调用 Rust embedded Telnet runtime，打开 Workspace 远程终端 pane，不调用系统 `telnet`。 |
| `Stacio/Services/SerialSessionCoordinator.swift` | 远程串口会话启动编排：调用 Rust embedded Serial runtime，打开 Workspace 远程终端 pane，不调用系统 `screen`、`cu` 或 `minicom`。 |
| `Stacio/Services/BLEConsoleModels.swift` | BLE RSSI、设备识别、NBEE 置顶排序、扫描快照去重/节流/淘汰和稳定错误码。 |
| `Stacio/Services/BLEConsoleCentral.swift` | CoreBluetooth adapter；无 service filter 扫描、重复 advertisement 合并、10 秒超时、精确 peripheral retrieval、GATT 操作与 generation 透传。 |
| `Stacio/Services/BLEConsoleSession.swift` | BLE Console 连接状态机；profile 解析、RX 订阅、TX MTU 分块与背压、字节保序、有限重连、stale generation 过滤和幂等 close。 |
| `Stacio/Services/ConsoleSessionCoordinator.swift` | 把 BLE session 接到外部 terminal runtime 和 `RemoteTerminalPaneViewController`；RX 写入现有 terminal buffer，pane input 进入 BLE TX，不调用 Serial runtime。 |
| `Stacio/Services/WorkspaceCapabilityPolicy.swift` | 按 session protocol 冻结 Workspace 能力；Console 只允许 AI 和 diagnostics，拒绝 Files、Tunnels、device dashboard 和 browser。 |
| `Stacio/Views/Dialogs/BLEConsoleScannerViewController.swift` | AppKit 扫描/绑定 sheet；显示名称、信号强度、识别状态，NBEE 高亮置顶但要求用户明确选择。 |
| `Stacio/Views/Dialogs/BLEConsoleCharacteristicMapperViewController.swift` | 未匹配内置 BTerm profile 时选择 service、TX、RX 和 write type，并阻止无效 characteristic 组合。 |
| `Stacio/Views/Dialogs/BLEConsoleSessionEditorView.swift` | Session Settings 内的当前 BLE binding/profile 摘要和扫描/重新绑定入口。 |
| `Stacio/Views/Workspace/SessionTabIconDescriptor.swift` | SSH、Console、图形和 OS tab icon descriptor；Console 使用原生天线 SF Symbol。 |
| `Stacio/Services/TransferQueueCoordinator.swift` | Swift transfer queue coordinator；维护 transfer job/progress 内存状态，调度后台 live SCP/FTP bridge，写入 transfer history，处理 cancel/retry UI action 并更新 `TransferQueueViewController`。 |
| `Stacio/Services/RuntimeDiagnosticFormatter.swift` | Swift UI 侧运行时诊断归一化；把常见英文错误转为中文，并统一 credential/path 脱敏，供 Terminal、Transfers、Tunnels 和 Files/Remote Edit 错误展示使用。 |
| `Stacio/Services/AgentExecutionCoordinator.swift` | AI/Agent 可见终端执行协调器；把已授权命令写入现有 terminal pane，并同步发出 queued/approval/typing/running trace 给终端 overlay 和 Agent Bridge；request id 是任务历史、terminal trace 和 AI/Agent 审计的关联键。 |
| `Stacio/Services/AgentActionAuthorizer.swift` | AI/Agent 风险分类、确认和脱敏授权边界。 |
| `Stacio/Services/AgentBridgeServer.swift` | 本地 Unix socket Agent Bridge server；外部 `stacio` CLI/Codex 请求经此进入 app-owned terminal 执行链路，并逐行 streaming trace 到 CLI。 |
| `StacioAgentBridge/AgentActionClassifier.swift` | Agent Bridge 命令风险分类；按 shell token 识别 docker/kubectl/systemd/package/git、Terraform/OpenTofu、Ansible、进程管理、数据库客户端、云 CLI、远程复制和 SSH 嵌套命令等运维命令，覆盖 kubectl 修改/会话类命令，支持 `sh -c`/`bash -lc` shell wrapper 内部脚本风险，并避免 quoted 诊断文本触发误报。 |
| `Stacio/Services/AIAssistantProvider.swift` | 内置 AI 助手 provider contract 和本地规则 fallback；磁盘、Docker 容器、系统负载/CPU/内存类问题会返回只读分步诊断命令。 |
| `Stacio/Services/OpenAICompatibleAIAssistantProvider.swift` | OpenAI-compatible chat/model catalog provider；支持本地/私有 endpoint、`/models` 列表刷新、reasoning effort 和可读错误归一化。 |
| `Stacio/Services/AIAssistantCoordinator.swift` | 内置 AI 助手编排；提问时裁剪 terminal context，执行建议命令时复用 AgentExecutionCoordinator，并可复用既有 task request id，让任务历史、terminal trace 和审计记录对齐。 |
| `Stacio/Views/AI/AIAssistantPanelViewController.swift` | AI 助手 AppKit 面板；展示建议命令、记录任务历史，并把执行交给可见 terminal 链路；用户从建议命令执行时沿用该任务 request id，便于从历史任务打开对应 trace/审计。 |
| `Stacio/Views/Terminal/TerminalCommandHighlighter.swift` | 终端/AI 命令文本增强高亮；复用 Agent 风险分类结果，对 docker/kubectl/systemd/package/git、IaC、配置管理、进程管理、数据库、云 CLI、远程复制和 shell-wrapped 命令显示 command/subcommand/flag/path token，不改写真实终端输出。 |
| `Stacio/Services/CredentialCenterStore.swift` | 设置页凭据中心 adapter；只通过 CoreBridge list/delete credential metadata，不读取或展示凭据库 secret。 |
| `Stacio/ViewModels/` | UI state 和 CoreBridge command 调用。 |
| `Stacio/Bridge/CoreBridge.swift` | UniFFI bridge facade；包含 Session CRUD/Import、Console v1 parse/serialize/profile/policy、SSH、Telnet、Serial、Files/SCP/SFTP、Tunnel 和 Diagnostics 等 Swift 调用入口。 |
| `Stacio/Bridge/Generated/Sources/` | UniFFI 生成的 Swift binding source，作为 `StacioCoreBindings` SwiftPM target。 |
| `Stacio/Bridge/Generated/Headers/` | UniFFI 生成的 C header 和 modulemap，C module 名为 `stacio_coreFFI`。 |

## 3. Rust Core 索引

| 路径 | 责任 |
| --- | --- |
| `StacioCore/src/lib.rs` | Rust library 与 UniFFI exports；包含 Console v1 contract API、external terminal runtime、live SSH/Telnet/Serial shell、SCP/SFTP/FTP 和其他 Core bridge。 |
| `StacioCore/uniffi-bindgen-swift.rs` | UniFFI Swift binding 生成入口。 |
| `StacioCore/src/domain/files.rs` | Remote Files entry DTO、SSH exec TSV parser、FTP LIST parser、unsafe path rejection。 |
| `StacioCore/src/domain/ftp.rs` | FTP connection config、auth secret DTO、invalid config 校验和 no-secret/no-system-command tests。 |
| `StacioCore/src/domain/graphics.rs` | X11/VNC diagnostics 和 adapter config tests。 |
| `StacioCore/src/domain/macro_recording.rs` | Macro recording/step DTO 和输入脱敏。 |
| `StacioCore/src/domain/multiexec.rs` | MultiExec target/plan/error 和生产环境保护规则。 |
| `StacioCore/src/domain/session.rs` | Quick Connect 解析、会话/文件夹 DTO、`SessionRecord.last_opened_at` 和 SessionError。 |
| `StacioCore/src/domain/scp.rs` | SCP transfer job/progress、方向、冲突策略和 typed transfer errors。 |
| `StacioCore/src/domain/serial.rs` | Serial connection config、device path/baud rate 校验和 no-secret/no-system-command tests。 |
| `StacioCore/src/domain/console.rs` | 版本化 Console v1 DTO、Bluetooth UUID 规范化、两套 BTerm profile、custom profile、稳定配置错误和 macOS/Windows transport policy；macOS 永远 BLE-only，Windows 只有 exact COM binding 才允许 BLE-then-SPP。 |
| `StacioCore/src/domain/ssh.rs` | SSH config、auth method、host key fingerprint/verification、`LiveSshHostKey`、`SshAuthSecret`、runtime errors 和诊断脱敏。 |
| `StacioCore/src/domain/telnet.rs` | Telnet connection config 和基础校验；不包含 password/secret 字段。 |
| `StacioCore/src/domain/terminal.rs` | Terminal runtime DTOs 和 UniFFI error type。 |
| `StacioCore/src/domain/tunnel.rs` | Tunnel profile、kind、state、error code 和状态转换。 |
| `StacioCore/src/domain/diagnostics.rs` | Diagnostic bundle/entry/severity DTO 和日志脱敏。 |
| `StacioCore/src/domain/agent.rs` | Agent action audit event DTO。 |
| `StacioCore/src/services/agent_service.rs` | Agent action audit event 基础校验。 |
| `StacioCore/src/services/session_service.rs` | 后续会话搜索、批量编辑和业务编排入口。 |
| `StacioCore/src/services/scp_service.rs` | Embedded SCP engine contract、mock transfer progress、permission/interrupted error mapping、live SCP job-id cancellation registry 和 progress event registry。 |
| `StacioCore/src/services/ssh_service.rs` | SSH transport contract、mock transport execution path 和 connection status mapping。 |
| `StacioCore/src/services/terminal_service.rs` | Terminal runtime registry、bounded input/output queues、resize revision 和 close state。 |
| `StacioCore/src/services/live_shell_service.rs` | Live SSH shell worker contract、fake channel tests、status DTO 和 terminal queue polling。 |
| `StacioCore/src/services/telnet_service.rs` | Telnet IAC 协商过滤、WILL/DO 拒绝响应和 no-secret/no-system-command tests。 |
| `StacioCore/src/services/tunnel_service.rs` | Embedded tunnel channel contract、mock start/stop 和错误映射。 |
| `StacioCore/src/services/diagnostics_service.rs` | Diagnostic bundle builder 和 entry redaction。 |
| `StacioCore/src/services/graphics_service.rs` | X11 forwarding args、DISPLAY/xauth diagnostics、VNC packaged adapter launch config。 |
| `StacioCore/src/services/device_metrics_service.rs` | Linux 设备看板采集解析；解析 `/proc`、`df` 和 mount 信息，覆盖 CentOS/RHEL、Ubuntu/Debian 新旧内核、Alpine/BusyBox、overlay/LVM/nvme，并过滤 snap loop、squashfs、nsfs、tmpfs、NFS/CIFS/SSHFS 等非本机业务磁盘，同时保留非 snap 的 loop-backed 数据盘。 |
| `StacioCore/src/services/files_service.rs` | Files 面板、SCP 传输、SSH exec 文件操作。 |
| `StacioCore/src/services/tunnel_service.rs` | tunnel lifecycle。 |
| `StacioCore/src/services/import_service.rs` | CSV 和 MobaXterm INI-like 导入预览、冲突检测、secret 字段忽略。 |
| `StacioCore/src/services/macro_service.rs` | Macro JSON serialization、playback ordering 和 secret redaction。 |
| `StacioCore/src/services/multiexec_service.rs` | Broadcast audit event、target count、input redaction 和 no-execute preparation。 |
| `StacioCore/src/services/diagnostics_service.rs` | 诊断包和脱敏。 |
| `StacioCore/src/infrastructure/ssh/` | 内置 SSH transport adapters；当前包含 mock transport contract、libssh2 live TCP/handshake/auth/host key adapter，不调用本机 `ssh`。 |
| `StacioCore/src/infrastructure/telnet.rs` | 内置 Telnet TCP channel；非阻塞 socket、IAC 协商过滤和 readiness wait interest，不调用本机 `telnet`。 |
| `StacioCore/src/infrastructure/serial.rs` | 内置 Serial channel；直接打开 macOS device fd、termios raw mode、非阻塞读写和 readiness wait interest，不调用本机串口工具。 |
| `StacioCore/src/infrastructure/files/` | 内置 remote files adapters；当前包含 libssh2 SSH exec directory listing adapter 和 FTP control/list/retrieve/store adapter，不调用本机 `sftp/scp/rsync/ftp`。 |
| `StacioCore/src/infrastructure/scp/` | 内置 SCP adapter 入口；当前包含 deterministic mock engine 和 libssh2 live SCP upload/download，不调用本机 `scp/sftp/rsync`。 |
| `StacioCore/src/infrastructure/tunnel/` | 内置 SSH tunnel channel 入口；包含 deterministic mock channel、libssh2 local direct-tcpip、remote forward listener、dynamic SOCKS 和 copy pump，不调用本机 `ssh`。 |
| `StacioCore/src/infrastructure/db.rs` | SQLite connection pragmas 和 migration bootstrap。 |
| `StacioCore/src/infrastructure/agent_audit_repository.rs` | `agent_action_events` SQLite record/list repository，保存脱敏 AI/Agent 操作事件。 |
| `StacioCore/src/infrastructure/session_repository.rs` | folders/sessions SQLite CRUD、最近连接和 no-secret export；Console 强制 `port=0`，以经过 Core 校验/规范化的完整 `config_json` 作为 source of truth，并在 duplicate/export 时保留。 |
| `StacioCore/src/infrastructure/credential_repository.rs` | SQLite `credentials` metadata repository；只保存 kind、label、keychain service/account，不保存 secret。 |
| `StacioCore/src/infrastructure/known_host_repository.rs` | SQLite `known_hosts` upsert/find/list 持久化，按 host/port 保存 SHA-256 fingerprint。 |
| `StacioCore/src/infrastructure/tunnel_repository.rs` | SQLite `tunnels` upsert/list/delete 持久化，保存 local/remote/dynamic `TunnelProfile`，不存命令字符串或 secret。 |
| `StacioCore/src/infrastructure/transfer_repository.rs` | SQLite `transfer_jobs`/`transfer_events` upsert/list 持久化，恢复 SCP job 和 progress history。 |
| `Stacio/Security/KeychainCredentialStore.swift` | Stacio 本地凭据库 facade；默认使用 `StacioFileCredentialBackend` 写入 Application Support 下的 AES-GCM vault，测试可用内存 backend，credential debug 脱敏。 |
| `Stacio/Security/SSHCredentialResolver.swift` | 根据 `SshConnectionConfig` 解析 credential ref，生成短生命周期 SSH secret。 |
| `Stacio/Security/FTPCredentialResolver.swift` | 根据 FTP saved session 的 username/credential id 从 Stacio 凭据库解析短生命周期 FTP password；anonymous 用户不读取凭据库，描述不暴露 secret。 |
| `Stacio/Security/SSHConnectionCoordinator.swift` | Swift live SSH 编排：probe host key、known_hosts 决策、credential resolver、auth 前 expected fingerprint connect；成功连接后可写入 `TunnelLiveSessionStore` 供隧道复用。 |
| `Stacio/Security/TunnelLiveSessionStore.swift` | 进程内当前 live SSH session context store；用 `NSLock` 保护替换/读取/清理，描述输出只包含 host/port/username/auth type/fingerprint，不暴露 secret。 |
| `Stacio/Security/SshAuthSecret+Redaction.swift` | Swift 侧 `SshAuthSecret` 描述脱敏，避免 UniFFI enum 默认打印关联 secret。 |
| `Stacio/Views/Security/HostKeyConfirmationPresenter.swift` | AppKit `NSAlert` host key confirmation sheet 配置；首次确认和 changed key 使用不同严重级别与按钮。 |
| `Stacio/Views/Security/HostKeyConfirmationPresenter.swift` | `AppKitHostKeyConfirmer` 生产实现；在主线程显示 host key sheet 并返回 Core trust decision。 |
| `Stacio/Views/Dialogs/QuickConnectPromptPresenter.swift` | AppKit Quick Connect prompt；Toolbar 和 Sidebar 共用，输入为空或取消时不启动会话。 |
| `StacioCore/src/infrastructure/runtime/` | Tokio runtime、blocking worker、bounded queues。 |
| `StacioCore/src/telemetry/` | OSLog/file logging、redaction、trace id。 |
| `StacioCore/migrations/` | SQLite migrations。 |

## 4. 数据库索引

详见 [SQLite Schema 详细设计](../data/sqlite-schema-design.md)。

| 表 | Repository |
| --- | --- |
| `sessions`、`folders` | `SessionRepository` |
| `credentials` | `CredentialRepository` |
| `terminal_profiles` | `TerminalProfileRepository` |
| `tunnels` | `TunnelRepository` |
| `transfer_jobs`、`transfer_events` | `TransferRepository` |
| `import_reports` | `ImportReportRepository` |
| `audit_events` | `AuditRepository` |
| `agent_action_events` | `AgentActionAuditRepository` |
| `known_hosts` | `KnownHostRepository` |
| `settings` | `SettingsRepository` |

## 5. 快速定位入口

| 问题 | 先看 |
| --- | --- |
| 主窗口打不开 | `WorkbenchWindowController.swift`、app logs。 |
| 打包后无法打开或 bundle 结构异常 | [本地安装测试与打包 Smoke 指南](./install-smoke-test.md) -> `scripts/package-app.sh` -> `scripts/smoke-local-app.sh` -> [本地交付诊断说明](../release/local-delivery-diagnostics.md)。 |
| 会话树空白 | `SessionSidebarViewController.swift` -> `session_service.rs` -> `SessionRepository`。 |
| SSH 连接失败 | `Stacio/Security/SSHConnectionCoordinator.swift` -> `StacioCore/src/lib.rs` live SSH exports -> `infrastructure/ssh/` -> diagnostics。 |
| 终端黑屏 | `TerminalView.swift` -> shell channel events。 |
| Files 不显示 | `files_service.rs` -> `infrastructure/ssh/` -> remote capability check。 |
| Remote Edit 打开黑屏、长时间加载或拖一下 Files 分栏才显示 | [Remote Text Editor 与 Files UI 稳定性 Runbook](./remote-text-editor-ui-runbook.md) -> `RemoteTextEditorViewController.loadMonacoEditorHTML` / `handleScriptMessage` / `scheduleEditorLayoutIfNeeded`。先区分 workspace readiness 与 layout，不要先改 SSH/下载链路。 |
| Remote Edit 在窗口 resize、折叠恢复或离屏重挂后空白 | [Remote Text Editor 与 Files UI 稳定性 Runbook](./remote-text-editor-ui-runbook.md) -> `editorLiveResizeDidStart/End` -> `editorDidMoveToWindow` -> `FilesViewController.restoreEmbeddedCapability()`。 |
| 上传下载失败 | `files_service.rs` -> SCP adapter -> `transfer_jobs`。 |
| 隧道无法启动 | `tunnel_service.rs` -> embedded tunnel worker；local/dynamic 看本地 listener 和 direct TCP/IP，remote 看 libssh2 remote listener 和本地 target connector。 |
| 凭据读取失败 | `Stacio/Security/KeychainCredentialStore.swift` -> `SSHCredentialResolver.swift` -> `CredentialRepository`。 |
| 凭据中心列表/删除异常 | `Stacio/Services/CredentialCenterStore.swift` -> `AppSettingsWindowController.swift` -> `CredentialRepository`；确认 UI 只显示 metadata。 |
| Remote Edit AI 问题没进入右侧 AI | `RemoteTextEditorViewController.swift` -> `FilesViewController.swift`/`RemoteFilesPaneViewController.swift` -> `InspectorViewController.swift`。 |
| AI 命令审批/风险等级不符合预期 | `StacioAgentBridge/AgentActionClassifier.swift` -> `AgentActionAuthorizer.swift` -> `AgentExecutionCoordinator.swift`；同时检查 `TerminalCommandHighlighter.swift` 是否与分类结果一致。 |
| 终端命令高亮或 hint 错判 | `TerminalCommandHighlighter.swift` -> `TerminalCommandHintOverlayView.swift` -> `TerminalPaneViewController.swift` / `RemoteTerminalPaneViewController.swift`。 |
| 设备看板 Linux 数据缺失或磁盘列表噪声 | `StacioCore/src/services/device_metrics_service.rs` -> `DeviceMetricsDashboardViewController.swift`；重点看 `/proc` markers、`df` 输出、mount 过滤和 truncation warning。 |
| 诊断导出审计范围不对 | `DiagnosticsViewController.swift` 的 `Stacio.Diagnostics.auditScope` -> `diagnosticsJSONData()`。 |
| 导入错乱 | `import_service.rs` -> fixtures -> import report。 |
| MultiExec 发错目标 | `TerminalWorkspaceController.swift` -> audit events。 |
| BLE Console 扫描、连接或收发异常 | `BLEConsoleModels.swift` -> `BLEConsoleCentral.swift` -> `BLEConsoleSession.swift` -> `ConsoleSessionCoordinator.swift` -> [BLE Console Bug 索引](./ble-console-bug-index.md)。 |

## 6. 命名约定

1. Runtime ID 使用前缀：`term_`、`files_`、`tun_`、`job_`。
2. 数据库 ID 使用 UUID。
3. Swift 类型使用 PascalCase。
4. Rust service 使用 `*_service.rs`。
5. 错误码使用大写 snake case，例如 `SSH_AUTH_FAILED`。

## 7. 文档同步规则

实现开始后，每新增一个一级模块必须更新本文件：

1. 添加路径。
2. 写明职责。
3. 写明常见 bug 定位入口。
4. 如果有新的日志文件或错误码，同步更新 [Bug 快速定位文档](./bug-triage-guide.md)。

## 8. 已实现基础模块

| 路径 | 责任 |
| --- | --- |
| `Package.swift` | SwiftPM package manifest。 |
| `Stacio/App/StacioApplication.swift` | macOS app 入口。 |
| `Stacio/App/AppDelegate.swift` | app lifecycle 和主窗口启动。 |
| `Stacio/Windows/WorkbenchWindowController.swift` | 三栏 AppKit workbench shell。 |
| `Stacio/Bridge/CoreBridge.swift` | UniFFI health bridge。 |
| `StacioCore/src/lib.rs` | Rust Core UniFFI exports。 |
| `StacioCore/src/infrastructure/db.rs` | SQLite migration bootstrap。 |
| `scripts/generate-uniffi.sh` | Rust dylib 构建和 UniFFI Swift/C binding 生成。 |

## 9. 已实现终端模块

| 路径 | 责任 |
| --- | --- |
| `Stacio/Views/Terminal/TerminalPaneViewController.swift` | SwiftTerm local shell terminal pane。 |
| `Stacio/Views/Terminal/StacioLocalTerminalView.swift` | SwiftTerm local process view subclass with output callback。 |
| `Stacio/Views/Terminal/RemoteTerminalPaneViewController.swift` | SwiftTerm remote SSH terminal pane；通过 `TerminalEventSink` 转发 input/resize，通过 `RemoteTerminalBridging` timer poll live shell output，不启动本地进程。 |
| `Stacio/Views/Terminal/StacioRemoteTerminalView.swift` | SwiftTerm `TerminalView` subclass，用于 remote output feed。 |
| `Stacio/Views/Terminal/TerminalEventSink.swift` | Terminal resize/output/input/close event bridge。 |
| `Stacio/Views/Terminal/TranscriptRecorder.swift` | M1 in-memory transcript recorder。 |
| `Stacio/Views/Workspace/WorkspaceViewController.swift` | Local shell tab creation and workspace terminal host。 |
| `StacioCore/src/domain/terminal.rs` | Terminal runtime/input/output DTOs and UniFFI error type。 |
| `StacioCore/src/services/terminal_service.rs` | Terminal runtime registry、bounded input/output batching、resize revision 和 closed runtime guard。 |
| `StacioCore/src/services/live_shell_service.rs` | Deterministic live shell worker、`ShellChannel` trait、`LiveShellStatus` 和 fake channel tests。 |

## 10. 已实现会话与导入模块

| 路径 | 责任 |
| --- | --- |
| `StacioCore/src/domain/session.rs` | `parse_quick_connect` 支持 `user@host:port`、`ssh://user@host:port` 和 host-only 默认 22 端口；定义 `SessionFolder`、`SessionDraft`、带 `last_opened_at` 的 `SessionRecord`。 |
| `StacioCore/src/infrastructure/session_repository.rs` | 基于 SQLite 的 folder/session 创建、folder list、root session list、all-session list、session update/delete、`last_opened_at` 标记和不含密码的导出。 |
| `StacioCore/src/infrastructure/credential_repository.rs` | 基于 SQLite 的 credential metadata 保存/list/delete；不保存 password、passphrase 或私钥内容。 |
| `StacioCore/src/infrastructure/import_repository.rs` | SQLite `import_reports` 记录和恢复，保存 source、status、count 和脱敏 issues。 |
| `StacioCore/src/services/import_service.rs` | CSV/MobaXterm INI-like preview、`ImportApplyResult`/`ImportReport` DTO；不导入 password，只保留 private key path。 |
| `StacioCore/src/lib.rs` | UniFFI exports：Quick Connect、import preview/apply/report list、credential save/list/delete、`create_session_folder`、`list_session_folders`、`create_session_record`、`update_session_record`、`delete_session_record`、`list_session_records`、`list_all_session_records`、`mark_session_record_opened`。 |
| `Stacio/Bridge/CoreBridge.swift` | Swift facade 暴露 Quick Connect、import preview/apply/report list、credential metadata save/list/delete、session folder/session create/update/delete/list/all persistence 和 saved session opened 标记。 |
| `Stacio/Services/SessionImportCoordinator.swift` | Import flow 编排：选择文件、按扩展名/内容 preview、跳过全冲突导入、确认后 apply、成功后触发 refresh。 |
| `Stacio/Views/Dialogs/SessionImportPresenter.swift` | AppKit 原生导入预览/结果/错误 alert，显示 Name/Folder/Target/Status 和 warnings。 |
| `Stacio/Views/Sidebar/SessionSidebarViewController.swift` | macOS source-list 风格 sidebar，包含 Search 过滤、Quick Connect、Import action、New/Edit/Delete saved session actions、从 `SessionSidebarStoring` 载入的 session outline，以及双击/测试 helper 打开 saved session 的 callback；编辑成功后触发旧 credential best-effort cleanup。 |
| `Stacio/Views/Sidebar/SessionSidebarErrorPresentation.swift` | Sidebar save/delete/editor 错误展示边界；生产端用 AppKit `NSAlert`，文案避免输出 secret/raw error。 |
| `Stacio/Views/Sidebar/SessionSidebarStore.swift` | Sidebar session store production adapter，调用 CoreBridge session CRUD/list APIs，不读取 secret。 |
| `Stacio/Views/Sidebar/SessionSidebarSessionManagement.swift` | Sidebar saved session editor/delete confirmation production UI；遵循 AppKit sheet/alert 和 system symbol 控件风格，auth mode 会折叠无关字段并在 sheet 内显示校验反馈，password/passphrase 字段只交给 credential saver，`SessionDraft` 不携带 secret。 |
| `Stacio/Views/Sidebar/SessionSidebarCredentialSaving.swift` | Sidebar credential saver/cleaner；保存 credential metadata 与 Stacio 凭据库 secret，凭据库失败时回滚 metadata；编辑 session 替换 credential 后，只有旧 credential 无任何 session 引用时才删除旧凭据和 metadata。 |
| `Tests/StacioAppTests/SessionBridgeTests.swift` | Swift bridge 层 Quick Connect、import preview/apply/report、session folder/session persistence 和 `lastOpenedAt` 标记测试。 |
| `Tests/StacioAppTests/SessionImportCoordinatorTests.swift` | Swift coordinator 层 import preview/confirm/apply/refresh、取消、全冲突跳过和 unknown fallback 测试。 |
| `Tests/StacioAppTests/SessionSidebarViewControllerTests.swift` | Swift UI 层 Sidebar controls、Search 过滤、Quick Connect/Import action、saved session Add/Edit/Delete、store error presentation、持久化 session source-list 渲染和 open callback 测试。 |
| `Tests/StacioAppTests/SessionSidebarSessionFormTests.swift` | Saved session editor 表单测试：auth mode 字段可见性、Password/Passphrase 标签、Save 启用状态和 sheet 内校验文案。 |
| `Tests/StacioAppTests/SessionSidebarCredentialSaverTests.swift` | 验证 Stacio 凭据库 saver、凭据库失败 metadata 回滚、旧 credential 无引用清理/仍被引用保留、password/private-key passphrase draft factory、account 变更时拒绝复用旧 credential ref、credential ref 保留和 no-secret draft 行为。 |
| `Tests/StacioAppTests/SavedSessionConnectionFlowTests.swift` | 验证从 SQLite saved session + credential ref 到 `SSHConnectionCoordinator`/embedded live shell starter 的 password 与 private-key passphrase 集成链路，并确认成功打开后写回 `lastOpenedAt`；包含复用 `STACIO_SSH_FIXTURE_*` 的默认跳过 live SSH smoke test。 |
| `Tests/StacioAppTests/WorkbenchWindowControllerTests.swift` | 验证 saved session 使用 embedded SSH/Telnet/Serial/SCP/FTP/open-local/browser/file/VNC 链路，并验证 RDP saved session 被拒绝且不启动 SSH 或图形 runtime；SSH/SCP 按 session metadata 转换为 agent/password/private-key `SshConnectionConfig`，FTP 解析 Stacio 凭据库 password 并打开 FTP files pane，Telnet 转换为 `TelnetConnectionConfig`，Serial 转换为 `SerialConnectionConfig`，成功后标记最近打开，失败不标记，且不调用系统 `ssh/scp/telnet/ftp/screen/cu/minicom`。 |
| `Tests/fixtures/import/` | CSV 和 MobaXterm INI-like 导入测试样例。 |

## 11. 已实现 SSH Runtime 基础模块

| 路径 | 责任 |
| --- | --- |
| `StacioCore/src/domain/ssh.rs` | 结构化 SSH 配置、Password/PrivateKey/Agent auth label、host key SHA-256 fingerprint、known-host match/change/unknown 判断。 |
| `StacioCore/src/services/ssh_service.rs` | `SshTransport` 合同、mock transport、auth failure/timeout/host key changed 错误映射。 |
| `StacioCore/src/infrastructure/ssh/libssh2_transport.rs` | libssh2 production adapter scaffold，当前只接受结构化 config 并返回 typed scaffold error。 |
| `Tests/StacioAppTests/SSHBridgeTests.swift` | Swift/UniFFI 侧 SSH config validation 和 redacted diagnostics 验证。 |

## 12. 已实现 SCP Files 基础模块

| 路径 | 责任 |
| --- | --- |
| `StacioCore/src/domain/files.rs` | 解析 SSH exec 生成的 TSV 远程文件列表，返回 file/dir/symlink typed entries。 |
| `StacioCore/src/domain/scp.rs` | SCP upload/download job、progress、conflict policy 和 typed errors。 |
| `StacioCore/src/services/scp_service.rs` | `ScpEngine` 合同和 mock transfer progress。 |
| `StacioCore/src/infrastructure/scp/mock_engine.rs` | success/permission denied/interrupted 的 deterministic engine tests。 |
| `Tests/StacioAppTests/TransferBridgeTests.swift` | Swift/UniFFI 侧 remote listing、conflict resolution 和 simulated transfer 验证。 |

## 13. 已实现 Tunnel 与 Diagnostics 基础模块

| 路径 | 责任 |
| --- | --- |
| `StacioCore/src/domain/tunnel.rs` | local/remote/dynamic tunnel profile、local-port preflight applicability、state transition、error code。 |
| `StacioCore/src/services/tunnel_service.rs` | `TunnelChannel` 合同、mock start/stop runtime status、本地端口占用 preflight、`TunnelRuntimeManager` 长生命周期 worker 注册/poll_all/stop、`TunnelPumpSignal` 低资源唤醒和 SSH failure 映射。 |
| `StacioCore/src/infrastructure/tunnel/mock_channel.rs` | deterministic tunnel channel tests。 |
| `StacioCore/src/infrastructure/tunnel/libssh2_channel.rs` | libssh2 tunnel adapter：local forward -> `channel_direct_tcpip` 请求模型、本地端口 preflight、TCP listener acceptor、持有 embedded libssh2 session 的 direct-tcpip opener、remote forward -> `channel_forward_listen` listener、本地 target connector、单次双向 copy pump、local/remote tunnel accept/connect/pump worker、dynamic SOCKS worker 和无系统命令测试。 |
| `StacioCore/src/infrastructure/tunnel/socks5.rs` | 内置 SOCKS5 no-auth handshake、IPv4/domain CONNECT 解析和 failure/success response 常量；dynamic tunnel 不依赖系统 ssh/scp/sftp。 |
| `StacioCore/src/infrastructure/tunnel_repository.rs` | SQLite tunnel profile repository；`upsert_profile`、`list_profiles`、`delete_profile` 覆盖 profile 管理底座。 |
| `StacioCore/src/domain/diagnostics.rs` | diagnostic entries/bundles 和 credential/private-key-path redaction。 |
| `StacioCore/src/services/diagnostics_service.rs` | diagnostics bundle builder。 |
| `StacioCore/src/lib.rs` | UniFFI exports：`validate_tunnel_profile`、`check_tunnel_local_port_available`、`save_tunnel_profile`、`list_tunnel_profiles`、`delete_tunnel_profile`、`start_mock_tunnel`、`start_live_local_tunnel_runtime`、`poll_live_tunnel_runtime`、`close_live_tunnel_runtime`、`stop_tunnel_runtime`、`build_diagnostic_bundle`；live tunnel runtime 按 profile kind 选择 local forward、remote forward 或 dynamic SOCKS worker。 |
| `Stacio/Bridge/CoreBridge.swift` | Swift facade 暴露 tunnel validation、本地端口 preflight、profile save/list/delete、mock tunnel start/stop、live local tunnel start/poll/close 和 diagnostics bundle。 |
| `Tests/StacioAppTests/DiagnosticsBridgeTests.swift` | Swift/UniFFI 侧 tunnel validation、本地端口 preflight、profile persistence、mock tunnel runtime start/stop、live local tunnel invalid-config preflight、live tunnel poll/close、port-in-use error 和 diagnostics redaction 验证。 |

## 14. 已实现 MultiExec 与 Macro 基础模块

| 路径 | 责任 |
| --- | --- |
| `StacioCore/src/domain/multiexec.rs` | target selection、disabled target filtering、production confirmation guard 和 visible active-state requirement。 |
| `StacioCore/src/services/multiexec_service.rs` | broadcast input audit preparation；当前只生成 audit，不执行真实终端输入。 |
| `StacioCore/src/domain/macro_recording.rs` | macro recording/step DTO 和输入脱敏。 |
| `StacioCore/src/services/macro_service.rs` | macro JSON serialization 和 playback step ordering。 |
| `Tests/StacioAppTests/MultiExecBridgeTests.swift` | Swift/UniFFI 侧生产环境保护和 macro secret redaction 验证。 |

## 15. 已实现图形适配器诊断基础模块

| 路径 | 责任 |
| --- | --- |
| `StacioCore/src/domain/graphics.rs` | X11 capability、DISPLAY/xauth、VNC 适配器 config tests。 |
| `StacioCore/src/services/graphics_service.rs` | X11 forwarding 参数、X11 diagnostics 和 VNC launch config。 |
| `StacioAdapters/VNC/main.swift` | Stacio bundle 内 VNC adapter；当前覆盖本机 TCP/RFB 握手、RFB 003.008/003.007 security-type list、RFB 003.003 None / VNCPassword 安全握手、VNCPassword(2) challenge-response、首帧前 Bell/ServerCutText 跳过、首帧 Raw/CopyRect/RRE/CoRRE/Hextile/Zlib/ZRLE/DesktopSize/LastRect update smoke、DesktopSize 尺寸状态输出和失败诊断，供主 App 验证 bundle 内 adapter 启动契约，不调用系统远程桌面客户端。 |
| `Stacio/Views/Graphics/GraphicsSessionPaneViewController.swift` | AppKit 原生图形会话 Pane；VNC 保存会话显示中文图形状态，不调用系统远程桌面软件。 |
| `Stacio/Services/GraphicsRuntimeManager.swift` | Graphics adapter runtime；当前只支持 VNC，通过可注入 launcher 启动 bundle 内 adapter；RDP 请求会被拒绝且不会启动外部客户端或适配器。 |
| `Stacio/Views/Workspace/WorkspaceViewController.swift` | `openGraphicsSession` 把 VNC 图形视图放入 Workspace tab，并支持 runtime manager 提供的 runtime id。 |
| `Stacio/Windows/WorkbenchWindowController.swift` | VNC saved session 构建受控适配器 launch config；保存密码凭据时以脱敏参数传给 bundle adapter，凭据 secret 丢失时会走 Stacio 补录流程并更新 credential ref，然后通过 `GraphicsRuntimeManager` 启动 runtime；缺少适配器时打开诊断 Pane 而不是误走 SSH。 |
| `Tests/StacioAppTests/GraphicsBridgeTests.swift` | Swift/UniFFI 侧 X11 args 和 VNC missing adapter diagnostics 验证。 |
| `Tests/Packaging/vnc_adapter_tcp_smoke_test.sh` | VNC adapter 本机 RFB handshake smoke；启动 fake RFB server，覆盖 RFB 003.008/003.007/003.003 版本协商、None / VNCPassword(2) 安全类型、首帧前 Bell/ServerCutText、首帧 Raw/CopyRect/RRE/CoRRE/Hextile/Zlib/ZRLE/DesktopSize/LastRect update、DesktopSize 新尺寸输出、密码缺失诊断和失败诊断，不依赖真实远程桌面服务器。 |
| `Tests/StacioAppTests/WorkspaceLocalShellTests.swift` | Workspace 图形诊断 tab 渲染和中文文案验证。 |
| `Tests/StacioAppTests/WorkbenchWindowControllerTests.swift` | VNC saved session 在存在 bundle 适配器时启动图形 runtime skeleton，并覆盖保存密码凭据传给 adapter 且 UI 脱敏的回归验证；RDP saved session 只覆盖 rejected regression。 |

## 16. 已实现 libssh2 SSH/SCP Adapter

| 路径 | 责任 |
| --- | --- |
| `StacioCore/Cargo.toml` | 引入 `ssh2`，启用 `vendored-openssl`，避免依赖用户本机 OpenSSL/pkg-config。 |
| `StacioCore/src/infrastructure/ssh/libssh2_transport.rs` | libssh2 SSH endpoint/timeout/session entrypoints、TCP connect、handshake、password/private-key-memory/agent auth、host key summary、shell PTY startup 和 gated fixture tests。 |
| `StacioCore/src/infrastructure/files/libssh2_exec_listing.rs` | libssh2 SSH exec remote directory listing：构造受控 `find` TSV 输出、解析为 `RemoteFileEntry`，不调用本机文件传输工具。 |
| `StacioCore/src/infrastructure/scp/libssh2_engine.rs` | libssh2 SCP request validation、local file size checks、remote path safety、chunked cancellable copy、chunk progress recording、`scp_send` upload、`scp_recv` download 和 gated fixture tests。 |
| `StacioCore/src/infrastructure/transfer_repository.rs` | SQLite transfer history：upsert SCP jobs、append progress/failure events、保留脱敏 message、按创建顺序恢复 jobs/events，不存储 secret 或本机命令字符串。 |
| `StacioCore/src/lib.rs` | `list_live_remote_directory` UniFFI export：validate config -> expected host key session -> SSH exec listing -> `RemoteFileEntry`。 |
| `StacioCore/src/lib.rs` | `run_live_scp_transfer` UniFFI export：validate config -> expected host key session -> libssh2 SCP upload/download -> `ScpTransferProgress`；`run_live_ftp_transfer` 走内置 FTP retrieve/store；`cancel_live_scp_transfer`/`cancel_live_ftp_transfer` 标记运行中 job 中断；`take_live_scp_transfer_progress_batch` 返回并清空 job progress batch。 |
| `StacioCore/src/lib.rs` | `record_scp_transfer_job`、`append_scp_transfer_progress`、`append_scp_transfer_progress_with_message`、`list_scp_transfer_jobs`、`list_scp_transfer_events` UniFFI exports：打开 SQLite、应用 migration、调用 `TransferRepository`。 |
| `Stacio/Bridge/CoreBridge.swift` | Swift facade 暴露 `parseRemoteListing`、`listLiveRemoteDirectory`、`simulateSCPTransfer`、`runLiveSCPTransfer`、`runLiveFTPTransfer`、`cancelLiveSCPTransfer`、`cancelLiveFTPTransfer`、`takeLiveSCPTransferProgressBatch` 和带可选失败 message 的 transfer history persistence。 |
| `Stacio/Services/FilesCoordinator.swift` | `RemoteFilesBridging` production adapter 和 Files UI update coordinator；支持 parse-only listing、显式 live remote listing、以及从当前 live session context 加载远端目录。 |
| `Stacio/Services/TransferQueueCoordinator.swift` | `SCPTransferBridging`/`FTPTransferBridging` production adapter、`SCPTransferHistoryStoring` adapter 和 queue update coordinator；已支持 queued/running/completed/failed/canceled 内存状态、默认单并发且可配置上限的后台调度、SCP 运行中 progress polling、失败诊断脱敏与恢复、queued/running cancel、SCP/FTP Core 取消请求、failed retry request、history restore 和取消后忽略 late completion。 |
| `Stacio/Views/Files/FilesViewController.swift` | AppKit 原生 remote files 表格，消费 `RemoteFileEntry`，显示 kind/path/size/link 和 Embedded SCP engine，不使用 SFTP/rsync 文案或本机命令。 |
| `Stacio/Views/Transfers/TransferQueueViewController.swift` | AppKit 原生 transfer queue 表格，按 SCP job 汇总最新 progress，显示 Progress/Status/Speed/ETA/Detail 和 Embedded SCP engine，并用 macOS symbol icon 暴露 Retry/Cancel action，不使用 SFTP/rsync 文案或本机命令。 |
| `Stacio/Views/Tunnels/TunnelsViewController.swift` | AppKit 原生 tunnel 表格，显示 Kind/Local/Remote/Status/Detail，使用 macOS symbol icon 暴露 Add/Edit/Delete 和 Start/Stop action；有 live session context 时调用 embedded live tunnel runtime（local forward / remote forward / dynamic SOCKS），缺少 context 时显示 `missing_live_session_context`。 |
| `Stacio/Views/Tunnels/TunnelProfileManagement.swift` | Swift profile 管理 adapter：`CoreBridgeTunnelProfileStore` 调用 `save/list/deleteTunnelProfile`，默认 editor 使用 AppKit alert accessory view 和 `NSSegmentedControl` 选择 Local/Remote/Dynamic。 |
| `Tests/StacioAppTests/FilesViewControllerTests.swift` | Swift UI 层 Files 表格渲染、empty state、Inspector 接线、内嵌编辑器分栏、折叠恢复和强制 Monaco 布局同步测试。 |
| `Tests/StacioAppTests/RemoteTextEditorViewControllerTests.swift` | Remote Text Editor 的 page generation、两阶段 workspace handshake、真实 Monaco、`0 x 0`/resize/重挂布局、WebContent/导航/JS 有限恢复、同 URI model 复用和 async save/close revision 回归。 |
| `Tests/StacioAppTests/FilesCoordinatorTests.swift` | Swift coordinator 层 remote listing parse、Files UI 更新和 parse failure 保持 empty state 测试。 |
| `Tests/StacioAppTests/TransferBridgeTests.swift` | Swift bridge 层 remote listing parser、conflict policy、SCP transfer、live preflight、progress polling 和 transfer history/failure message persistence 测试。 |
| `Tests/StacioAppTests/TransferQueueViewControllerTests.swift` | Swift UI 层 transfer queue 渲染、empty state、progress coalescing、Speed/ETA、failure Detail、传输日志、Retry/Cancel action 和 Inspector 接线测试。 |
| `Tests/StacioAppTests/TransferQueueCoordinatorTests.swift` | Swift coordinator 层 live SCP/FTP 调用、后台队列并发上限、SCP 运行中 progress polling、运行中取消、队列更新、失败状态/诊断、历史传输日志恢复、重试请求和 secret 不进入 debug 输出测试。 |
| `Tests/StacioAppTests/TunnelsViewControllerTests.swift` | Swift UI 层 Tunnels 表格渲染、empty state、Add/Edit/Delete profile 管理、Start/Stop action、live local/remote/dynamic start wiring、失败诊断脱敏和 Inspector 接线测试。 |

`SSHConnectionCoordinator.makeTunnelLiveSessionContext` 会复用 host-key 验证、credential resolution 和 private-key material loading，生成 `TunnelLiveSessionContext`；`QuickConnectCoordinator`、`RemoteSSHSessionCoordinator` 和 `SSHConnectionCoordinator.connect` 成功路径会把当前可信 live SSH context 写入同一个 `TunnelLiveSessionStore`，`WorkbenchWindowController` -> `InspectorViewController` -> `TunnelsViewController`/`FilesCoordinator` 共享该 provider。

Fixture 集成测试默认跳过。要执行真实 SSH/SCP 路径，设置：

```bash
export STACIO_SSH_FIXTURE_HOST=127.0.0.1
export STACIO_SSH_FIXTURE_PORT=2222
export STACIO_SSH_FIXTURE_USERNAME=stacio
export STACIO_SSH_FIXTURE_PASSWORD='...'
export STACIO_SSH_FIXTURE_REMOTE_DIR=/tmp
# Optional: override default /root denied-path failure fixture.
export STACIO_SSH_FIXTURE_READONLY_REMOTE_PATH=/root/stacio-denied-fixture.txt
cargo test --manifest-path StacioCore/Cargo.toml libssh2_transport
cargo test --manifest-path StacioCore/Cargo.toml libssh2_scp
```

`libssh2_transport` fixture 包含 interactive shell smoke test，会打开 PTY shell 并读取 marker 输出。私钥 fixture 可用 `STACIO_SSH_FIXTURE_PRIVATE_KEY` 和可选 `STACIO_SSH_FIXTURE_PRIVATE_KEY_PASSPHRASE` 代替 password。Files/Transfer queue UI 已有 AppKit 表格骨架，Swift 已能调用真实 `listLiveRemoteDirectory`、`runLiveSCPTransfer` 和 `runLiveFTPTransfer` bridge。Transfer queue 已有 Swift 内存状态、默认单并发且可配置上限的后台调度、SCP 运行中 progress polling、Speed/ETA、失败诊断 Detail、queued/running cancel、failed retry request、history restore、libssh2 copy-loop cancellation、FTP Core cancel bridge、FTP chunk-boundary cancellation、late completion ignore 和 gated 真实失败路径覆盖。

## 17. 已实现 Stacio 凭据库与 Host Key 确认基础模块

| 路径 | 责任 |
| --- | --- |
| `Stacio/Security/KeychainCredentialStore.swift` | Stacio 本地凭据库 facade、AES-GCM 文件 backend、内存测试 backend 和 secret 脱敏；生产路径不调用 macOS Keychain/Security.framework。 |
| `Stacio/Security/SSHCredentialResolver.swift` | password credential ref、private-key passphrase ref、agent auth 的短生命周期 secret 解析边界。 |
| `Stacio/Views/Sidebar/SessionSidebarCredentialSaving.swift` | saved session editor 写入 password/passphrase 的唯一生产入口；SQLite 只拿 credential metadata，Stacio 凭据库保存 secret，凭据库写失败时回滚 metadata；credential 替换后只清理无引用旧 credential。 |
| `Stacio/Views/Sidebar/SessionSidebarSessionManagement.swift` | auth mode 到 `SessionDraft` 的转换规则；password 新建必须有 secret，编辑同模式且 account 不变时 secret 留空才保留 credential ref；AppKit 表单按 auth mode 折叠字段并在 sheet 内禁用 Save/展示校验文案。 |
| `Stacio/Views/Security/HostKeyConfirmationPresenter.swift` | host key unknown/changed 的 AppKit alert sheet 配置，按钮使用明确安全动作。 |
| `Tests/StacioAppTests/KeychainCredentialStoreTests.swift` | Stacio 凭据库 storage key、redaction、AES-GCM 文件 backend、save/read/delete 行为验证。 |
| `Tests/StacioAppTests/SSHCredentialResolverTests.swift` | SSH auth method 到 Stacio 凭据库 secret 的解析验证。 |
| `Tests/StacioAppTests/SessionSidebarCredentialSaverTests.swift` | saved session password/passphrase 保存、旧 credential 清理策略和 no-secret draft 回归测试。 |
| `Tests/StacioAppTests/SessionSidebarSessionFormTests.swift` | saved session editor auth mode UI 和 validation feedback 回归测试。 |
| `Tests/StacioAppTests/SavedSessionConnectionFlowTests.swift` | saved session 打开时从 SQLite credential ref 解析 Stacio 凭据库 secret 并启动 embedded live shell 的回归测试；fixture env 配好时会真实打开 embedded SSH shell 并读取 marker。 |
| `Tests/StacioAppTests/HostKeyConfirmationPresenterTests.swift` | host key confirmation alert 的标题、文案、按钮和无 secret 内容验证。 |
| `StacioCore/src/domain/ssh.rs` | `HostKeyTrustDecision` UniFFI-safe DTO，用于后续 Swift UI 回传 trust/reject。 |

## 18. 已实现 Known Hosts 持久化基础模块

| 路径 | 责任 |
| --- | --- |
| `StacioCore/migrations/0001_init.sql` | 增加 `known_hosts` 表，主键为 `(host, port)`。 |
| `StacioCore/src/infrastructure/known_host_repository.rs` | known host upsert、lookup、list all 和 no-secret serialization tests。 |
| `StacioCore/src/services/ssh_service.rs` | `KnownHostStore` trait 和 `apply_host_key_decision`，支持 trust once、trust and save、reject。 |
| `StacioCore/src/lib.rs` | UniFFI exports：host key fingerprint、known host verification、trust decision label。 |
| `Tests/StacioAppTests/SSHBridgeTests.swift` | Swift bridge host key helper、changed host key rejection 和 decision label 验证。 |

## 19. 已实现 Live SSH 连接编排基础模块

| 路径 | 责任 |
| --- | --- |
| `StacioCore/src/domain/ssh.rs` | `LiveSshHostKey` 和 `SshAuthSecret` UniFFI DTO；host key raw bytes/secret debug 输出脱敏。 |
| `StacioCore/src/infrastructure/ssh/libssh2_transport.rs` | `probe_host_key` 只做 TCP + SSH handshake，不发送凭据；`connect_with_secret_and_expected_host_key` 在 auth 前校验 expected fingerprint。 |
| `StacioCore/src/lib.rs` | UniFFI exports：`apply_host_key_decision_in_database`、`probe_live_ssh_host_key`、`connect_live_ssh`。 |
| `Stacio/Bridge/CoreBridge.swift` | Swift facade 暴露 database-backed host key decision、live host key probe 和 live SSH connect。 |
| `Stacio/Security/SSHConnectionCoordinator.swift` | 编排 probe -> known_hosts/confirm -> credential resolver -> expected fingerprint connect。 |
| `Tests/StacioAppTests/SSHConnectionCoordinatorTests.swift` | 验证 host key 先于凭据解析、changed key 阻断、private key material loader 不调用系统命令。 |

## 20. 已实现 Live SSH Shell Channel 基础模块

| 路径 | 责任 |
| --- | --- |
| `StacioCore/src/services/live_shell_service.rs` | `ShellChannel` trait、`LiveShellWorker`、`LiveShellManager`、`LiveShellPumpSignal`、socket wait interest、fake shell channel 和 terminal queue polling 行为。 |
| `StacioCore/src/infrastructure/ssh/libssh2_transport.rs` | `Libssh2ShellRequest`、`Libssh2ShellChannel`、PTY request、extended data merge、nonblocking libssh2 shell channel adapter，并暴露 libssh2 socket readiness interest。 |
| `StacioCore/src/lib.rs` | UniFFI exports：`poll_live_ssh_shell`、`close_live_ssh_shell`、`start_live_ssh_shell_runtime`；production 全局 manager 持久保存 `LiveShellWorker<Libssh2ShellChannel>`，首次 live shell 启动 Rust 后台 pump 线程。 |
| `Stacio/Bridge/CoreBridge.swift` | Swift facade 暴露 live shell poll/close/start。 |
| `Stacio/Views/Terminal/RemoteTerminalPaneViewController.swift` | Remote terminal pane timer 只读取 CoreBridge output batch 和状态，关闭时同步 close live shell；不负责驱动 libssh2 channel。 |
| `Tests/StacioAppTests/RemoteTerminalPaneViewControllerTests.swift` | Swift poller 注入 fake bridge，验证 status/output drain 和 close shell。 |
| `Tests/StacioAppTests/SSHBridgeTests.swift` | Swift bridge 验证 live shell status type 和 start API invalid config guard。 |

后台泵送模型：`start_live_ssh_shell_runtime` 校验通过后启动单一 Rust pump 线程；线程通过 libssh2 socket readiness 和内部 wake pipe 等待事件，input/resize/start/close 会唤醒 pump。Swift pane 隐藏时不再影响 channel pumping，Swift timer 只承担渲染队列 drain。

## 21. 已实现 Live Serial Shell Channel 基础模块

| 路径 | 责任 |
| --- | --- |
| `StacioCore/src/domain/serial.rs` | `SerialConnectionConfig` UniFFI DTO；校验 device path 非空、baud rate 非零，debug 输出不包含系统命令或 secret。 |
| `StacioCore/src/infrastructure/serial.rs` | macOS 友好的内置串口 channel；使用 `open` + `termios` raw mode + `poll` readiness，支持常见 baud rate，不调用 `screen/cu/minicom`。 |
| `StacioCore/src/services/terminal_service.rs` | `open_serial` 创建 `remote_serial` terminal runtime，device path 暂存于 `remote_host`，baud rate 暂存于 `remote_port`。 |
| `StacioCore/src/lib.rs` | UniFFI export：`start_live_serial_shell_runtime`；注册 `LiveShellWorker<SerialShellChannel>` 并复用 live shell pump。 |
| `Stacio/Services/SerialSessionCoordinator.swift` | Swift 编排 Serial runtime start，并打开 Workspace remote terminal pane。 |
| `Stacio/Windows/WorkbenchWindowController.swift` | Saved session `protocol == serial` 时把 `host` 解释为设备路径、`port` 解释为 baud rate，进入 embedded Serial starter。 |
| `Tests/StacioAppTests/SSHBridgeTests.swift` | Swift bridge 验证 Serial start API 的 invalid config preflight 和 no-secret/no-system-command 描述。 |
| `Tests/StacioAppTests/WorkbenchWindowControllerTests.swift` | 验证 saved Serial session 使用 embedded Serial starter，不误走 SSH starter。 |

当前临时数据映射：在专用串口表单落地前，`SessionRecord.host` 保存 `/dev/cu.*` 设备路径，`SessionRecord.port` 保存 baud rate（例如 `9600`、`115200`）。后续需要迁移到 protocol-specific config JSON 或专用字段。

## 22. 已实现 BLE Console 模块

| 路径 | 责任 |
| --- | --- |
| `StacioCore/src/domain/console.rs` | Console v1 持久化 DTO、UUID 规范化、FFE1/FFE3/FFE2 与 FFE0/FFE1 profile 匹配、custom profile 校验和跨平台 transport policy；macOS 固定 BLE-only，Windows 只有 exact COM binding 才允许 BLE-then-SPP。 |
| `StacioCore/src/lib.rs` | UniFFI exports：`parse_console_session_config`、`serialize_console_session_config`、`match_ble_console_profile` 和 `console_transport_policy`。 |
| `Stacio/Bridge/CoreBridge.swift` | Swift facade 暴露 Console config 解析/序列化、GATT profile 匹配和 transport policy。 |
| `Stacio/Services/BLEConsoleModels.swift` | RSSI 规范化、设备名称 fallback、NBEE 识别/置顶、扫描快照去重/节流/过期淘汰和稳定 BLE 错误码。 |
| `Stacio/Services/BLEConsoleCentral.swift` | CoreBluetooth adapter；管理权限/电源状态、无 service filter 扫描、精确 peripheral retrieval、GATT discovery/subscribe/write 和 generation callback。 |
| `Stacio/Services/BLEConsoleSession.swift` | BLE 会话状态机；profile discovery、RX 原始字节、TX MTU 分块/背压/保序、有限重连、stale generation 过滤和幂等 close。 |
| `Stacio/Services/ConsoleSessionCoordinator.swift` | 把 BLE session 接入现有 remote terminal pane；pane input、Macro、Agent 和 MultiExec 共用 Console TX，且从不启动 Serial runtime。 |
| `Stacio/Views/Dialogs/BLEConsoleScannerViewController.swift` | 原生 AppKit 扫描/绑定 sheet；显示设备名、原生信号图标与 RSSI，`NBEE_BLE_1103` 高亮置顶但不自动选择或连接。 |
| `Stacio/Views/Dialogs/BLEConsoleCharacteristicMapperViewController.swift` | unknown GATT profile 的 service/TX/RX/write type 选择与组合校验。 |
| `Stacio/Views/Dialogs/BLEConsoleSessionEditorView.swift` | saved Console session 的 BLE binding/profile 摘要、扫描和重新绑定入口。 |
| `Stacio/Views/Dialogs/SessionSettingsViewController.swift` | 保存 `protocol=console`、`port=0` 和 Console v1 `config_json`；新会话必须完成显式扫描、选择和 profile 确认。 |
| `Stacio/Windows/WorkbenchWindowController.swift` | 打开 saved Console 时解析并校验配置、要求当前 macOS binding、调用独立 Console starter；不进入 Serial starter。 |
| `Tests/StacioAppTests/BLEConsoleModelsTests.swift` | RSSI、NBEE 识别、去重、排序节流、selection 保持与过期淘汰回归。 |
| `Tests/StacioAppTests/BLEConsoleCentralTests.swift` | 扫描、advertisement 合并、超时、精确 retrieval、GATT 操作和 generation 透传回归。 |
| `Tests/StacioAppTests/BLEConsoleSessionTests.swift` | profile、订阅、RX、TX chunk/backpressure/order、重连、stale callback 和 close 回归。 |
| `Tests/StacioAppTests/ConsoleSessionCoordinatorTests.swift` | Console terminal runtime 接入、输入/输出/关闭和 Serial 隔离回归。 |
| `Tests/StacioAppTests/BLEConsoleScannerViewControllerTests.swift` | AppKit 设备行、信号显示、NBEE 高亮置顶、显式 selection 与 custom mapper 入口回归。 |
| `Tests/StacioAppTests/SessionSettingsViewControllerTests.swift` | Console 表单、保存门禁、binding probe 断开、`port=0` 持久化和 Serial 隔离回归。 |
| `Tests/StacioAppTests/SavedSessionConnectionFlowTests.swift` | saved Console 配置解析、独立 starter 路由、无效 schema 拒绝和 Serial starter 零调用回归。 |
| `docs/development/ble-console-bug-index.md` | 自动化覆盖状态、未复现风险、真实 NBEE manual matrix 和 Windows future 缺陷入口。 |
| `docs/platform/windows-adaptation-plan.md` | Windows WinRT BLE-first adapter、有限重试和 exact-COM-only SPP fallback 交接。 |

BLE Console 与 Serial 是两个独立 protocol 和 runtime owner。macOS Console 失败时只允许 BLE 重试、重扫或重新绑定，不读取 `sppFallback`，也不得打开 `/dev/cu.*`；现有 USB、手动串口和 `NBEE_SPP_*` 兼容逻辑继续只属于 Serial。
