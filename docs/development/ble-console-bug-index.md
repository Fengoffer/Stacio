# BLE Console Bug 索引

版本：v1.0
日期：2026-07-29
范围：Stacio macOS BLE Console、共享 Console v1 contract，以及未来 Windows BLE/SPP 适配。

本文只记录可复现路径、证据和当前验证状态。`Covered` 表示已有自动化回归覆盖，不等于真实 NBEE 硬件链路已验收；未执行的硬件项保持 `Needs hardware`。

## 状态定义

| Status | 含义 |
| --- | --- |
| `Covered` | 已有明确自动化回归测试覆盖对应行为。 |
| `Not reproduced` | 当前没有稳定复现；保留证据入口，复现后再冻结修复。 |
| `Needs hardware` | 必须使用真实 NBEE、手机 BTerm 或系统蓝牙状态验证。 |
| `Windows future` | 共享 contract 已冻结，但 Windows 平台适配器尚未实现和验收。 |

## Bug 索引

| ID | Error code | Symptom | Reproduction | Evidence | Owner | Fix | Regression test | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| BLE-001 | `-` | CoreBluetooth 返回 RSSI `127` 时界面显示伪造的强信号值。 | 扫描结果注入 `RSSI=127`。 | `BLEConsoleRSSI` 将 `127` 映射为无可用值和 `-- dBm`。 | macOS BLE | 不参与按信号强度排序，稳定显示无可用值。 | `Tests/StacioAppTests/BLEConsoleModelsTests.swift::testRSSI127IsUnavailableAndUsesStableDisplayText` | `Covered` |
| BLE-002 | `-` | 重复 advertisement 造成重复行，RSSI 抖动造成列表频繁重排或选中项丢失。 | 同一 peripheral identifier 连续广播不同名称/RSSI；在排序节流窗口内更新。 | 扫描快照按 identifier 合并最新广播、节流重排并保留 selection。 | macOS BLE | 去重、过期淘汰和稳定排序均以 peripheral identifier 为主键。 | `BLEConsoleModelsTests::testSnapshotDeduplicatesLatestAdvertisementAndEvictsStaleDevices`<br>`BLEConsoleModelsTests::testSnapshotThrottlesRSSIReorderingAndPreservesSelectionByIdentifier`<br>`BLEConsoleCentralTests::testAdvertisementsCoalesceByIdentifierAndUseLatestNameAndRSSI` | `Covered` |
| BLE-003 | `BLE_CONSOLE_CONNECT_FAILED` | 手机 BTerm 占用 NBEE 后，Stacio 无法连接或服务发现失败。 | 手机保持 BTerm 连接，再从 Stacio 连接同一 NBEE。 | 需要执行下方 NBEE manual matrix 的“手机占用”项。 | macOS BLE / Hardware | 不回退 SPP；显示稳定错误并允许用户断开手机后重试。 | `NBEE manual matrix: 手机/BTerm 占用` | `Needs hardware` |
| BLE-004 | `BLE_CONSOLE_CONNECT_FAILED` / `BLE_CONSOLE_DISCONNECTED` | 上一轮连接的晚到 callback 覆盖新一轮状态。 | 先递增 connection generation，再注入旧 generation 的 connected/disconnected callback。 | Session 和 CoreBluetooth adapter 在事件与操作中携带 generation。 | macOS BLE | 所有连接、发现、订阅、写入和断开事件按 generation 过滤。 | `BLEConsoleSessionTests::testStaleGenerationCallbacksAreIgnored`<br>`BLEConsoleCentralTests::testConnectionOperationsAndCallbacksPreserveGeneration` | `Covered` |
| BLE-005 | `BLE_CONSOLE_SUBSCRIBE_FAILED` | 重复服务发现或回调可能造成 RX characteristic 重复订阅。 | 对同一 generation 重复投递服务发现/订阅完成事件。 | 标准连接路径当前只记录一次 subscribe；尚无稳定的重复订阅现场复现。 | macOS BLE | 状态机只在 profile 解析完成后进入 subscribing；若现场复现，补充重复 callback 去重断言。 | `BLEConsoleSessionTests::testConnectsOnlyAfterProfileDiscoveryAndRXSubscription` | `Not reproduced` |
| BLE-006 | `BLE_CONSOLE_WRITE_FAILED` | `writeWithoutResponse` 暂不可发送时队列永久停住。 | 令 driver 的 `canSendWithoutResponse=false`，排队 21 字节，再发送 ready callback。 | ready callback 后按运行时 maximum write length 继续排空。 | macOS BLE | 保留队列并等待 `peripheralIsReadyToSendWriteWithoutResponse` 对应事件。 | `BLEConsoleSessionTests::testWithoutResponsePausesUntilDriverSignalsReady` | `Covered` |
| BLE-007 | `BLE_CONSOLE_TX_QUEUE_FULL` | 大段粘贴被截断、乱序、重复发送，或队列溢出后部分接收。 | 发送 1/20/21/MTU 边界/4 KiB 字节序列；在 driver 阻塞时填满队列后再写入。 | TX 按运行时 MTU 分块，测试按字节比较完整序列；溢出整次拒绝。 | macOS BLE | 不使用固定 20 字节假设；维护单一有序队列和整次写入上限。 | `BLEConsoleSessionTests::testWithoutResponseUsesRuntimeMaximumAndPreservesByteOrder`<br>`BLEConsoleSessionTests::testWithResponseWaitsForMatchingAcknowledgementBeforeNextChunk`<br>`BLEConsoleSessionTests::testQueueOverflowRejectsWholeWriteWithoutTruncatingAcceptedBytes` | `Covered` |
| BLE-008 | `BLE_CONSOLE_DISCONNECTED` | 已安排重连后关闭标签，延迟任务仍重新连接或重复 close。 | 断开并安排 reconnect，随后连续调用两次 close，再执行全部 scheduler action。 | close 会取消重连、清空队列、解除 event handler，并只断开一次。 | macOS BLE | close 幂等；关闭后任何排队重连不得生效。 | `BLEConsoleSessionTests::testCloseCancelsQueuedReconnectAndIsIdempotent` | `Covered` |
| BLE-009 | `BLE_CONSOLE_DEVICE_NOT_FOUND` / `BLE_CONSOLE_POWERED_OFF` | 系统睡眠/唤醒后已保存的 macOS peripheral binding 失效，连接停留或找不到设备。 | 已绑定 NBEE 后让 Mac 睡眠并唤醒，再从保存会话重连。 | 需要执行下方 NBEE manual matrix 的“睡眠/唤醒”项。 | macOS BLE / Hardware | 不按名称随机改绑；找不到精确 peripheral UUID 时要求重新扫描绑定。 | `NBEE manual matrix: 睡眠/唤醒与 binding` | `Needs hardware` |
| BLE-010 | `BLE_CONSOLE_PERMISSION_DENIED` | 打包 App 缺少蓝牙用途说明，系统拒绝访问或应用在权限路径失败。 | 生成测试 App 后读取 `Info.plist`。 | 包装契约精确读取 `NSBluetoothAlwaysUsageDescription`。 | Packaging | 在生成的 plist 中写入固定用途说明，不增加推测性的 sandbox entitlement。 | `Tests/Packaging/package_app_test.sh` | `Covered` |
| BLE-011 | `CONSOLE_SPP_FALLBACK_NOT_BOUND` | Windows BLE 失败后错误选择同名、随机或历史无关 COM 口。 | 配置缺少精确 `COMn`，或提供 `COM0`、小写、带空格、带后缀值。 | Core transport policy 只有精确已保存 `COMn` 才返回 BLE-then-SPP。 | Windows | WinRT BLE 重试耗尽后，只允许使用当前会话已验证的 exact COM binding；否则保持 BLE-only 并提示绑定。 | `StacioCore/src/domain/console.rs::windows_policy_requires_an_exact_saved_com_port` | `Windows future` |
| BLE-012 | Serial path | 新增 Console 后，旧 `serial` 扫描、NBEE SPP 兼容路径或 embedded Serial starter 被误改为 BLE。 | 在设置中选择 `serial`，并分别打开保存的 Serial 与 Console 会话。 | Serial 与 Console 使用不同 protocol、配置和 starter；macOS Console 不调用 Serial starter。 | macOS Serial / BLE | 保留 Serial 独立路径；Console 分支在 Serial 分支之前返回或抛错。 | `SessionSettingsViewControllerTests::testSelectingSerialDoesNotStartBLEScanningOrChangeNBEEDeviceDiscovery`<br>`SavedSessionConnectionFlowTests::testConsoleSavedSessionDecodesStoredConfigAndStartsConsoleWithoutSerial`<br>`ConsoleSessionCoordinatorTests::testReturnRetriesStoppedConsoleWithoutOpeningSerial` | `Covered` |

