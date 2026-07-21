import Foundation

enum L10n {
    enum Common {
        static let ok = "确定"
        static let cancel = "取消"
        static let close = "关闭"
        static let stop = "停止"
        static let save = "保存"
        static let delete = "删除"
    }

    enum Menu {
        static let about = "关于 Stacio"
        static let file = "文件"
        static let edit = "编辑"
        static let terminal = "终端"
        static let view = "视图"
        static let help = "帮助"
        static let settings = "设置"
        static let quit = "退出 Stacio"
        static let newSession = "新建会话"
        static let newLocalTerminal = "新建本地终端"
        static let closeCurrentTerminal = "关闭当前终端"
        static let cut = "剪切"
        static let copy = "复制"
        static let paste = "粘贴"
        static let selectAll = "全选"
        static let find = "查找"
        static let splitTerminal = "分屏布局"
        static let multiExec = "多执行"
        static let toggleSidebar = "显示/隐藏会话列表"
        static let toggleDeviceDashboard = "显示/隐藏设备看板"
        static let feedback = "反馈"
        static let checkForUpdates = "检查更新"
        static let license = "License"
    }

    enum ProductOps {
        static let feedbackTitle = "反馈"
        static let feedbackSubtitle = "提交前请确认将发送的诊断信息。"
        static let feedbackTitleField = "标题"
        static let feedbackType = "类型"
        static let feedbackDescription = "描述"
        static let feedbackContact = "联系方式（可选）"
        static let feedbackDiagnostics = "将随反馈发送"
        static let feedbackIncludeDiagnostics = "我同意随反馈附带清洗后的诊断信息"
        static let feedbackPreviewDiagnostics = "预览诊断信息"
        static let feedbackDiagnosticsPreviewTitle = "将发送的诊断信息"
        static let submitFeedback = "提交反馈"
        static let copyError = "复制错误信息"
        static let feedbackValidation = "请填写标题和描述。"
        static let feedbackSubmitting = "正在提交反馈..."
        static let feedbackSubmitted = "反馈已提交，谢谢。"
        static let feedbackFailedPrefix = "提交失败："
        static let feedbackConfirmTitle = "提交反馈？"
        static let feedbackConfirmMessage = "Stacio 只会发送你填写的反馈和下方可见诊断信息，不会包含 SSH 密钥、终端内容、文件内容、环境变量、token 或密码。"

        static let updateTitle = "检查更新"
        static let updateInitial = "点击“检查更新”手动读取版本信息。Stacio 不会自动下载或静默安装更新。"
        static let updateChecking = "正在检查更新..."
        static let updateUpToDate = "已是最新版本。"
        static func updateAvailable(version: String, build: String) -> String {
            "发现新版本 \(version) (Build \(build))。"
        }
        static let updateFailedPrefix = "检查失败："
        static let checkUpdates = "检查更新"
        static let openDownloadPage = "打开下载页"
        static let updateDownload = "下载更新"
        static let updateLater = "稍后提醒"
        static let updateSkipVersion = "跳过此版本"
        static let updateReleaseNotesUnavailable = "此版本未提供可显示的更新说明。"
        static let updateInstallConfirmTitle = "安装更新并重新启动 Stacio？"
        static func updateInstallConfirmMessage(version: String, build: String) -> String {
            "Stacio \(version) (Build \(build)) 已下载并校验完成。确认后应用将退出、安装更新并重新打开。"
        }
        static let updateInstallAndRelaunch = "安装并重新启动"
        static let updateTerminationRetryTitle = "Stacio 尚未退出"
        static let updateTerminationRetryMessage = "应用取消或延迟了退出，更新暂时无法继续。是否再次尝试退出并安装？"
        static let updateTerminationRetry = "重试退出并安装"
        static let updateTerminationPaused = "Stacio 未能退出，更新安装已暂停。"
        static let updateConfirmTitle = "打开下载页？"
        static let updateConfirmMessage = "Stacio 将在浏览器中打开下载页；下载和安装必须由你手动确认。"
        static let releaseNotes = "Release Notes"

        static let licenseTitle = "License"
        static let licenseSubtitle = "在线验证 License 状态，离线授权文件会在本机完成签名与身份校验。"
        static let licenseStatus = "授权状态"
        static let licenseKey = "License Key"
        static let licenseUser = "用户名"
        static let licenseEmail = "邮箱"
        static let licensePlan = "套餐"
        static let licenseExpires = "到期"
        static let licenseGraceUntil = "宽限至"
        static let licenseOfflineToken = "离线授权 token"
        static let applyOfflineToken = "应用离线 token"
        static let importOfflineLicenseFile = "导入离线授权文件..."
        static let validateOnline = "在线校验"
        static let licenseOnlineReserved = "在线校验将连接 Stacio 授权服务；设备指纹只作为激活/风险信号。"
        static let licenseMissingIdentity = "请填写 License Key、用户名和邮箱。"
        static let licenseValidatingOnline = "正在在线校验 License..."
        static let licenseOnlineValidated = "在线授权校验完成。"
        static func licenseOnlineCompleted(status: String) -> String {
            "在线校验完成，当前状态：\(status)。"
        }
        static let licenseTokenApplied = "离线授权已应用。"
        static let licenseFileImportFailedPrefix = "离线授权文件导入失败："
        static let licenseOnlineFailedPrefix = "在线校验失败："
        static let licenseTokenFailedPrefix = "离线授权失败："
        static let licenseNoPrivateKey = "客户端不会保存私钥；签发、撤销和套餐权限由后端决定。"
    }

