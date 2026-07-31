# Stacio Remote Text Editor 与 Files UI 稳定性 Runbook

版本：v1.0
最近更新：2026-07-31
适用范围：macOS AppKit `Files` 面板、内嵌 Remote Edit、独立 Remote Text Editor、Monaco/WKWebView 生命周期
状态：2026-07-31 黑屏、长时间加载和窗口拖拽后失刷问题的当前稳定性基线

> 目标：下次出现编辑器黑屏、空白、长时间加载、拖动分栏后才显示、窗口缩放后打不开或 UI 不刷新时，先按本文定位。不要从 `WorkspaceViewController`、`WorkbenchWindowController` 或文件传输链路开始大范围搜索。

## 1. 五分钟入口

权威源码与测试目录固定为 `/Users/mac/Documents/Stacio`。隐藏 Codex worktree 只用于对比，不在其中修改、测试或打包。

仓库的 `/docs/` 目录按项目策略被 `.gitignore` 整体忽略；本文已写入权威目录，但后续需要提交或交接时必须用显式路径确认并按项目流程显式纳入，不能只依赖普通 `git status`。

优先检查以下四个文件：

| 文件 | 责任 |
| --- | --- |
| `Stacio/Views/Files/RemoteTextEditorViewController.swift` | AppKit 容器、WKWebView、Monaco HTML/JS、加载握手、恢复、布局、保存和关闭状态。 |
| `Stacio/Views/Files/FilesViewController.swift` | Files 分栏、编辑器折叠/恢复、容器尺寸同步。 |
| `Tests/StacioAppTests/RemoteTextEditorViewControllerTests.swift` | 编辑器生命周期、真实 Monaco、布局、恢复、保存/关闭回归。 |
| `Tests/StacioAppTests/FilesViewControllerTests.swift` | Files 分栏、折叠/恢复和编辑器布局同步回归。 |

第一轮搜索直接使用稳定符号，避免搜索 `status`、`view`、`layout` 等宽泛词：

```bash
cd /Users/mac/Documents/Stacio
rg -n "loadMonacoEditorHTML|handleScriptMessage|workspaceReady|scheduleEditorLayoutIfNeeded|recoverMonacoReadinessIfNeeded|editorLiveResizeDidEnd|synchronizeLayoutAfterContainerChange" \
  Stacio/Views/Files/RemoteTextEditorViewController.swift \
  Stacio/Views/Files/FilesViewController.swift \
  Tests/StacioAppTests/RemoteTextEditorViewControllerTests.swift \
  Tests/StacioAppTests/FilesViewControllerTests.swift
```

## 2. 已知故障签名与根因

| 可见现象 | 优先判断 | 已知根因或高概率入口 |
| --- | --- | --- |
| 打开文件时短暂黑屏 | 加载遮罩是否仍覆盖 WKWebView | WebContent 首帧早于 Monaco 工作区完成；不能把 `WKNavigation.didFinish` 或 JS `ready` 当成可见就绪。 |
| 一直黑屏或一直“正在加载编辑器...” | 看 3 秒后是否自动恢复一次，之后是否出现“重新加载” | Monaco 资源、JS bridge、导航或 WebContent 进程未完成两阶段握手。 |
| 拖一下左侧 Files 分栏立刻显示 | 先看布局，不要先查 SSH/下载 | 编辑器经历过 `0 x 0`、折叠或离屏，恢复后尺寸与上次相同，旧的尺寸去重吞掉了必须执行的布局。 |
| 拖动整个窗口后文件再次打不开 | 看 live resize 期间是否尚未 `workspaceReady` | live resize、临时 detach/reattach 与 Monaco 初始化发生竞态，恢复动作必须延后到 resize 结束。 |
| 折叠编辑器再展开后空白 | 看 `restoreEmbeddedCapability()` | 恢复容器后必须调用 `synchronizeLayoutAfterContainerChange()`，即使尺寸看起来没变。 |
| 控制台出现 `ModelService: Cannot add model because it already exists!` | 看同 URI model 创建 | 同一个页面重复装载同 URI workspace 时必须先 `monaco.editor.getModel(uri)` 并复用。 |
| 重载后收到旧内容、旧 dirty 状态或旧 ready | 看 `pageLoadGeneration` | 前一页面的异步 bridge 消息或 JS 回调越过了重载边界。 |
| resize 时 CPU 升高或输入卡顿 | 看布局调用频率 | AppKit 每次布局和 JS 每次 resize 都同步调用 `editor.layout()`，缺少 runloop/rAF 合并。 |