## NBEE Manual Matrix

以下项目只能在开发构建和真实硬件上记录观察结果。未执行时不得改成 `Covered`。

| Case | Procedure | Expected | Status |
| --- | --- | --- | --- |
| 扫描时限 | 手机 BTerm 完全断开，启动一次扫描。 | 10 秒内出现 NBEE；无服务过滤，超时后停止扫描。 | `Needs hardware` |
| 识别与选择 | 同时放置 NBEE、普通 BLE Console 和其他 BLE 设备。 | `NBEE_BLE_1103` 高亮置顶但不自动连接；其他设备正常显示。 | `Needs hardware` |
| 名称与信号 | 观察有名、无名和 RSSI 变化设备。 | 显示名称 fallback、原生信号图标和数值 RSSI；无效值显示 `-- dBm`。 | `Needs hardware` |
| Profile | 选择 NBEE 并探测 GATT。 | 匹配 FFE1/FFE3/FFE2；未知 profile 才进入手动 mapper。 | `Needs hardware` |
| 首字节 | 连接后发送 CR。 | 收到设备 prompt 原始字节，不做文本重编码。 | `Needs hardware` |
| 循环连接 | 连续执行 10 次连接/断开。 | 无重复订阅、残留连接、重复 close 或 UI 卡死。 | `Needs hardware` |
| TX 边界 | 发送 1、20、21、MTU 边界和 4 KiB 数据。 | 无截断、乱序或重放。 | `Needs hardware` |
| 手机占用 | 手机 BTerm 保持连接，再由 Stacio 连接。 | 稳定失败并可恢复；不得打开 SPP。 | `Needs hardware` |
| 设备掉电 | 连接中关闭 NBEE 电源。 | 进入有限 1/2/4 秒重试，最终给出稳定错误。 | `Needs hardware` |
| 超距 | 连接中让设备离开有效范围再返回。 | 不接受旧 generation callback；允许用户重试。 | `Needs hardware` |
| 蓝牙关闭 | 连接或扫描中关闭 macOS 蓝牙。 | 显示 powered-off 状态，不访问 Serial。 | `Needs hardware` |
| 睡眠/唤醒 | 保存绑定后睡眠并唤醒，再重连。 | 精确 binding 有效则重连；失效则要求 rebind，不按名称替代。 | `Needs hardware` |
| SPP 隔离 | 在以上每个失败场景检查进程和设备节点。 | macOS Console 从不打开 `/dev/cu.NBEE_SPP_*` 或其他串口节点。 | `Needs hardware` |