    enum Settings {
        static let title = "设置"
        static let terminal = "终端"
        static let terminalDescription = "会话侧边栏、终端显示、输入和交互偏好。"
        static let terminalTheme = "终端主题"
        static let terminalThemeDescription = "终端配色、主题库、导入主题和预览。"
        static let aiAndAgent = "AI 与执行"
        static let aiAndAgentDescription = "模型配置、命令确认和独立任务/可见终端执行策略。"
        static let files = "文件"
        static let filesDescription = "内置 Files、SCP 传输和目录跟随行为。"
        static let metrics = "看板"
        static let metricsDescription = "远端设备指标采集、刷新节奏和 Linux 兼容策略。"
        static let updates = "更新"
        static let updatesDescription = "检查 Stacio 更新并选择 Stable 或 Beta 发布通道。"
        static let updateChannelGroupTitle = "更新通道"
        static let updateChannelGroupDescription = "通道只影响后续手动检查和下次启动时的版本探测。"
        static let updateChannel = "发布通道"
        static let updateChannelHelp = "Stable 提供稳定版本；Beta 可提前体验测试版本。切换通道不会自动下载或安装更新。"
        static func updateChannelCurrent(_ channel: String) -> String {
            "当前通道：\(channel)"
        }
        static let updateChannelConfirmTitle = "切换更新通道？"
        static func updateChannelConfirmMessage(from current: String, to proposed: String) -> String {
            "更新通道将从 \(current) 切换为 \(proposed)。切换后不会自动检查、下载或安装更新。"
        }
        static let updateChannelConfirmAction = "确认切换"
        static let security = "安全"
        static let securityDescription = "凭据、审计和高风险操作保护。"
        static let fontSize = "字体大小"
        static let terminalFontFamily = "字体"
        static let theme = "主题"
        static let sessionTabIconMode = "会话图标"
        static let sessionTabIconDefault = "默认"
        static let sessionTabIconOperatingSystem = "操作系统"
        static let sessionTabIconModeHelp = "默认使用 Stacio 的连接类型图标；操作系统模式会在 SSH 连接成功后自动识别远端系统并切换为对应图标。"
        static let sessionSidebarGroupTitle = "会话侧边栏"
        static let sessionSidebarGroupDescription = "控制会话列表中的自动分组和快捷入口。"
        static let sessionSidebarShowRecentSessions = "显示“最近使用”分组"
        static let sessionSidebarShowRecentSessionsHelp = "在会话侧边栏顶部显示最近打开的最多 5 个会话；这些只是快捷入口，不会复制、移动或删除原会话。"
        static let terminalHighlightTheme = "高亮主题"
        static let terminalCloseConfirmation = "关闭终端前确认"
        static let terminalSelectionAutoCopy = "选中自动复制"
        static let terminalControlScrollZoom = "Ctrl 滚轮缩放字体"
        static let terminalGeneralGroupTitle = "常规"
        static let terminalGeneralGroupDescription = "控制终端缓冲、渲染、留白、行号、时间戳和粘贴保护。"
        static let terminalScrollbackLines = "滚动缓冲行数"
        static let terminalScrollbackLinesHelp = "保留可回滚查看的历史输出行数；数值越大，长时间会话可查看的内容越多。"
        static let terminalKeepAliveInterval = "保活间隔（秒）"
        static let terminalKeepAliveIntervalHelp = "SSH 空闲时发送保活探测，降低网络设备断开连接的概率；设为 0 表示关闭。"
        static let terminalX11Display = "X11 DISPLAY"
        static let terminalX11DisplayHelp = "为需要 X11 转发的远程程序指定 DISPLAY；macOS 通常需要先启动 XQuartz。"
        static let terminalHardwareAcceleration = "硬件加速"
        static let terminalHardwareAccelerationHelp = "使用 GPU 加速终端绘制，提升高频输出和大屏滚动时的渲染流畅度。"
        static let terminalWorkspacePadding = "显示工作区留白"
        static let terminalWorkspacePaddingHelp = "在终端内容边缘保留少量空隙，让提示符、输出和选择区域不贴边。"
        static let terminalLineNumbers = "显示行号"
        static let terminalLineNumbersHelp = "在终端左侧显示输出行号，便于定位日志、错误堆栈和 AI 引用的行。"
        static let terminalTimestamps = "显示时间戳"
        static let terminalTimestampsHelp = "在终端侧栏显示每行输出时间，方便排查命令耗时和远端响应顺序。"
        static let terminalTimestampMilliseconds = "显示毫秒"
        static let terminalTimestampMillisecondsHelp = "将时间戳精度提升到毫秒，适合观察快速连续输出和交互响应。"
        static let terminalMultiLinePasteConfirmation = "多行粘贴前确认"
        static let terminalMultiLinePasteConfirmationHelp = "粘贴多行命令前弹出确认，避免误把脚本或换行内容直接执行。"
        static let terminalPasteImageAsPath = "图片粘贴为路径"
        static let terminalPasteImageAsPathHelp = "粘贴图片或图片文件时插入本地可读取路径，便于上传、分析或交给命令处理。"
        static let terminalAltAsMeta = "Option 作为 Meta"
        static let terminalAltAsMetaHelp = "将 Option 键作为终端 Meta 修饰键发送，适配 Emacs、Readline 和部分远程快捷键。"
        static let terminalMacIMECompatibility = "macOS 输入法兼容"
        static let terminalMacIMECompatibilityHelp = "优化中文等输入法的组合输入流程，减少候选词确认和终端快捷键之间的冲突。"
        static let terminalCommandSuggestion = "联想补全"
        static let terminalCommandSuggestionHistoryMinLength = "历史记录最小字数限制"
        static let terminalCommandSuggestionHistoryMaxLength = "历史记录最大字数限制"
        static let terminalCommandSuggestionWordSeparators = "单词分隔符"
        static let terminalDuplicateSessionCommandDelay = "复制后执行命令延迟（ms）"
        static let terminalCommandCompletionNotification = "长命令结束后通知"
        static let terminalCommandCompletionNotificationThreshold = "通知阈值（秒）"
        static let terminalCursorStyle = "光标样式"
        static let terminalCursorBlock = "块"
        static let terminalCursorBar = "竖线"
        static let terminalCursorUnderline = "下划线"
        static let terminalCursorBlink = "光标闪烁"
        static let terminalRightClickBehavior = "右键行为"
        static let terminalRightClickPaste = "粘贴"
        static let terminalRightClickMenu = "菜单"
        static let terminalRightClickNone = "无操作"
        static let terminalHighlightLevel = "高亮级别"
        static let terminalHighlightOff = "关闭"
        static let terminalHighlightANSI = "ANSI"
        static let terminalHighlightEnhanced = "命令增强"
        static let terminalRichHighlighting = "丰富高亮"
        static let terminalHighlightHelp = "关闭：不做 Stacio 显示高亮。ANSI：保留终端原生颜色并突出提示符。命令增强：在 ANSI 基础上识别命令、路径、IP、时间、错误和 Git 等输出。"
        static let terminalRichHighlightingHelp = "丰富高亮会扩展变量、字符串、权限等细节；终端记录、AI 上下文和广播仍保留原始文本。"
        static let customTheme = "自定义"
        static let importTerminalTheme = "导入主题..."
        static let terminalThemeImportedPrefix = "已导入"
        static let terminalThemeImportHint = "支持 Kitty、Ghostty、Alacritty、WezTerm、Windows Terminal、iTerm2 和 Stacio 主题文件。"
        static let terminalThemeNoCustomTheme = "尚未导入自定义主题"
        static let terminalThemeModeGroupTitle = "主题模式"
        static let terminalThemeModeGroupDescription = "选择终端配色跟随系统、浅色、深色或自定义导入主题。"
        static let terminalThemeSystemAdaptiveName = "系统自适应"
        static let terminalThemeSystemAdaptiveSource = "macOS"
        static let terminalThemeSystemAdaptiveMetadata = "跟随 macOS 浅色/深色外观\n保留原生文本、背景和选区颜色"
        static let terminalThemeLibraryGroupTitle = "主题库"
        static let terminalThemeLibraryGroupDescription = "像终端抽屉一样直接比较多套配色，选择后立刻应用到当前终端预览。"
        static let terminalAppearanceGroupTitle = "字体与光标"
        static let terminalAppearanceGroupDescription = "控制终端字体、会话图标、光标和命令高亮级别。"
        static let terminalCommandInputGroupTitle = "命令输入"
        static let terminalCommandInputGroupDescription = "配置命令联想、历史候选和终端单词边界。"
        static let terminalCommandSuggestionHelp = "输入命令时会立即显示基于历史记录和内置命令的候选列表；Tab 接受当前候选。"
        static let terminalBehaviorGroupTitle = "终端行为"
        static let terminalBehaviorGroupDescription = "控制关闭确认等会影响日常操作节奏的偏好。"
        static let system = "跟随系统"
        static let light = "浅色"
        static let dark = "深色"
        static let preview = "预览"
        static let terminalPreview = "Stacio 终端会实时应用字体与主题"
        static let provider = "提供商"
        static let baseURL = "Base URL"
        static let model = "模型"
        static let apiKey = "API Key"
        static let aiMaxRetryCount = "失败重试"
        static let aiRequestTimeoutSeconds = "请求超时"
        static let aiUserAgent = "User-Agent"
        static let aiTestConnection = "测试连接"
        static let aiConnectionReady = "填写配置后可测试模型接口。"
        static let aiConnectionTesting = "正在测试连接..."
        static let aiConnectionSuccess = "连接成功，模型已响应。"
        static let aiRulesConnectionSuccess = "Stacio 规则模式已可用，无需模型接口。"
        static let aiConnectionFailedPrefix = "连接失败："
        static let aiStatusGroupTitle = "当前配置"
        static let aiStatusGroupDescription = "快速确认 AI 来源、命令审批和执行方式。"
        static let aiProviderGroupTitle = "模型接口"
        static let aiProviderGroupDescription = "选择模型接口提供商后，Stacio 会同步填入对应 Base URL、默认模型和模型目录建议。"
        static let aiPresetGroupTitle = "快速模板"
        static let aiPresetGroupDescription = "一键填入常见 OpenAI-compatible 本地模型服务，填好后仍可手动调整模型名。"
        static let aiPresetOllama = "Ollama 本地"
        static let aiPresetLMStudio = "LM Studio"
        static let aiPresetOpenAI = "OpenAI"
        static let aiPresetDeepSeek = "DeepSeek"
        static let aiPresetOpenRouter = "OpenRouter"
        static let aiPresetQwen = "Qwen"
        static let aiPresetKimi = "Kimi"
        static let aiPresetHelp = "模板只写入 Base URL 和模型名，不会改写 Stacio 凭据库中的 API Key；本地服务通常允许空 Key。"
        static let aiModelCatalogGroupTitle = "模型目录"
        static let aiModelCatalogGroupDescription = "从当前供应商的建议模型、已刷新模型或本地常用模型中选择；推理强度和协议会随请求一起应用。"
        static let aiModelCatalog = "模型列表"
        static let aiRefreshModels = "刷新模型"
        static let aiAddCustomModel = "添加当前模型"
        static let aiCustomModelListEmpty = "尚未添加模型；填写模型名后点击添加。"
        static let aiRemoveCustomModel = "移除模型"
        static let aiReasoningEffort = "推理强度"
        static let aiCompatibilityProtocol = "兼容协议"
        static let aiModelCatalogHelp = "刷新会读取当前供应商的 OpenAI-compatible /models 接口；本地列表保存在本机设置中，不包含 API Key。"
        static let aiExecutionGroupTitle = "执行与审批"
        static let aiExecutionGroupDescription = "控制 AI 和外部 Agent 何时能写入终端，以及执行过程显示在哪里。"
        static let aiConversationHistoryGroupTitle = "对话历史"
        static let aiConversationHistoryGroupDescription = "AI 助手按终端 runtimeID 在本机 SQLite 保存最近 30 条历史；不会上传云端。"
        static let clearAIConversationHistory = "清除 AI 对话历史"
        static let aiConversationHistoryHelp = "会清除所有终端会话的 AI 助手历史，包括用户消息、AI 回复、命令卡片状态和执行结果摘要；不会清除会话、凭据或任务审计。"
        static let aiConversationHistoryCleared = "AI 对话历史已清除。"
        static let aiConversationHistoryUnavailable = "AI 对话历史存储不可用。"
        static let aiAutoRunProposedCommands = "AI 回复命令后自动进入审批/执行"
        static let agentCommandAllowPatterns = "自动放行模式"
        static let agentCommandDenyPatterns = "禁止模式"
        static let agentCommandPatternPlaceholder = "每行一个命令片段，例如 systemctl status"
        static let agentCommandPatternHelp = "按行填写命令模式，大小写不敏感，并从命令开头匹配；sudo/env 等包装器会自动跳过。禁止模式优先于自动放行；生产环境和会话强制确认仍会覆盖自动放行。"
        static let agentBridgeGroupTitle = "Agent Bridge"
        static let agentBridgeGroupDescription = "外部 Codex、CLI 或自动化工具通过 Stacio Agent Bridge 使用当前打开的终端。"
        static let agentBridgeSocket = "Socket"
        static let agentBridgeHint = "CLI 示例：stacio agent sessions，然后 stacio agent run --runtime <runtimeID> --command \"uptime\" --follow（stacio 仍作为兼容命令保留）"
        static let copySocketPath = "复制 Socket 路径"
        static let aiProviderSummaryPrefix = "AI 来源"
        static let aiApprovalSummaryPrefix = "审批策略"
        static let aiExecutionSummaryPrefix = "执行方式"
        static let aiProviderHelp = "OpenAI、DeepSeek、OpenRouter、Qwen、Kimi、Ollama 和 LM Studio 都走 OpenAI-compatible 通道；选择供应商后仍可手动微调 Base URL 和模型名。"
        static let aiRequestAdvancedHelp = "失败重试只用于超时、限流和服务端瞬时错误；鉴权失败、模型不存在等配置错误不会重复请求。User-Agent 可用于代理网关识别 Stacio 流量。"
        static let aiSettingsTabModels = "模型"
        static let aiSettingsTabContext = "上下文"
        static let aiSettingsTabExecutionPermissions = "执行与权限"
        static let aiSettingsTabHistory = "历史"
        static let addAIProviderTitle = "添加模型供应商"
        static let addAIProviderDescription = "填写 Base URL 和 API Key 后可以立即拉取模型；失败时也可以保存为未验证供应商。"
        static let addAIProviderTemplate = "供应商模板"
        static let addAIProviderDisplayName = "显示名称"
        static let addAIProviderFetchModels = "连接并获取模型"
        static let addAIProviderSave = "保存供应商"
        static let addAIProviderCancel = "取消"
        static let addAIProviderAddManualModel = "添加模型"
        static let addAIProviderModelSearch = "搜索模型"
        static let addAIProviderNoModels = "尚未获取模型。可先连接获取，失败后也可保存为未验证供应商。"
        static let addAIProviderNoMatchingModels = "没有匹配的模型。"
        static let addAIProviderReady = "填写供应商信息后获取模型。"
        static let addAIProviderFetching = "正在获取模型..."
        static let addAIProviderFetchSucceeded = "已获取模型。"
        static let addAIProviderFetchFailedPrefix = "获取模型失败："
        static let addAIProviderSaved = "供应商已保存。"
        static let addAIProviderSaveFailedPrefix = "保存失败："
        static let addAIProviderInvalidRequiredFields = "请填写显示名称和有效 Base URL。"
        static let addAIProviderDefaultRequired = "已有启用模型时必须选择默认模型。"
        static let aiContextGroupTitle = "终端上下文"
        static let aiContextGroupDescription = "控制 AI 请求附带多少终端输出，减少长日志导致的等待，同时保留必要排障上下文。"
        static let aiIncludeRecentTerminalTranscript = "附带最近终端输出"
        static let aiContextCharacterLimit = "上下文字符上限"
        static let aiContextHelp = "关闭后 AI 只收到当前终端标题、目录和你的问题。模型的上下文容量和推理强度请在模型管理中查看或配置。"
        static let aiExecutionHelp = "AI 命令会直接写入当前终端标签页，沿用现有 SSH 或本地终端会话，并把执行过程同步到终端。自动执行仍会遵守全局与会话审批策略。"
        static let confirmationPolicy = "命令确认"
        static let executionMode = "执行方式"
        static let filesDirectoryFollowDefault = "默认开启目录跟随"
        static let filesDirectoryFollowHelp = "新打开的 Files 面板会跟随当前远程终端的 cd 目录变化；面板内仍可临时关闭。"
        static let filesShowHiddenFilesByDefault = "默认显示隐藏文件"
        static let filesShowHiddenFilesHelp = "新打开的 Files 面板会按此默认值显示或隐藏 .env、.ssh、.config 等 dotfile；面板工具栏可临时切换。"
        static let filesRemoteEditAutoDetectChanges = "检测本地编辑副本变化"
        static let filesRemoteEditAutoDetectHelp = "外部编辑器保存 Remote Edit 本地副本后，Files 面板可提示并通过传输队列同步；不会在无提示情况下直接覆盖远端文件。"
        static let filesTransferConflictPolicy = "传输冲突策略"
        static let filesTransferQueueVisibleByDefault = "默认显示传输队列"
        static let filesTransferPolicyHelp = "冲突策略只作用于 Stacio Files 传输；默认每次询问，选择保留、覆盖、重命名或跳过后会直接用于新传输。"
        static let filesCacheGroupTitle = "缓存维护"
        static let filesCacheGroupDescription = "清除 Stacio 自建的本地编辑缓存和临时远端文件缓存。"
        static let filesCacheSizePrefix = "当前缓存占用"
        static func filesCacheDirtySummary(dirtyItemCount: Int) -> String {
            "未保存远程编辑：\(dirtyItemCount) 项"
        }
        static let filesCacheHelp = "仅清除 Remote Edit 本地副本、StacioRemoteFileCreate 和 StacioRemoteEditCache 等 Stacio 自建缓存目录；旧 Stacio 缓存名仅用于兼容清理，不会触碰真实文件、下载目录、会话数据库或凭据。"
        static let clearCache = "清除缓存..."
        static let clearCacheConfirmTitle = "清除 Stacio 缓存？"
        static let clearCacheCompletedTitle = "缓存已清除"
        static func clearCacheConfirmMessage(cacheSize: String, dirtyItemCount: Int) -> String {
            var lines = [
                "将清除 Remote Edit 本地副本，以及 StacioRemoteFileCreate / StacioRemoteEditCache 等 Stacio 自建临时缓存。",
                "当前缓存占用：\(cacheSize)。",
                "不会删除用户真实文件、下载目录、会话数据库或凭据。"
            ]
            if dirtyItemCount > 0 {
                lines.append("警告：有 \(dirtyItemCount) 项未保存的远程编辑改动将丢失。")
            }
            return lines.joined(separator: "\n\n")
        }
        static func clearCacheCompletedMessage(cacheSize: String) -> String {
            "已清除 \(cacheSize) 缓存。"
        }
        static let filesStatusGroupTitle = "当前默认"
        static let filesStatusGroupDescription = "查看新建 Files 面板会继承的默认行为。"
        static let filesNavigationGroupTitle = "目录与传输"
        static let filesNavigationGroupDescription = "Stacio 使用内置 SSH/SCP 和 Files 面板处理远程目录、预览和传输队列。"
        static let filesDirectoryFollowSummaryPrefix = "目录跟随"
        static let filesHiddenFilesSummaryPrefix = "隐藏文件"
        static let filesRemoteEditAutoDetectSummaryPrefix = "Remote Edit 检测"
        static let filesConflictPolicySummaryPrefix = "冲突策略"
        static let filesTransferQueueSummaryPrefix = "传输队列"
        static let metricsStatusGroupTitle = "采集状态"
        static let metricsStatusGroupDescription = "控制 SSH 设备看板采集间隔和采集失败后的显示策略。"
        static let metricsCollectionGroupTitle = "刷新与失败处理"
        static let metricsCollectionGroupDescription = "控制 Stacio 通过远端探针采集 CPU、内存、网卡和磁盘指标的节奏。"
        static let metricsDisplayGroupTitle = "显示内容"
        static let metricsDisplayGroupDescription = "决定 SSH 设备看板默认展示哪些模块，以及曲线和磁盘列表保留多少信息。"
        static let metricsCompatibilityGroupTitle = "兼容与过滤"
        static let metricsCompatibilityGroupDescription = "面向 CentOS/RHEL、Debian/Ubuntu、Alpine/BusyBox 和容器化主机，减少无关接口干扰。"
        static let metricsAlertsGroupTitle = "告警阈值"
        static let metricsAlertsGroupDescription = "当 CPU、内存或磁盘连续超过阈值时，通过 macOS 通知提醒并可点击回到对应会话看板。"
        static let deviceMetricsRefreshIntervalSeconds = "刷新间隔"
        static let deviceMetricsKeepLastSnapshotOnFailure = "失败时保留上次成功数据"
        static let deviceMetricsShowNetworkSection = "显示网络模块"
        static let deviceMetricsShowDiskSection = "显示磁盘模块"
        static let deviceMetricsDiskMountLimit = "磁盘显示数量"
        static let deviceMetricsHideVirtualNetworkInterfaces = "自动隐藏虚拟/容器网卡"
        static let deviceMetricsHistorySampleCount = "曲线采样点"
        static let deviceMetricsAlertEnabled = "启用设备指标告警"
        static let deviceMetricsCPUAlertThresholdPercent = "CPU 阈值（%）"
        static let deviceMetricsMemoryAlertThresholdPercent = "内存阈值（%）"
        static let deviceMetricsDiskAlertThresholdPercent = "磁盘阈值（%）"
        static let deviceMetricsAlertConsecutiveRefreshCount = "连续次数"
        static let metricsCollectionSummaryPrefix = "采集"
        static let metricsDisplaySummaryPrefix = "显示"
        static let metricsRefreshHelp = "刷新间隔 1-30 秒；内网或轻量主机可保持 2 秒，跨地域、老系统或 BusyBox 环境建议调高，避免频繁探针对终端会话造成抖动。"
        static let metricsModuleVisibilityHelp = "网络和磁盘模块关闭后不会占用看板空间。"
        static let metricsDisplayLimitsHelp = "磁盘显示数量 1-20 个；曲线采样点 3-240 个，数值越大历史更长但刷新和布局计算会更重。"
        static let metricsCompatibilityHelp = "兼容探针覆盖 CentOS/RHEL 6/7/8/9、Rocky、Alma、Fedora、Ubuntu、Debian、Alpine/BusyBox、openSUSE 等新老版本；优先读取 /proc/stat、/proc/meminfo、/proc/net/dev、/proc/mounts，并兼容 df -PT/-P/-k 输出。"
        static let metricsAlertNotificationHelp = "通知权限只会在首次真正需要发送告警时请求，拒绝后不会反复打扰。"
        static let metricsAlertThresholdHelp = "阈值范围 0-100%；连续次数范围 1-10 次。"
        static let enabled = "开启"
        static let disabled = "关闭"
        static let securityStatusGroupTitle = "安全状态"
        static let securityStatusGroupDescription = "快速确认命令审批、凭据存储和本地审计。"
        static let securityApprovalGroupTitle = "命令审批"
        static let securityApprovalGroupDescription = "审批策略同时作用于内置 AI 助手、Codex/Agent Bridge 和外部自动化写入终端。"
        static let securityAuditGroupTitle = "凭据与审计"
        static let securityAuditGroupDescription = "控制 Diagnostics 默认读取与导出的审计记录和应用日志范围。"
        static let securityApprovalSummaryPrefix = "命令审批"
        static let securityCredentialSummary = "凭据库：Stacio 本地凭据库"
        static let securityAuditSummary = "本地审计：Agent 操作记录"
        static let securityAuditHelp = "审批、拒绝、取消和执行结果会用于本地追踪；诊断包导出会再次脱敏，并按这里的数量限制读取最近记录。"
        static let diagnosticsAuditExportLimit = "审计导出条数"
        static let diagnosticsAppLogLineLimit = "日志导出行数"
        static let diagnosticsIncludeAppLogs = "诊断包包含应用日志"
        static let diagnosticsExportLimitHelp = "审计条数会同时作用于 MultiExec 和 AI/Agent 记录；日志行数设为 0 时，导出诊断包仍保留 appLogs 字段但内容为空。"
        static let securityCommandPolicyHelp = "控制内置 AI 和外部 Codex/Agent 写入终端前的全局审批策略。低风险自动放行只读和普通写入命令，网络与破坏性命令仍需确认；禁止模式会优先生效。"
        static let sessionPolicyGroupTitle = "会话策略覆盖"
        static let sessionPolicyGroupDescription = "解释全局设置、会话环境和单会话 AI 执行策略之间的优先级。"
        static let sessionPolicyOverrideSummary = "全局命令确认是默认规则；生产环境强制确认；会话 AI 执行策略可进一步设为禁用、命令卡、只读自动或每次确认。"
        static let sessionPolicyEntry = "在新建/编辑会话里配置环境与 AI 执行策略；保存后 Agent Bridge、内置 AI 助手和后台任务都会读取同一套策略。"
        static let credentialCenterGroupTitle = "凭据中心"
        static let credentialCenterGroupDescription = "查看 Stacio 数据库中的凭据引用，删除失效引用时不会读取或展示本地凭据库密钥内容。"
        static let credentialCenterRefresh = "刷新"
        static let credentialCenterDelete = "删除引用"
        static let credentialCenterAddPassword = "添加密码凭据"
        static let credentialCenterAddPrivateKeyPassphrase = "添加私钥口令"
        static let credentialCenterAddToken = "添加 Token"
        static let credentialCenterNewLabel = "标签"
        static let credentialCenterNewAccount = "账户"
        static let credentialCenterNewSecret = "密钥内容"
        static let credentialCenterNewLabelPlaceholder = "例如 生产 SSH"
        static let credentialCenterNewAccountPlaceholder = "例如 root@prod.example.com"
        static let credentialCenterNewSecretPlaceholder = "只写入 Stacio 本地凭据库"
        static let credentialCenterSavedPrefix = "已保存凭据引用："
        static let credentialCenterInputRequired = "填写账户和密钥内容后可添加。"
        static let credentialCenterListHelp = "列表只显示标签、类型和账户引用，不会显示任何 secret。"
        static let credentialCenterSecretHelp = "新增密码、私钥口令或 token 时 secret 只写入 Stacio 本地凭据库，不会显示在列表、摘要或诊断导出中。"
        static let credentialCenterEmpty = "暂无凭据引用"
        static let credentialCenterUnavailable = "凭据中心不可用"
        static let credentialCenterEmptySummary = "0 个凭据引用 · Stacio 不会在设置页展示任何 secret。"
        static let securityStorageGroupTitle = "本地存储"
        static let securityStorageGroupDescription = "这些路径用于定位 Stacio 本地数据库、审计记录和应用日志，便于排障或备份。"
        static let applicationSupport = "App Support"
        static let database = "数据库"
        static let appLog = "日志"
        static let copyPath = "复制路径"
        static let portDeskRules = "Stacio 规则"
        static let openAICompatible = "OpenAI Compatible"
        static let allowAllCommands = "全部自动"
        static let allowLowRisk = "低风险自动"
        static let requireEveryCommand = "每次确认"
        static let allowReadOnly = "只读自动"
        static let visibleTerminal = "可见终端"
        static let backgroundTask = "后台任务"
        static let comingSoon = "后续接入"
        static let filesPlaceholder = "Files 偏好会承接目录跟随、冲突处理和传输队列默认行为。"
        static let securityPlaceholder = "安全偏好会承接 Stacio 本地凭据库、审计日志和高风险命令升级确认。"
    }