## 3. 当前正确生命周期

正常路径必须保持为：

```text
Swift 创建页面 generation N
  -> WKWebView 导航完成（仅说明 HTML 完成，不代表编辑器可见）
  -> JS post("ready", generation N)
  -> Swift 标记 Monaco runtime ready，并调用 loadWorkspace
  -> JS 创建或复用 model、安装文档、更新 tabs/status
  -> JS post("workspaceReady", generation N, activeDocumentID, documentCount)
  -> Swift 校验 generation、activeDocumentID、documentCount
  -> 隐藏原生加载遮罩
  -> 强制安排一次 Monaco layout
```

失败路径必须保持有限：

```text
导航失败 / workspace JS 异常 / WebContent 终止 / 3 秒未 workspaceReady
  -> live resize 或离屏期间先等待
  -> 最多自动重载 1 次
  -> 只有新页面 workspaceReady 后恢复自动重载预算
  -> 连续失败显示“编辑器加载失败”与“重新加载”按钮
```

以下状态不能混用：

| 状态 | 含义 | 允许的 UI 行为 |
| --- | --- | --- |
| `isMonacoRuntimeReady` | Monaco runtime 已发送当前代 `ready` | 可以发送 `loadWorkspace`，但不能隐藏加载遮罩。 |
| `isEditorReady` | 当前 workspace 已回传并通过校验 | 可以隐藏遮罩、接收正常交互并执行布局。 |
| `monacoPageLoadGeneration` | 当前 WebKit 页面代次 | 所有 JS -> Swift 消息必须携带并匹配它。 |
| `monacoReadinessRecoveryReloadCount` | 当前连续失败的自动恢复次数 | 成功前最多为 1；只有 `workspaceReady` 才能清零。 |
| `forcePendingEditorLayoutRequest` | 即使尺寸相同也必须补布局 | `0 x 0`、展开、重挂、就绪和 resize 结束时必须保留。 |

Swift 内的 `documents`、`activeDocumentID`、dirty/save revision 是数据源。WebContent 重载只能重建渲染层，不能成为文档状态的数据源。

## 4. 代码定位图

### 4.1 Swift / AppKit

| 符号 | 作用 | 修改时必须保持 |
| --- | --- | --- |
| `RemoteTextEditorViewController.loadMonacoEditorHTML` | 创建新页面、递增 generation、显示遮罩、启动 watchdog | 新页面必须清空 runtime/editor ready，但不能丢 Swift 文档状态。 |
| `webView(_:didFinish:)` | 导航完成信号 | 只能继续 watchdog，不能在这里显示编辑器。 |
| `handleScriptMessage(_:)` | JS bridge 总入口 | 第一层必须拒绝不匹配的 `pageLoadGeneration`。 |
| `syncWorkspaceToWebView()` | 把 Swift workspace 送入 JS | JS 执行错误应立即进入有限恢复。 |
| `scheduleMonacoReadinessWatchdog()` | 处理没有 delegate 回调或没有 bridge 消息的卡死 | 当前宽限为 3 秒；live resize/离屏时不得误重载。 |
| `recoverMonacoReadinessIfNeeded()` | 统一恢复门禁 | 最多自动重载一次，不允许形成 reload loop。 |
| `webViewWebContentProcessDidTerminate(_:)` | WebContent 崩溃恢复 | 回到原生遮罩并走同一有限恢复路径。 |
| `scheduleEditorLayoutIfNeeded(force:)` | AppKit -> Monaco 布局桥 | 同一 runloop 合并；零尺寸时保留强制请求；不得触发页面重载。 |
| `editorLiveResizeDidStart/End()` | 窗口拖拽边界 | ready 时只补布局；unready 时在拖拽结束后恢复。 |
| `editorDidMoveToWindow(_:)` | 离屏/重挂恢复 | detach 期间不重载，重挂后按 ready 状态补布局或恢复。 |
| `RemoteTextEditorRootView` | 采集 AppKit live resize 和 window 变化 | `viewWillStartLiveResize`、`viewDidEndLiveResize`、`viewDidMoveToWindow` 三条回调都要保留。 |
| `FilesViewController.restoreEmbeddedCapability()` | 恢复被折叠的编辑器 | 布局约束稳定后调用 `synchronizeLayoutAfterContainerChange()`。 |

