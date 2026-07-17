# Stacio

Stacio 是一款面向 macOS 的本地优先远程运维工作台，适合开发者、运维人员和 Homelab 用户把终端、远程文件、文件传输、隧道、设备看板和 AI 辅助排查放在同一个原生桌面应用里完成。

应用由 AppKit 工作台和 Rust Core 组成。远程连接、会话存储、传输、诊断和可审计自动化都尽量由应用自身负责，而不是把核心体验降级成零散 shell 命令包装。

![Stacio 工作台](assets/screenshots/stacio-workbench.png)

## 亮点

- 原生 macOS 桌面体验：会话侧栏、标签页工作区、工具栏操作和右侧检查器。
- 以应用自身为中心的 SSH / SCP / Files 工作流，覆盖终端、远程文件、传输、隧道、诊断和命令历史。
- 多协议会话管理：SSH、Telnet、VNC、FTP、SCP、串口和本地终端统一从会话编辑器维护。
- 本地优先安全模型：会话数据落在本地应用数据库，凭据走 macOS Keychain，诊断与日志默认脱敏。
- Swift / AppKit 前端加 Rust Core，仓库包含桥接、会话、传输、文件、诊断、AI、终端体验和打包相关测试。
- AI 助手可读取可见终端上下文，提出排查建议，生成可执行命令卡片，并保留执行审计。

![Stacio 会话设置](assets/screenshots/stacio-session-settings.png)

## 功能说明

### 会话管理

Stacio 可以保存常用主机和连接配置，包括协议、主机、端口、用户名、标签、环境变量、启动命令、超时设置和每个会话的 AI 执行策略。侧栏支持已保存会话和分组，让常用主机保持在手边。

### 终端工作区

终端工作区支持本地终端和远程终端标签，包含命令高亮、链接识别、当前目录追踪、终端输出事件和右侧面板联动。终端上下文可以被诊断、命令历史和 AI 助手复用。

### 文件与传输

远程文件能力在 Stacio 内部完成。应用支持远程目录浏览、本地/远程文件面板、文本编辑、媒体预览、传输队列状态、取消流程和进度更新稳定性保护。

### 隧道与设备看板

Stacio 提供 SSH 相关隧道管理和设备看板入口。应用会跟踪运行中的隧道，避免关闭窗口时误中断仍在工作的连接。

### AI 助手

AI 助手可以基于当前终端标题、目录和最近输出生成排查建议，也可以返回可发送到终端的命令卡片。执行流程会经过 Stacio 的协调器，便于保留请求标识、操作记录和诊断信息。

### 诊断与安全

诊断能力围绕脱敏、应用日志、运行时上下文和可复现检查展开。凭据通过 macOS Keychain 路径保存，诊断面默认避免暴露密钥、账号和敏感路径。

## 系统要求

- macOS 14 或更新版本
- Xcode Command Line Tools
- Swift Package Manager
- Rust toolchain 和 Cargo
- Node.js 与 npm，用于应用内 web 资源

## 从源码构建

安装 JavaScript 依赖：

```bash
npm ci
```

构建 Rust Core：

```bash
cargo build --manifest-path StacioCore/Cargo.toml --lib
```

运行 Swift 测试或构建应用目标：

```bash
swift test
swift build --product Stacio
```

创建本地 `.app`：

```bash
./scripts/package-app.sh
```

打包完成后应用位于：

```text
dist/Stacio.app
```

## 测试

常用本地检查：

```bash
swift test
cargo test --manifest-path StacioCore/Cargo.toml
./scripts/smoke-local-app.sh dist/Stacio.app
```

打包和发布辅助脚本位于 `scripts/`，CI 配置位于 `.github/workflows/stacio-ci.yml`。

## 下载

预编译 DMG 包通过 GitHub Releases 发布：

https://github.com/Fengoffer/Stacio/releases

## 开源协议与商用限制

Stacio 允许个人学习、研究和非商业二次开发。未经书面授权，禁止商用、转售、付费托管、付费分发，或将本项目集成到商业产品中。

完整条款见 [LICENSE](LICENSE)。