    enum TerminalNotifications {
        static let commandCompletedTitle = "命令已完成"

        static func commandCompletedBody(command: String, sessionTitle: String) -> String {
            "\(command)\n\(sessionTitle)"
        }
    }

    enum DeviceMetricsAlerts {
        static let title = "设备指标告警"
    }

    enum Workbench {
        static let quickConnect = "快速连接"
        static let newSession = "新建会话"
        static let split = "分屏"
        static let splitTerminal = "终端分屏布局"
        static let splitSingleTerminal = "单终端模式"
        static let splitVertical = "垂直分屏"
        static let splitHorizontal = "水平分屏"
        static let splitGrid = "网格分屏"
        static let close = "关闭"
        static let closeCurrentTerminal = "关闭当前终端"
        static let importSessions = "导入会话"
        static let importSessionsTooltip = "从其他终端工具导入会话"
        static let importSessionsAccessibilityDescription = "导入外部会话"
        static let multiExec = "多执行"
        static let multiExecTooltip = "将输入同步执行到多个终端"
        static let multiExecAccessibilityDescription = "向多个终端同步执行"
        static let panels = "面板"
        static let panelsTooltip = "打开文件、浏览器、隧道、诊断、宏、历史命令、设备看板或 AI"
        static let tunnels = "隧道"
        static let deviceDashboard = "设备看板"
        static let toggleDeviceDashboard = "显示或隐藏当前 SSH 标签页设备看板"
        static let inspector = "检查器"
        static let sidebar = "侧边栏"
        static let toggleSidebar = "显示或隐藏侧边栏"
        static let localShellOpened = "本地 Shell 已打开"
        static let browserOpened = "内置浏览器已打开"
        static let localFilePaneOpened = "本地文件面板已打开"
        static let scpFilePaneOpened = "文件面板已打开"
        static let ftpFilePaneOpened = "内置 FTP 文件面板已打开"
        static let plaintextProtocolWarningTitle = "明文协议风险提示"
        static let plaintextProtocolWarningContinue = "继续打开"
        static let savedCredentialMissingTitle = "重新输入凭据"
        static let savedCredentialSaveAndRetry = "保存并重新连接"
        static let savedCredentialPasswordPlaceholder = "密码"
        static let savedCredentialPassphrasePlaceholder = "私钥口令"