### 4.2 嵌入 Monaco JavaScript

| 符号 | 作用 | 修改时必须保持 |
| --- | --- | --- |
| `post(name, payload)` | JS -> Swift bridge | 每条消息自动带当前 `pageLoadGeneration`。 |
| `performMeasuredEditorLayout()` | 读取 `#editor.clientWidth/clientHeight` 并布局 | 零尺寸时跳过；传显式 `{ width, height }`。 |
| `scheduleEditorLayout()` | 合并 JS 布局 | 每个 animation frame 最多一次，并保留 200ms fallback。 |
| `setEditorDocument(_:)` | 切换/刷新文档 model | 同 URI 先 `getModel(uri)`，存在则更新内容，不重复 `createModel`。 |
| `loadWorkspace(_:)` | 完成 workspace 安装 | 所有文档、主题、显示选项和当前 tab 安装完成后才发送 `workspaceReady`。 |

## 5. 快速诊断流程

### 5.1 先判断卡在哪一层

1. 记录问题发生在冷启动、暖启动、重复打开、窗口 resize、Files 分栏拖动、折叠恢复还是 tab 切换。
2. 看原生遮罩：
   - 显示“正在加载编辑器...”说明仍未通过 `workspaceReady`。
   - 显示“编辑器加载失败”说明有限自动恢复已耗尽。
   - 遮罩已经消失但内容空白，优先查 Monaco surface 尺寸和渲染，不要扩大到远端传输。
3. 拖动任意分栏后立刻恢复，优先查 `forcePendingEditorLayoutRequest` 和 `scheduleEditorLayout()`。
4. 只有重新打开同一文件才失败，优先查 model URI 复用和旧 generation 消息。
5. 只有打包 App 失败，先验证 `Contents/Resources/MonacoEditor/vs/loader.js`，不要先改生命周期代码。

### 5.2 推荐断点

在 Xcode/LLDB 使用符号断点，按顺序观察：

```text
loadMonacoEditorHTML
webView(_:didFinish:)
handleScriptMessage
syncWorkspaceToWebView
scheduleEditorLayoutIfNeeded
recoverMonacoReadinessIfNeeded
webViewWebContentProcessDidTerminate
editorLiveResizeDidStart
editorLiveResizeDidEnd
editorDidMoveToWindow
```

每次只记录以下非敏感字段：generation、消息名、runtime/editor ready、live resize、是否 attached、WebView bounds、自动恢复次数。不要记录远端文件正文、主机、路径、凭据或 token。

应用统一日志只能辅助确认 App/窗口生命周期；当前 editor bridge 的主要证据仍来自断点和回归测试：

生产运行日志通常位于 `~/Library/Application Support/Stacio/Logs/stacio.log`；XCTest 使用临时目录日志。当前编辑器生命周期没有把文件正文写入日志，排障时不要为了“方便”添加未脱敏正文日志。

```bash
log stream --style compact --level debug \
  --predicate 'subsystem == "com.stacio.Stacio"'
```

## 6. 不可破坏的实现约束

1. 不得在 `didFinish` 或 `ready` 时隐藏加载遮罩；唯一正常出口是当前页面的 `workspaceReady`。
2. 正常 `viewDidLayout`、split resize 和 window resize 只能触发布局，不能重载 Monaco 页面。
3. 所有 JS bridge 消息必须校验页面代次；新增消息也不能绕过 generation。
4. 自动恢复必须有上限；不得用 timer 构造无限 reload loop。
5. `0 x 0` 不是“无需布局”，而是“恢复非零尺寸后必须强制布局”。
6. 布局必须合并：Swift 侧按 main runloop，JS 侧按 animation frame；不要恢复 `automaticLayout: true` 与手动布局双重触发。
7. 同 URI workspace 必须复用 Monaco model；切 tab 和重载不得盲目重复 `createModel`。
8. 文档正文、dirty/save revision 和待关闭状态必须由 Swift 持有，WebContent 重建不能清空它们。
9. 编辑器恢复不能改动 `FilesCoordinator`、下载缓存、上传回传路径或 SSH/FTP transport，除非故障证据明确落在这些层。
10. UI 状态继续使用 `StacioDesignSystem` 和现有 loading overlay，不引入第二套视觉语言。
11. 修复 resize 问题时不得只调用 `view.layoutSubtreeIfNeeded()`；必须验证 Monaco surface 最终尺寸和内容。
12. 任何生命周期修改都必须同时新增或更新对应回归测试，不能只靠录屏目测。