## 已执行自动化记录

| Date | Scope | Result |
| --- | --- | --- |
| 2026-07-29 | Task 10 saved Console routing/capability focused tests | 25 tests，1 SSH fixture skip，0 failures。 |
| 2026-07-29 | Workspace session-group regression | 11 tests，0 failures。 |
| 2026-07-29 | Task 11 package contract | `package_app_test passed`；`PackageManifestTests` 3 tests，0 failures。 |
| 2026-07-29 | Task 13 Rust full regression | `cargo test` 共 518 tests passed，1 ignored，0 failures；`cargo fmt -- --check` 通过。 |
| 2026-07-29 | Task 13 UniFFI regeneration | `./scripts/generate-uniffi.sh` 退出码 0；生成目录无 Git 差异。 |
| 2026-07-29 | Task 13 focused Swift regression | 257 tests，1 live SSH fixture skip，0 failures。 |
| 2026-07-29 | Task 13 full Swift regression | 2807 tests，5 skips，0 failures。 |
| 2026-07-29 | Task 13 package/source hygiene | `package_app_test passed`；`git diff --check` 通过；四个 macOS BLE owner 文件不含 `NBEE_SPP_`、`/dev/cu.` 或 `SerialRuntimeStarting`。 |

本轮未连接真实 NBEE 硬件，也未执行手机 BTerm 占用、断电、超距、蓝牙关闭或 sleep/wake 场景；上方 NBEE Manual Matrix 的所有状态继续保持 `Needs hardware`。