        static func plaintextProtocolWarningMessage(protocolName: String) -> String {
            "\(protocolName) 不加密，建议只在受信任网络使用。是否继续打开此会话？"
        }

        static func savedPasswordCredentialMissingMessage(account: String) -> String {
            "该密码不在 Stacio 本地凭据库中。保存后会立即重新连接。"
        }

        static func savedPassphraseCredentialMissingMessage(account: String) -> String {
            "该私钥口令不在 Stacio 本地凭据库中。保存后会立即重新连接。"
        }
    }

    enum MultiExec {
        static let title = "多执行"
        static let message = "选择要广播输入的终端。"
        static let noTargets = "当前没有可执行的终端。"
        static let interactiveMessage = "选择要加入多执行分屏的可用终端。"
        static let requiresMultipleTargets = "多执行需要至少两个可用终端。"
        static let pauseTerminal = "暂停此终端同步"
        static let resumeTerminal = "恢复此终端同步"
        static let execute = "执行"
        static let start = "开始"
        static let command = "输入"
        static let snippets = "常用片段"
        static let chooseSnippet = "选择常用片段"
        static let macroPrefix = "宏："
        static let systemOverviewSnippet = "系统概览"
        static let diskUsageSnippet = "磁盘占用"
        static let currentUserSnippet = "当前用户"
        static let targets = "目标终端"
        static let production = "生产"
        static let development = "开发"
        static let executable = "可执行"
        static let unavailable = "不可用"
        static let productionConfirmation = "我确认要向生产终端广播输入"
        static let broadcastingWindowTitle = "Stacio - 正在广播"
    }