## 7. 回归测试映射

| 不变量 | 关键测试 |
| --- | --- |
| 当前页面代次隔离 | `testEditorBridgeIgnoresReadyFromPreviousPageGeneration` |
| 遮罩只在 workspace 完成后消失 | `testEditorRemainsLoadingUntilCurrentWorkspaceAcknowledges`、`testActualMonacoRuntimeCompletesWorkspaceHandshakeBeforeBecomingVisible` |
| Swift 布局合并与同尺寸去重 | `testReadyEditorCoalescesLayoutRequestsAndSkipsUnchangedSize` |
| 零尺寸恢复不丢布局 | `testForcedLayoutSurvivesTemporaryZeroSizedContainer` |
| JS rAF 合并和 200ms fallback | `testMonacoLayoutUsesMeasuredSizeAndOneAnimationFramePerRenderCycle` |
| 同 URI model 复用 | `testRepeatedWorkspaceLoadReusesExistingMonacoModelURI` |
| JS workspace 错误立即恢复 | `testWorkspaceJavaScriptFailureImmediatelyTriggersBoundedRecovery` |
| resize 不重载，进程终止有限恢复 | `testLayoutChangesNeverReloadMonacoAndProcessTerminationReloadsExactlyOnce`、`testRepeatedWebContentProcessTerminationUsesBoundedAutomaticRecovery` |
| 成功后恢复下一次故障预算 | `testSuccessfulWorkspaceAfterRecoveryRestoresProcessTerminationBudget` |
| ready/unready live resize 分流 | `testUnreadyEditorReloadsOnceWhenLiveResizeEnds`、`testReadyEditorEndingLiveResizeRequestsLayoutWithoutReloading`、`testEditorBecomingReadyDuringLiveResizeAvoidsRecoveryReload` |
| 无 delegate、导航失败和 watchdog | `testFinishedNavigationWithoutReadyTriggersOneBoundedRecoveryReload`、`testNavigationWithoutAnyDelegateCallbackStillTriggersBoundedRecovery`、`testCurrentNavigationFailureImmediatelyTriggersBoundedRecovery` |
| 自动恢复耗尽后人工重试 | `testExhaustedAutomaticRecoveryShowsManualRetryWithoutReloadLoop` |
| resize callback 丢失、detach/reattach | `testWindowLiveResizeEndNotificationRecoversWhenViewCallbackIsMissed`、`testEditorAttachedWhileWindowIsLiveResizingRecoversAtResizeEnd`、`testEditorDetachedDuringLiveResizeRecoversWhenReattachedAfterResize` |
| Files 折叠恢复强制布局 | `testRestoringCollapsedEditorForcesLayoutWhenItsSizeIsUnchanged` |
| 保存/关闭不丢最后一版内容 | `testWindowCloseRechecksMonacoRevisionBeforeDelayedChangedMessageArrives` 及相邻 async save/close 测试 |

最小验证：

```bash
cd /Users/mac/Documents/Stacio
swift test --filter RemoteTextEditorViewControllerTests
swift test --filter FilesViewControllerTests
git diff --check
```

合并前验证：

```bash
cd /Users/mac/Documents/Stacio
swift build
swift test
git diff --check
```

2026-07-31 稳定基线：编辑器套件 `56/56`、Files 套件 `75/75`；全量 `2867` tests、`5` skipped、`0` failures。测试数量会增长，后续不能把减少或新增 skip 当成默认可接受。

## 8. 人工与真实 Monaco 压测矩阵

每次修改编辑器生命周期或布局，至少覆盖：