    enum Sidebar {
        static let sessions = "会话"
        static let recentSessions = "最近使用"
        static let favorites = "收藏"
        static let search = "搜索会话、主机或标签"
        static let importSessions = "导入"
        static let newGroup = "新建分组"
        static let expandAllGroups = "展开所有分组"
        static let collapseAllGroups = "折叠所有分组"
        static let renameGroup = "重命名分组"
        static let deleteGroup = "删除分组"
        static let exportGroupSessions = "导出分组会话"
        static let createGroupTitle = "新建分组"
        static let createRootGroupMessage = "输入新分组名称。"
        static let createChildGroupMessage = "在“%@”下创建子分组。"
        static let createGroupConfirm = "创建"
        static let renameGroupMessage = "输入“%@”的新名称。"
        static let renameGroupConfirm = "重命名"
        static let exportGroupSessionsSuggestedName = "%@ Sessions.json"
        static let duplicateSession = "复制会话"
        static let moveSession = "移动会话"
        static let exportSessions = "导出会话"
        static let executeSession = "执行"
        static let connectAs = "连接为..."
        static let pingHost = "Ping 主机"
        static let renameSession = "重命名会话"
        static let renameSessionConfirm = "重命名"
        static let saveSessionToFile = "导出会话"
        static let createDesktopShortcut = "创建桌面快捷方式"
        static let saveAsDefaultPreset = "将会话设置保存为默认预设"
        static let copySessionSettings = "复制会话设置"
        static let rootFolder = "根目录"
        static let moveSessionTitle = "移动会话"
        static let moveSessionMessage = "选择“%@”的新位置。"
        static let connectAsTitle = "连接为"
        static let connectAsMessage = "输入用于打开“%@”的用户名。保存的会话不会被修改。"
        static let renameSessionMessage = "输入“%@”的新名称。"
        static let pingProgressTitle = "正在 Ping 主机"
        static let pingProgressMessage = "正在持续 Ping %@，输出会实时显示，点击停止结束。"
        static let pingWaitingForOutput = "等待系统 ping 输出..."
        static let pingLiveStatus = "实时输出"
        static let pingReachableStatus = "可达"
        static let pingUnreachableStatus = "不可达"
        static let pingSuccessMessage = "%@ 可达，详细输出如下。"
        static let pingFailedMessage = "%@ 暂不可达，详细输出如下。"
        static let pingStopping = "正在停止 Ping..."
        static let pingSuccessTitle = "Ping 主机成功"
        static let pingFailedTitle = "Ping 主机失败"
        static let exportSessionsSuggestedName = "Stacio Sessions.json"
        static let exportCompleteTitle = "会话已导出"
        static let shortcutCreatedTitle = "桌面快捷方式已创建"
        static let defaultPresetSavedTitle = "默认预设已保存"
        static let defaultPresetSavedMessage = "已将“%@”的会话设置保存为默认预设。"
        static let settingsCopiedTitle = "会话设置已复制"
        static let settingsCopiedMessage = "已复制为 Stacio 会话 JSON。"
        static let editSession = "编辑会话"
        static let deleteSession = "删除会话"
    }

    enum SecureSessionTransfer {
        static let exportTitle = "导出加密会话"
        static let importTitle = "导入加密会话"
        static let exportAction = "导出"
        static let importAction = "导入"
        static let passphrasePlaceholder = "迁移口令"
        static let confirmPassphrasePlaceholder = "确认迁移口令"
        static let emptyPassphrase = "请输入迁移口令。"
        static let passphraseMismatch = "两次输入的迁移口令不一致。"
        static let invalidEnvelope = "所选文件不是有效的 Stacio 加密会话文件。"
        static let unsupportedFormat = "此加密会话文件使用了当前版本不支持的格式。"
        static let decryptionFailed = "迁移口令不正确，或文件已损坏。"
        static let invalidPayload = "加密会话文件中的会话数据无效。"
        static let credentialUnavailable = "无法读取该会话保存的凭据，未创建导出文件。"
        static let unsupportedCredentialKind = "该会话使用的凭据类型暂不支持安全迁移。"
        static let privateKeyUnavailable = "无法读取该会话的私钥文件，未创建导出文件。"
        static let privateKeyInstallFailed = "无法在本机安全保存导入的私钥。"
        static let keyDerivationFailed = "无法创建加密迁移文件。"
        static func exportMessage(_ sessionName: String) -> String {
            "为“\(sessionName)”设置迁移口令。它不会替代 SSH 密码；在另一台 Stacio 导入时需要输入一次。"
        }
        static func importMessage(_ sourceName: String) -> String {
            "输入“\(sourceName)”导出时设置的迁移口令。SSH 密码不会再次要求输入。"
        }
    }

    enum Inspector {
        static let files = "文件"
        static let transfers = "传输"
        static let tunnels = "隧道"
        static let browser = "浏览器"
        static let logs = "诊断"
        static let metrics = "看板"
        static let macros = "宏"
        static let commandHistory = "历史命令"
        static let commandHistoryTime = "时间"
        static let commandHistoryCommand = "命令"
        static let noCommandHistory = "暂无历史命令"
        static let pasteCommandToTerminal = "复制到终端"
    }

    enum TerminalMacro {
        static let title = "宏"
        static let nameColumn = "名称"
        static let commandCountColumn = "命令"
        static let updatedColumn = "更新"
        static let empty = "暂无 Macro"
        static let startRecording = "开始录制"
        static let stopRecording = "停止录制"
        static let play = "回放"
        static let rename = "重命名"
        static let delete = "删除"
        static let refresh = "刷新"
        static let saveRecordingTitle = "保存 Macro"
        static let macroNamePlaceholder = "Macro 名称"
        static let defaultMacroName = "新 Macro"
        static let noCommandsTitle = "没有记录到命令"
        static let noCommandsMessage = "录制期间只会保存实际提交的命令行。"
        static let noTerminalTitle = "没有可用终端"
        static let noTerminalMessage = "请选择一个本地或远程终端后再回放 Macro。"
        static let storageUnavailableTitle = "Macro 存储不可用"
        static let storageUnavailableMessage = "无法打开本机 SQLite 数据库，请稍后重试。"
        static let dangerousPlaybackTitle = "确认回放危险命令？"
        static let playAnyway = "继续回放"

        static func dangerousPlaybackMessage(name: String) -> String {
            "Macro「\(name)」包含危险命令，回放会写入当前终端并立即执行。"
        }

        static func commandCount(_ count: Int) -> String {
            "\(count) 条"
        }
    }

    enum AI {
        static let title = "AI"
        static let assistant = "AI 助手"
        static let ask = "询问"
        static let execute = "执行"
        static let copy = "复制"
        static let targetPicker = "选择终端"
        static let targetSearchPlaceholder = "搜索终端、目录或环境"
        static let targetSearchSummary = "可执行终端"
        static let noMatchingTargets = "没有匹配的终端"
        static let currentTarget = "当前终端"
        static let recentTarget = "最近终端"
        static let openTargets = "已打开终端"
        static let rulesMode = "规则建议"
        static let modelMode = "模型推理"
        static let collapse = "收起"
        static let run = "运行"
        static let skip = "跳过"
        static let edit = "编辑"
        static let askFromTerminal = "询问 AI"
        static let explainSelection = "解释选中内容"
        static let noTerminal = "请选择一个终端后再使用 AI 助手。"
        static let placeholder = "输入你想排查的问题"
        static let ready = "输入问题后，AI 会结合当前终端输出给出建议。"
        static let emptyQuestion = "请输入要排查的问题。"
        static let thinking = "正在分析当前终端上下文..."
        static let executing = "正在发送到终端..."
        static let sentToTerminal = "已发送到终端，执行过程会实时显示。"
        static let skippedCommand = "已跳过此命令。"
        static let taskOutputSummary = "输出摘要"
        static let taskControls = "控制"
        static let recentTasks = "最近任务"
        static let openTask = "查看"
        static let dismissTaskControl = "收起任务"
        static let pauseTask = "暂停"
        static let cancelTask = "取消"
        static let takeOverTask = "接管"
        static let confirmTaskComplete = "确认完成"
        static let continueTask = "继续"
        static let commandRiskReadOnly = "只读"
        static let commandRiskWrite = "写入"
        static let commandRiskNetwork = "网络"
        static let commandRiskDestructive = "危险"
    }

    enum Workspace {
        static let local = "本地"
        static let terminalUnavailable = "没有可操作的终端"
        static let start = "开始连接"
        static let startSubtitle = "启动一个本地终端，新增会话，或从左侧打开已保存会话。"
        static let startLocalTerminal = "启动本地终端"
        static let addSession = "新增会话"
        static let quickConnectPlaceholder = "例如 deploy@example.com:22"
        static let localTerminal = "本地终端"
        static let localFiles = "本地文件"
        static let files = "文件"
    }

    enum WorkspaceTabs {
        static let rename = "重命名选项卡"
        static let setColor = "设置选项卡颜色"
        static let duplicate = "复制选项卡"
        static let closeTab = "关闭选项卡"
        static let closeTabsToLeft = "关闭左侧所有选项卡"
        static let closeTabsToRight = "关闭右侧所有选项卡"
        static let closeOtherTabs = "关闭除此选项卡以外的所有选项卡"
        static let closeAllTabs = "关闭所有选项卡"
        static let detach = "分离选项卡"
        static let fullscreen = "全屏"
        static let pin = "固定此选项卡"
        static let unpin = "取消固定选项卡"
        static let saveTerminalOutput = "保存终端输出"
        static let printTerminalOutput = "打印终端输出"
        static let increaseFontSize = "增加字体大小"
        static let decreaseFontSize = "减小字体大小"
        static let renameMessage = "输入新的选项卡名称。"
        static let renameConfirm = "重命名"
        static let colorMessage = "为当前选项卡选择颜色。"
        static let colorConfirm = "应用"
        static let saveOutputSuggestedName = "终端输出.txt"
        static let saveOutputCompleteTitle = "终端输出已保存"
        static let noTerminalOutput = "当前选项卡没有终端输出。"
        static let operationFailedTitle = "选项卡操作失败"
        static let openLocalTerminalFailedTitle = "无法新建本地终端"
        static let outputSaveFailedTitle = "无法保存终端输出"
        static let outputPrintFailedTitle = "无法打印终端输出"
        static let duplicateUnsupported = "当前选项卡缺少可重新打开的连接信息，无法复制。"
        static let detachFailed = "无法分离当前选项卡。"
    }

    enum Graphics {
        static let title = "图形会话"
        static let endpoint = "目标"
        static let endpointDetail = "连接目标"
        static let adapter = "适配器"
        static let adapterPath = "适配器路径"
        static let status = "状态"
        static let runtimeStatus = "运行状态"
        static let launchArguments = "启动参数"
        static let copyDiagnostic = "复制诊断"
        static let missingAdapterSummary = "无法启动"
        static let runningSummary = "图形连接中"
        static let diagnosticSummary = "诊断模式"
        static let missingAdapter = "缺少 Stacio 打包的图形适配器"

        static func engine(_ protocolName: String) -> String {
            "内置 \(protocolName) 适配器"
        }

        static func externalClientEngine(_ clientName: String) -> String {
            "\(clientName) 外部客户端"
        }

        static func missingAdapter(_ protocolName: String) -> String {
            "缺少 Stacio 打包的 \(protocolName) 适配器"
        }

        static func adapterReady(_ protocolName: String) -> String {
            "已找到 Stacio 打包的 \(protocolName) 适配器"
        }

        static func diagnosticOnly(_ protocolName: String) -> String {
            "已找到 Stacio 打包的 \(protocolName) 适配器，当前版本仅提供诊断，尚未建立图形连接。"
        }

        static func adapterStarting(_ protocolName: String) -> String {
            return "已启动 Stacio 内置 \(protocolName) 适配器，正在建立图形连接。"
        }

        static func adapterLaunchFailed(_ protocolName: String, exitCode: Int32?, output: String) -> String {
            let title = "\(protocolName) 图形连接启动失败"
            var lines = [title]
            if let exitCode {
                lines.append("退出码 \(exitCode)")
            }
            let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedOutput.isEmpty {
                lines.append(trimmedOutput)
            }
            return lines.joined(separator: "\n")
        }

        static let adapterStopped = "已停止 Stacio 内置图形适配器。"
        static let invalidEndpoint = "图形会话端点无效"
    }

    enum Browser {
        static let address = "地址"
        static let go = "打开地址"
        static let invalidAddress = "地址无效"
    }

    enum TerminalLifecycle {
        static let closeTitle = "关闭终端？"
        static func closeMessage(title: String) -> String {
            "将关闭“\(title)”并结束当前连接。"
        }
        static let close = "关闭"
        static let reconnect = "重连"
        static let connecting = "正在连接..."
        static let connectionFailed = "连接失败"
        static let disconnected = "已断开"
        static let reconnecting = "正在重连..."
        static let reconnectUnavailable = "当前终端无法重连。"
        static func connectionFailedMessage(_ diagnostic: String) -> String {
            let trimmed = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? connectionFailed : "\(connectionFailed)：\(trimmed)"
        }

        static func disconnectedMessage(_ diagnostic: String) -> String {
            let trimmed = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? disconnected : "\(disconnected)：\(trimmed)"
        }

        static func connectionStartingPrompt(title: String) -> String {
            "\r\n正在连接 \(title)...\r\n"
        }

        static func stoppedSessionPrompt(diagnostic: String, connectionKind: RemoteTerminalConnectionKind) -> String {
            let trimmed = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
            let failureLine: String
            if trimmed.isEmpty {
                failureLine = "连接失败"
            } else if trimmed.hasPrefix("连接失败") || trimmed.hasPrefix("串口连接失败") {
                failureLine = trimmed
            } else {
                failureLine = "连接失败：\(trimmed)"
            }

            var lines = [
                "",
                "\u{001B}[31m\(failureLine)\u{001B}[0m",
                "------------------------------------------------------------",
                "会话已停止"
            ]
            if connectionKind == .serial {
                lines.append("按 <回车> 或 R 重新连接会话")
            } else {
                lines.append("按 <回车> 关闭标签页")
                lines.append("按 R 重新连接会话")
            }
            lines.append("按 S 保存终端输出到文件")
            lines.append("")
            return lines.joined(separator: "\r\n")
        }
    }

    enum TerminalOutputProtection {
        static let pause = "暂停输出"
        static let resume = "继续输出"
        static let paused = "输出已暂停"
        static let protected = "输出保护中"

        static func droppedBytes(_ count: UInt32) -> String {
            "已跳过 \(count) 字节"
        }

        static func bufferedBytes(_ count: UInt32) -> String {
            "已缓冲 \(count) 字节"
        }
    }

    enum TerminalSearch {
        static let placeholder = "搜索终端"
        static let previousMatch = "上一个匹配"
        static let nextMatch = "下一个匹配"

        static func matchSummary(current: Int, total: Int) -> String {
            "第 \(current) / 共 \(total) 个"
        }
    }

    enum Files {
        static let title = "文件"
        static let engine = ""
        static let ftpEngine = "内置 FTP"
        static let empty = "暂无远端文件"
        static let hiddenFilesFilteredEmpty = "隐藏文件已隐藏\n开启“显示隐藏文件”查看 . 开头项目"
        static let remoteFiles = "远端文件"
        static let remotePath = "远端路径"
        static let parentDirectory = "返回上一级目录"
        static let refresh = "刷新远端目录"
        static let retry = "重试"
        static let download = "下载所选项目"
        static let upload = "上传到当前目录"
        static let uploadFile = "上传文件"
        static let uploadFolder = "上传文件夹"
        static let showHiddenFiles = "显示隐藏文件"
        static let hideHiddenFiles = "隐藏隐藏文件"
        static let mkdir = "新建远端目录"
        static let newFile = "新建远端文件"
        static let rename = "重命名远端项目"
        static let deleteRemote = "删除远端项目"
        static let editLocalCopy = "编辑本地副本"
        static let saveEditedCopy = "保存编辑副本"
        static let syncChangedEdits = "同步已变更编辑文件"
        static let chmod = "修改远端权限"
        static let contextOpen = "打开"
        static let openWithDefaultTextEditor = "在 Stacio 编辑器中打开"
        static let openWith = "打开方式..."
        static let openWithDefaultApplication = "使用默认程序打开..."
        static let compareFiles = "比较文件..."
        static let contextDownload = "下载"
        static let contextDelete = "删除"
        static let contextRename = "重命名"
        static let copyPath = "复制文件路径"
        static let sendPathToTerminal = "将文件路径复制到终端"
        static let sendFileNameToTerminal = "将文件名复制到终端（单击鼠标中键）"
        static let properties = "属性"
        static let permissions = "权限"
        static let chooseDownloadDestination = "选择保存远端文件的位置。"
        static let chooseDownloadDirectory = "选择保存远端项目的本地文件夹。"
        static let chooseUploadFile = "选择要上传的本地文件。"
        static let chooseUploadFolder = "选择要上传的本地文件夹。"
        static let chooseOpenApplication = "选择用于打开远端文件本地副本的应用。"
        static let downloadFallbackName = "下载文件"
        static let newDirectoryTitle = "新建远端目录"
        static let newDirectoryMessage = "输入要在当前远端目录下创建的文件夹名称。"
        static let newDirectoryPlaceholder = "目录名称"
        static let newFileTitle = "新建远端文件"
        static let newFileMessage = "输入要在当前远端目录下创建的文件名称。"
        static let newFilePlaceholder = "文件名称"
        static let renameTitle = "重命名远端项目"
        static let renameMessage = "输入新的远端路径。"
        static let renamePlaceholder = "远端路径"
        static let deleteTitle = "删除远端项目？"
        static let deleteMessage = "该操作会从远端服务器删除所选项目。"
        static let chmodTitle = "修改远端权限"
        static let chmodMessage = "输入 chmod 八进制权限，例如 755。"
        static let chmodPlaceholder = "755"
        static let create = "创建"
        static let renameAction = "重命名"
        static let apply = "应用"
        static let refreshFailedTitle = "无法刷新远端目录"
        static let createDirectoryFailedTitle = "无法新建远端目录"
        static let createFileFailedTitle = "无法新建远端文件"
        static let renameFailedTitle = "无法重命名远端项目"
        static let deleteFailedTitle = "无法删除远端项目"
        static let openRemoteEditFailedTitle = "无法编辑远端文件"
        static let saveRemoteEditFailedTitle = "无法保存编辑副本"
        static let compareFilesFailedTitle = "无法比较远端文件"
        static let chmodFailedTitle = "无法修改远端权限"
        static let backupFailedTitle = "无法备份远端文件"
        static let restoreFailedTitle = "无法恢复备份文件"
        static let invalidListingMessage = "远端目录返回的数据无法解析。"
        static let unsafePathMessage = "远端路径不安全，操作已取消。"
        static let missingLiveSSHContext = "当前没有可用的 SSH 文件上下文，请先选中一个已连接的 SSH 终端。"
        static let operationFailedMessage = "远端文件操作失败，请检查权限或连接状态后再试。"
        static let compareUnavailableMessage = "未找到 FileMerge，请安装 Xcode 或使用下载后的本地文件进行比较。"
        static let compareRequiresTwoFilesMessage = "请选择两个远端文件进行比较。"
        static let conflictTitle = "文件已存在"
        static func conflictMessage(destinationPath: String) -> String {
            "目标位置已存在：\(destinationPath)"
        }
        static let overwrite = "覆盖"
        static let skip = "跳过"
        static let keepBoth = "保留两者"
        static let renameCopy = "重命名"
    }