| 场景 | 操作 | 通过标准 |
| --- | --- | --- |
| 冷启动首次打开 | 启动 App 后立即打开文本文件 | 原生遮罩连续覆盖加载期，随后一次性显示编辑器，无黑屏。 |
| 暖启动重复打开 | 连续打开/关闭同一文件 | 不出现重复 model 异常，内容与最新 Swift workspace 一致。 |
| 初始化期间 resize | 文件刚打开时持续拖动窗口 | 不在 live resize 中重载；结束后成功就绪或进入有限恢复。 |
| 高频 resize | 连续 300 次改变容器尺寸 | 不重载页面、无明显卡顿，最终 Monaco surface 匹配宿主。 |
| 零尺寸往返 | 折叠至 `0 x 0` 再恢复原尺寸 | 即使恢复尺寸与历史相同，也强制执行一次有效布局。 |
| Files 折叠恢复 | 折叠右侧编辑器再展开 | 编辑器立即刷新，不需要再拖左侧分栏。 |
| 离屏重挂 | 切换容器/窗口使 view detach 后 reattach | ready 时补布局，unready 时有限恢复，不无限重载。 |
| 同 URI 内容更新 | 同页面再次载入相同 URI、不同内容 | 复用 model，最终显示新内容。 |
| 深浅色切换 | 加载前后切换 appearance | 遮罩和编辑器背景连续，无黑色闪烁。 |
| dirty save/close | 修改后保存、立即关闭或保存失败 | 不丢最后 revision，失败时保持窗口和 dirty 状态。 |

2026-07-31 真实 Monaco 验收记录：两次 workspace 握手；同 URI 第二次内容更新成功；300 次尺寸变化；`0 x 0 -> 1111 x 733`；最终宿主和 Monaco surface 均为 `1111 x 677`；最终内容为 `const value = 2;\n`。源资源模式连续 4 轮、最终包内资源模式连续 2 轮通过。

## 9. 本地 QA 打包验证

Monaco 生命周期修改必须验证最终包，不能只验证源码测试：

```bash
cd /Users/mac/Documents/Stacio
STACIO_ALLOW_INCOMPLETE_PRODUCT_OPS_CONFIG=1 \
STACIO_MONACO_VS_PATH=/Users/mac/Documents/Stacio/node_modules/monaco-editor/min/vs \
./scripts/package-app.sh

./scripts/smoke-local-app.sh /Users/mac/Documents/Stacio/dist/Stacio.app
codesign --verify --deep --strict /Users/mac/Documents/Stacio/dist/Stacio.app
find /Users/mac/Documents/Stacio/dist/Stacio.app/Contents/Resources/MonacoEditor/vs -type f | wc -l
```

检查 bundle 时间必须晚于所有本次修改的源码；`Contents/Resources/MonacoEditor/vs/loader.js` 必须存在。该流程生成本地 ad-hoc QA 包，不代表 notarized、DMG、OTA 或正式发布完成。

## 10. 缺陷记录模板

```markdown
### Remote Editor UI defect

- App version/build:
- source runtime or packaged App:
- macOS version / architecture:
- cold start or warm start:
- document type and approximate size (不要粘贴敏感正文):
- trigger: initial open / window resize / Files split resize / collapse-restore / tab switch / reattach:
- native overlay text and whether retry button appeared:
- did dragging the Files divider immediately restore rendering:
- last known WebView bounds / Monaco surface size:
- current page generation and recovery count (如已加临时诊断):
- focused tests:
- full test result:
- screen recording or screenshot:
- package Monaco resource check:
```

## 11. 修改完成检查清单

- [ ] 只在权威目录 `/Users/mac/Documents/Stacio` 修改和验证。
- [ ] 先保留并列出用户已有脏文件，没有覆盖 Workspace、Workbench 或其他模块改动。
- [ ] `ready -> loadWorkspace -> workspaceReady` 顺序未被缩短。
- [ ] 旧 generation 消息仍被拒绝。
- [ ] resize/布局没有触发页面重载。
- [ ] `0 x 0` 恢复和 Files 折叠恢复均有测试。
- [ ] 自动恢复仍有上限，人工 retry 可用。
- [ ] 同 URI model 不重复创建。
- [ ] dirty/save/close 最后 revision 不丢失。
- [ ] focused、full suite、真实 Monaco 和最终包资源均验证。
- [ ] 同步更新 `docs/development/code-index.md` 与 `docs/cross-platform-reference/03-views-and-components.md`。