    enum Transfers {
        static let title = "传输"
        static let engine = "SCP 传输"
        static let empty = "暂无传输任务"
        static let queue = "传输队列"
        static let upload = "上传"
        static let download = "下载"
        static let retry = "重试"
        static let cancel = "取消"
        static let pause = "暂停"
        static let resume = "恢复"
        static let restart = "重新开始"
        static let stop = "停止"
        static let clearFinished = "清理已结束"
        static let transferFailed = "传输失败"
        static let invalidSSHConfiguration = "SSH 配置无效"
        static let authenticationFailed = "认证失败"
        static let connectionTimedOut = "连接超时"
        static let hostKeyChanged = "主机密钥已变更"
        static let unknownHostKey = "未知主机密钥"
        static let completedNotificationTitle = "文件传输完成"
        static let failedNotificationTitle = "文件传输失败"
        static let notificationListTitle = "文件传输通知"
        static let notificationItemUnit = "项记录"
        static let notificationSize = "大小"
        static let notificationCompletedAt = "完成时间"
        static let notificationDuration = "用时"
        static let notificationAverageSpeed = "平均速率"
        static let completed = "已完成"
        static let failed = "失败"
        static let detailTitle = "任务详情"
        static let detailEmpty = "选择传输任务查看详情"
        static let detailJobID = "任务 ID"
        static let detailDirection = "方向"
        static let detailStatus = "状态"
        static let detailProgress = "进度"
        static let detailSource = "来源"
        static let detailDestination = "目标"
        static let detailDiagnostic = "诊断"
        static let detailLog = "传输日志"
        static let detailLogEmpty = "暂无传输日志"
        static let remainingPrefix = "剩余"

        static func completedNotificationBody(direction: String, fileName: String) -> String {
            "\(direction)“\(fileName)”已完成。"
        }

        static func failedNotificationBody(direction: String, fileName: String, diagnostic: String?) -> String {
            let summary = "\(direction)“\(fileName)”失败。"
            guard let diagnostic, diagnostic.isEmpty == false else { return summary }
            return "\(summary) \(diagnostic)"
        }

        static func status(_ rawStatus: String) -> String {
            switch rawStatus {
            case "queued":
                return "排队中"
            case "running":
                return "传输中"
            case "resuming":
                return "续传中"
            case "paused":
                return "已暂停"
            case "stopped":
                return "已停止"
            case "completed":
                return "已完成"
            case "failed":
                return "失败"
            case "canceled", "cancelled":
                return "已取消"
            default:
                return rawStatus
            }
        }
    }

    enum Tunnels {
        static let title = "隧道"
        static let engine = "内置 SSH 隧道"
        static let empty = "暂无隧道"
        static let table = "SSH 隧道"
        static let add = "新建隧道"
        static let edit = "编辑隧道"
        static let delete = "删除隧道"
        static let start = "启动"
        static let stop = "停止"
        static let ready = "就绪"
        static let addTitle = "新建隧道"
        static let editTitle = "编辑隧道"
        static let deleteOneTitle = "删除隧道？"
        static let deleteManyTitle = "删除隧道？"
        static let deleteOneMessage = "保存的隧道配置将被移除。"
        static let missingLiveSessionContext = "需要先打开一个 SSH 或 SCP 会话，再启动隧道。"
        static let quitWithRunningTitle = "仍有隧道在运行"
        static let quitWithRunningConfirm = "退出并停止"
        static func quitWithRunningMessage(count: Int) -> String {
            count == 1
                ? "退出 Stacio 会结束当前运行中的隧道。"
                : "退出 Stacio 会结束当前 \(count) 个运行中的隧道。"
        }
        static func deleteManyMessage(_ count: Int) -> String {
            "\(count) 个保存的隧道配置将被移除。"
        }

        static func detail(_ rawDetail: String) -> String {
            switch rawDetail {
            case "ready":
                return ready
            case "stopped":
                return "已停止"
            case "starting":
                return "启动中"
            case "running":
                return "运行中"
            case "failed":
                return "失败"
            case "missing_live_session_context":
                return missingLiveSessionContext
            default:
                if let liveSummary = liveRuntimeDetail(rawDetail) {
                    return liveSummary
                }
                return rawDetail
            }
        }

        private static func liveRuntimeDetail(_ rawDetail: String) -> String? {
            let parts = rawDetail.split(separator: " ").map(String.init)
            guard parts.first == "running" else {
                return nil
            }

            let values = Dictionary(
                uniqueKeysWithValues: parts.dropFirst().compactMap { part -> (String, String)? in
                    let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                    guard pair.count == 2 else {
                        return nil
                    }
                    return (pair[0], pair[1])
                }
            )
            guard let accepted = values["accepted"],
                  let active = values["active"],
                  let uploadBytes = UInt64(values["client_to_remote_bytes"] ?? ""),
                  let downloadBytes = UInt64(values["remote_to_client_bytes"] ?? "")
            else {
                return nil
            }

            return "运行中，接入 \(accepted)，活跃 \(active)，上行 \(byteCount(uploadBytes))，下行 \(byteCount(downloadBytes))"
        }

        private static func byteCount(_ bytes: UInt64) -> String {
            if bytes < 1_024 {
                return "\(bytes) 字节"
            }
            if bytes < 1_048_576 {
                return String(format: "%.1f KB", Double(bytes) / 1_024.0)
            }
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        }
    }

    enum SessionSettings {
        static let title = "会话设置"
        static let newSession = "新建会话"
        static let editSession = "编辑会话"
        static let name = "名称"
        static let host = "主机"
        static let port = "端口"
        static let devicePath = "设备路径"
        static let baudRate = "波特率"
        static let commonBaudRate = "常用波特率"
        static let autoBaudRate = "自动/不设置"
        static let serialDeviceProfile = "设备类型"
        static let serialProfileGeneric9600 = "通用网络设备（9600 8N1，无流控）"
        static let serialProfileGeneric115200 = "通用高速 Console（115200 8N1，无流控）"
        static let serialProfileInspur = "浪潮网络（9600 8N1）"
        static let serialProfileYuanmai = "元脉网络（9600 8N1）"
        static let serialProfileCisco = "思科 Cisco（9600 8N1）"
        static let serialProfileHuawei = "华为 Huawei（9600 8N1）"
        static let serialProfileH3C = "H3C（9600 8N1）"
        static let serialProfileRuijie = "锐捷 Ruijie（9600 8N1）"
        static let serialProfileBDCOM = "博达 BDCOM（9600 8N1）"
        static let serialProfileCustom = "自定义参数"
        static let dataBits = "数据位"
        static let stopBits = "停止位"
        static let parity = "校验位"
        static let flowControl = "流控"
        static let backspaceMode = "退格键"
        static let backspaceDelete = "DEL (0x7F)"
        static let backspaceControlH = "Ctrl+H (BS)"
        static let storageNote = "保存说明"
        static let none = "无"
        static let oddParity = "奇校验"
        static let evenParity = "偶校验"
        static let serialStorageHint = "网络设备预设会随会话保存；手工修改高级项后仍以当前参数连接。"
        static let url = "网址"
        static let localPath = "本地路径"
        static let user = "用户"
        static let auth = "认证"
        static let privateKey = "私钥"
        static let secret = "密钥"
        static let password = "密码"
        static let passphrase = "口令"
        static let tags = "标签"
        static let agent = "SSH 代理"
        static let passwordAuth = "密码"
        static let privateKeyAuth = "私钥"
        static let passwordOrPassphrase = "密码或口令"
        static let storedInKeychain = "已保存到 Stacio 凭据库"
        static let optionalPassphrase = "可选口令"
        static let optionalUser = "可选"
        static let optionalPassword = "可选密码"
        static let tagColor = "标签颜色"
        static let automation = "自动化"
        static let environment = "环境"
        static let aiExecutionPolicy = "AI 执行"
        static let environmentDevelopment = "开发"
        static let environmentStaging = "预发"
        static let environmentProduction = "生产"
        static let aiPolicyInherit = "跟随全局"
        static let aiPolicyDisabled = "禁止执行"
        static let aiPolicyCommandCard = "仅命令卡片"
        static let aiPolicyReadOnlyAuto = "只读自动"
        static let aiPolicyRequireEveryCommand = "每条确认"
        static let automationHint = "生产环境会强制保守审批；策略会覆盖全局 AI 执行设置。"
        static let startupActions = "连接后动作"
        static let startupCommand = "启动命令"
        static let postConnectScript = "连接脚本"
        static let environmentVariables = "环境变量"
        static let connectTimeoutSeconds = "连接超时"
        static let startupActionsHint = "连接脚本会在 SSH 终端就绪后自动写入；环境变量每行一个 KEY=value。"
        static let proxyJump = "跳板机"
        static let proxyJumpMode = "跳板方式"
        static let proxyJumpDisabled = "不使用"
        static let proxyJumpSavedSession = "已有会话"
        static let proxyJumpManual = "手动填写"
        static let proxyJumpSessionID = "会话 ID"
        static let proxyJumpCredentialID = "凭据 ID"
        static let proxyJumpHint = "仅 SSH/SCP 会话使用；跳板机和目标主机都会按普通 SSH 主机密钥流程确认。"

        static func unsupportedProtocol(_ protocolName: String) -> String {
            "当前 Stacio 版本暂不支持 \(protocolName) 会话。"
        }
    }

    enum SessionValidation {
        static let missingName = "名称不能为空。"
        static let missingHost = "主机不能为空。"
        static let invalidPort = "端口必须在 1 到 65535 之间。"
        static let passwordRequired = "使用密码认证时必须填写密码。"
        static let privateKeyPathRequired = "使用私钥认证时必须填写私钥路径。"
        static let privateKeyPassphraseRequired = "无法复用已保存凭据，请重新填写口令。"
    }

    enum SessionErrors {
        static let createTitle = "无法创建会话"
        static let updateTitle = "无法更新会话"
        static let duplicateTitle = "无法复制会话"
        static let moveTitle = "无法移动会话"
        static let exportTitle = "无法导出会话"
        static let createFolderTitle = "无法创建分组"
        static let updateFolderTitle = "无法更新分组"
        static let deleteFolderTitle = "无法删除分组"
        static let pingTitle = "无法 Ping 主机"
        static let shortcutTitle = "无法创建桌面快捷方式"
        static let defaultPresetTitle = "无法保存默认预设"
        static let copySettingsTitle = "无法复制会话设置"
        static let deleteTitle = "无法删除会话"
        static let saveTitle = "无法保存会话"
        static let openTitle = "无法打开会话"
        static let credentialStorageUnavailable = "凭据存储不可用，请重新打开 Stacio 后再试。"
        static let keychainNotFound = "在 Stacio 凭据库中找不到已保存凭据，请重新输入密钥并保存。"
        static let invalidSecretEncoding = "无法为 Stacio 凭据库编码该密钥。"
        static let keychainAccessDenied = "Stacio 凭据库无法读写，请检查本机文件权限后再试。"
        static let credentialVaultCorrupted = "Stacio 凭据库无法解密或格式异常，请重新保存该凭据。"
        static let createMessage = "Stacio 无法创建该保存会话，请检查会话信息后再试。"
        static let updateMessage = "Stacio 无法更新该保存会话，请检查会话信息后再试。"
        static let duplicateMessage = "Stacio 无法复制该保存会话，请稍后再试。"
        static let moveMessage = "Stacio 无法移动该保存会话，请稍后再试。"
        static let exportMessage = "Stacio 无法导出保存会话，请检查目标位置后再试。"
        static let createFolderMessage = "Stacio 无法创建该分组，请检查名称后再试。"
        static let updateFolderMessage = "Stacio 无法更新该分组，请稍后再试。"
        static let deleteFolderMessage = "Stacio 无法删除该分组，请稍后再试。"
        static let pingMessage = "Stacio 无法 Ping 该主机，请检查主机名和网络状态后再试。"
        static let shortcutMessage = "Stacio 无法创建桌面快捷方式，请检查目标位置权限后再试。"
        static let defaultPresetMessage = "Stacio 无法保存默认预设，请稍后再试。"
        static let copySettingsMessage = "Stacio 无法复制会话设置，请稍后再试。"
        static let deleteMessage = "Stacio 无法删除该保存会话，请稍后再试。"
        static let saveMessage = "Stacio 无法保存该会话，请检查会话信息后再试。"
        static let openMessage = "Stacio 无法打开该会话，请检查协议和连接信息后再试。"
    }

    enum DeleteSession {
        static let oneTitle = "删除会话？"
        static let manyTitle = "删除会话？"
        static let oneMessage = "保存的会话将被移除，并同时清除该会话的本地编辑缓存。Stacio 凭据库中的凭据不会被删除。"
        static func manyMessage(_ count: Int) -> String {
            "\(count) 个保存的会话将被移除，并同时清除这些会话的本地编辑缓存。Stacio 凭据库中的凭据不会被删除。"
        }
    }

    enum DeleteFolder {
        static let title = "删除分组？"
        static let deleteFolderAndSessions = "删除分组和会话"
        static let deleteFolderOnly = "仅删除分组"
        static func message(_ name: String, sessionCount: Int) -> String {
            "“\(name)”及其子分组中有 \(sessionCount) 个会话。是否同时删除这些会话？选择“仅删除分组”会将会话移动到根目录。"
        }
        static func emptyMessage(_ name: String) -> String {
            "将删除“\(name)”及其子分组结构。"
        }
    }

    enum QuickConnect {
        static let title = "快速连接"
        static let message = "输入 SSH 目标，例如 用户名@主机:22。"
        static let connect = "连接"
        static let placeholder = "用户名@主机:端口"
        static let target = "目标"
        static let saveAsSession = "连接成功后保存为会话"
        static let sessionNamePlaceholder = "默认使用 用户名@主机"
        static let missingCredentialReference = "使用密码或私钥口令认证时，必须先保存凭据。"
        static let missingPrivateKeyPath = "使用私钥认证时必须填写私钥路径。"
        static let failedTitle = "快速连接失败"
        static let failedMessage = "请检查连接目标、凭据和网络状态后重试。"
    }

    enum Import {
        static let chooseFile = "选择要导入的会话文件。"
        static let sourceTitle = "导入配置"
        static let sourceMessage = "请选择要导入的配置来源"
        static let chooseSourceAction = "选择文件"
        static let title = "导入会话"
        static let action = "导入"
        static let completeTitle = "导入完成"
        static let failedTitle = "导入失败"
        static let header = "名称\t文件夹\t协议\t目标\t状态"
        static let nameColumn = "名称"
        static let folderColumn = "文件夹"
        static let protocolColumn = "协议"
        static let targetColumn = "目标"
        static let statusColumn = "状态"
        static let warningsColumn = "警告"
        static let warnings = "警告"
        static let sensitiveWarningHidden = "已隐藏敏感字段"
        static let conflict = "冲突"
        static let new = "新增"
        static func sourceTypeLabel(_ sourceType: SessionImportSourceType) -> String {
            switch sourceType {
            case .csv:
                return "CSV 文件"
            case .legacyINI:
                return "Legacy INI 导出"
            case .stacioJSON:
                return "Stacio 会话 JSON"
            case .xShell:
                return "Xshell"
            case .mobaXterm:
                return "MobaXterm"
            case .windTerm:
                return "WindTerm"
            case .secureCRT:
                return "SecureCRT"
            case .finalShell:
                return "FinalShell"
            case .termius:
                return "Termius"
            case .electerm:
                return "Electerm"
            case .genericJSON:
                return "JSON"
            case .unknown:
                return "未知格式"
            }
        }

        static func previewMessage(sourceName: String, sourceType: SessionImportSourceType, importableCount: Int, conflictCount: UInt32) -> String {
            "\(sourceName) - \(sourceTypeLabel(sourceType))。\(importableCount) 个新增，\(conflictCount) 个冲突。"
        }
        static func resultMessage(imported: UInt32, skipped: UInt32, failed: UInt32) -> String {
            "\(imported) 个已导入，\(skipped) 个已跳过，\(failed) 个失败。"
        }
    }

    enum HostKey {
        static func unknownTitle(host: String) -> String {
            "信任 \(host) 的主机密钥？"
        }
        static func changedTitle(host: String) -> String {
            "\(host) 的主机密钥已变更"
        }
        static func unknownMessage(host: String, port: UInt16, fingerprint: String) -> String {
            """
            Stacio 尚未见过此主机密钥。

            主机：\(host):\(port)
            指纹：\(fingerprint)
            """
        }
        static func changedMessage(host: String, port: UInt16, previous: String, new: String) -> String {
            var lines = [
                "当前主机密钥与已信任的值不同。这可能来自服务器维护，也可能表示安全风险。",
                "",
                "主机：\(host):\(port)"
            ]
            if !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("旧指纹：\(previous)")
            }
            lines.append("新指纹：\(new)")
            return lines.joined(separator: "\n")
        }
        static let trust = "信任主机密钥"
        static let reject = "拒绝连接"
        static let trustNew = "信任新的主机密钥"
    }

    enum Diagnostics {
        static let title = "诊断"
        static let empty = "暂无诊断项"
        static let severity = "级别"
        static let message = "消息"
        static let export = "导出"
        static let exportSuggestedName = "Stacio Diagnostics.json"
        static let exportCompleteTitle = "诊断已导出"
        static let exportFailedTitle = "无法导出诊断"
        static let exportFailedMessage = "Stacio 无法写入诊断文件，请检查目标位置后再试。"
        static let info = "信息"
        static let warning = "警告"
        static let error = "错误"
        static let localPortCheck = "本地端口检查"
        static let host = "主机"
        static let port = "端口"
        static let check = "检查"
        static let invalidPort = "端口无效"
        static let redactedCredential = "[已隐藏凭据]"
        static let redactedPath = "[已隐藏路径]"
        static let multiExecAudit = "多执行审计"
        static let agentAudit = "AI/Agent 审计"
        static let auditScopeAll = "全部"
        static let auditScopeAgent = "AI"
        static let auditScopeMultiExec = "多执行"
        static let refreshAudit = "刷新"
        static let auditEmpty = "暂无审计记录"
        static let importReports = "导入报告"
        static let refreshImportReports = "刷新"
        static let importReportsEmpty = "暂无导入报告"
        static let appLogs = "应用日志"
        static let refreshAppLogs = "刷新"
        static let appLogsEmpty = "暂无应用日志"

        static func auditRequest(_ requestId: String) -> String {
            "request \(requestId)"
        }

        static func auditRuntime(_ runtimeId: String) -> String {
            "runtime \(runtimeId)"
        }

        static func auditTargets(_ count: UInt32) -> String {
            "目标 \(count)"
        }

        static func auditDelivery(sent: UInt32, failed: UInt32) -> String {
            "已发送 \(sent) / 失败 \(failed)"
        }

        static func importReportCounts(imported: UInt32, skipped: UInt32, failed: UInt32) -> String {
            "已导入 \(imported) / 已跳过 \(skipped) / 失败 \(failed)"
        }

        static func portReachable(host: String, port: UInt16) -> String {
            "\(host):\(port) 可连接"
        }

        static func portUnreachable(host: String, port: UInt16) -> String {
            "\(host):\(port) 不可连接"
        }
    }
}
