<div align="center">

<img src="assets/stacio-logo.png" width="128" alt="Stacio" />

# Stacio

**原生 macOS SSH 客户端与远程运维工作台**

终端 · SCP/SFTP · 远程文件 · SSH 隧道 · 设备看板 · AI Agent

[![版本](https://img.shields.io/badge/版本-0.14.2%20Stable-2dd4bf)](https://www.stacio.cn/)
[![macOS](https://img.shields.io/badge/macOS-14%2B-000000)](https://www.stacio.cn/)
[![许可证](https://img.shields.io/badge/许可证-Source%20Available%20NC-blue)](LICENSE)
[![Swift](https://img.shields.io/badge/Swift-5-F05138)](https://www.swift.org/)
[![Rust](https://img.shields.io/badge/Rust-Core-CE422B)](https://www.rust-lang.org/)
[![PR 欢迎贡献](https://img.shields.io/badge/PR-欢迎贡献-brightgreen)](CONTRIBUTING.md)

[官网](https://www.stacio.cn/) · [下载](https://www.stacio.cn/#download) · [GitHub](https://github.com/Fengoffer/Stacio) · [Gitee](https://gitee.com/fengoffer/Stacio) · [更新日志](https://www.stacio.cn/#releases)

**中文** | [English](README.md)

</div>

---

> Stacio 是原生 macOS SSH 客户端与远程运维工作台，在一个桌面应用中管理远程会话、终端、文件传输、隧道、设备状态和经用户确认的 AI 辅助排查。**不是 Electron，不是网页套壳**——Swift + AppKit 原生构建，共享 Rust Core 处理 SSH 协议。

## 为什么选择 Stacio

| 痛点 | 现有方案 | Stacio |
|------|---------|--------|
| 终端 + 文件 + 监控分散在多个应用 | iTerm2 + FileZilla + htop 来回切 | 一个应用全搞定 |
| Electron 工具吃内存、风扇狂转 | Termius 500MB+ 内存 | 原生 Swift，空载约 50MB |
| Xshell 没有 Mac 版 | 找不到替代品 | 会话分组 + 分屏 + 堡垒机导入 |
| AI 运维工具不可控 | 担心 AI 静默执行命令 | 命令需确认后执行，安全可控 |
| SSH 客户端锁定订阅 | Termius $120/年，SecureCRT $99+ | 核心免费，本地优先，无需注册账号 |

### 与同类工具对比

| 能力 | Stacio | iTerm2 | Termius | Tabby | Electerm | SecureCRT |
|------|--------|--------|---------|-------|----------|-----------|
| Mac 原生（非 Electron） | Swift + AppKit | 原生 | Electron | Electron | Electron | Qt |
| SSH / Telnet / 串口 | SSH / Telnet / 串口 / 蓝牙 | 仅 SSH | SSH / Telnet | SSH / Telnet / 串口 | SSH / Telnet / 串口 | SSH / Telnet / 串口 |
| SCP / SFTP 文件传输 | 双栏 + 多面板 + 远端到远端 | 无 | 有 | 有 | 有 | 无 |
| 远程文件编辑器 | 语法高亮 + 多编码 | 无 | 无 | 无 | 有 | 无 |
| 文件快速预览（空格键） | 图片 / 视频 / 音频 / PDF / 十六进制 | 无 | 无 | 无 | 无 | 无 |
| 会话分组 + 分屏 | 有 + 同步执行 | 仅分屏 | 仅分组 | 仅标签页 | 仅标签页 | 仅分组 |
| 堡垒机配置导入 | 天融信 / Xshell / SecureCRT | 无 | 无 | 无 | 无 | 无 |
| SSH 隧道 | 本地 / 远端 / 动态转发 | 无 | 有 | 无 | 无 | 无 |
| 设备指标看板 | CPU / 内存 / 磁盘 / 网络 + 告警 | 无 | 有（付费） | 无 | 无 | 无 |
| AI 辅助排查 | 命令卡片（用户确认后执行） | 无 | 无 | 无 | 无 | 无 |
| 本地 Agent 集成 | Codex / Claude / OpenCode / Qwen | 无 | 无 | 无 | 无 | 无 |
| SSH 远程浏览器 | 通过 SSH 访问远端内网服务 | 无 | 无 | 无 | 无 | 无 |
| 定价 | 核心免费，本地优先 | 免费 | $120/年 | 免费 | 免费 | $99+ |

## 应用截图

<p float="left">
  <img src="assets/screenshots/terminal-dark-light.png" width="49%" alt="深浅色终端界面（含会话分组）" />
  <img src="assets/screenshots/terminal-split.png" width="49%" alt="终端分屏" />
</p>
<p float="left">
  <img src="assets/screenshots/scp-sftp-transfer.png" width="49%" alt="多面板 SCP/SFTP 传输" />
  <img src="assets/screenshots/device-dashboard.png" width="49%" alt="设备看板" />
</p>
<p float="left">
  <img src="assets/screenshots/ai-assistant.png" width="49%" alt="内置 AI 助手" />
  <img src="assets/screenshots/codex-integration.png" width="49%" alt="Codex 本地 Agent 集成" />
</p>
<p float="left">
  <img src="assets/screenshots/file-editor.png" width="49%" alt="远程文件编辑器" />
  <img src="assets/screenshots/stacio-workbench.png" width="49%" alt="主工作台" />
</p>

## 核心能力

### 终端管理

- **多协议**：SSH / Telnet / 串口 / 蓝牙 Console 集于一身
- **会话分组**：按项目、环境或团队组织，支持保存和恢复分屏布局
- **终端分屏**：水平 / 垂直分屏，多终端同步执行
- **语义高亮**：系统信息、状态、错误自动着色
- **命令补全**：智能联想，无幻影空格和光标错位
- **命令历史**：按会话可搜索的命令历史检查器
- **终端宏**：录制和回放命令序列

### 文件传输

- **SCP/SFTP 工作区**：双栏及多面板网格布局（2×2）
- **拖拽传输**：本地→远端、远端→本地、本地→本地、远端→远端
- **传输队列**：暂停 / 恢复 / 取消，并发队列，显示进度、速率和预计剩余时间
- **完整性保障**：断点续传、完整性校验、自动重试
- **冲突处理**：替换 / 保留两者 / 跳过
- **远程文件编辑器**：语法高亮、多编码、查找替换、安全保存
- **文件快速预览**：空格键预览图片、视频、音频、PDF 和十六进制

### 网络与隧道

- **SSH 隧道管理**：本地 / 远端 / 动态端口转发
- **SSH 远程浏览器**：通过 SSH 会话访问远端内网 Web 服务
- **ProxyJump**：多跳跳板机支持

### 设备监控

- **实时指标**：CPU / 内存 / 磁盘 / 网络 I/O
- **自定义告警**：基于阈值的通知
- **系统概览**：主机名、操作系统、内核版本、运行时长、网络接口

### AI 辅助

- **上下文感知**：AI Agent 读取终端上下文生成排查建议
- **命令卡片**：生成可执行命令，**需用户确认后执行**
- **本地 Agent 集成**：Codex / Claude / OpenCode / Qwen Code
- **安全优先**：AI 不会静默执行命令、下载或安装

### 专业功能

- **堡垒机配置导入**：天融信 / Xshell / SecureCRT 配置导入，支持预览
- **会话批量导入导出**：批量操作，自动去重
- **会话分组**：将多面板布局（终端 + 文件传输）保存为可恢复的分组

## 技术架构

```
┌─────────────────────────────────────┐
│         macOS UI 层                  │
│     Swift + AppKit（原生）           │
├─────────────────────────────────────┤
│         FFI 桥接层                   │
│    Swift ↔ Rust 桥接                │
├─────────────────────────────────────┤
│         Rust Core (StacioCore)      │
│  · SSH 协议 (russh)                  │
│  · SCP/SFTP 传输引擎                 │
│  · 会话管理 · 隧道管理               │
├─────────────────────────────────────┤
│         平台层                       │
│  macOS Keychain · Network · FS      │
└─────────────────────────────────────┘
```

UI 层各平台原生（macOS: Swift/AppKit, Windows: WinUI 3, Linux: GTK4），核心协议层用 Rust 统一——三端共享同一套 SSH/SCP 引擎。

## 安全设计

- **凭据管理**：所有凭据走 macOS Keychain，不存储明文
- **本地优先**：会话数据保存在本地，不默认外传
- **日志脱敏**：诊断和日志默认脱敏（主机名、IP、账号、路径、命令被移除）
- **AI 安全**：AI 生成的命令、更新下载、安装和重启均需用户确认，Stacio 不会静默执行
- **离线许可证**：Ed25519 签名 + X25519 密钥协商，跨平台 License 契约（v1.2）

## 平台路线

| 平台 | 状态 | 技术栈 |
|------|------|--------|
| macOS | 当前可用（0.14.2） | Swift + AppKit + Rust Core |
| Windows | 适配开发中 | WinUI 3 / .NET 8 + Rust Core |
| Linux | 架构基线已定 | GTK4 / libadwaita + Rust Core |
| 国产操作系统 | 规划中 | 统信 UOS · 深度 · 麒麟 · 欧拉 · 鸿蒙 |

## 快速事实

- **当前版本：** Stacio 0.14.2 Stable（构建号 333）
- **系统要求：** macOS 14 及以上
- **安装包：** 下载页分别提供 Apple Silicon 与 Intel Mac 版本
- **首次打开：** 当前安装包尚未公证。若 macOS 拦截首次启动，请在 Finder 中右键 `Stacio.app`，选择"打开"

## 常见问题

<details>
<summary><b>Stacio 是 Mac SSH 客户端吗？</b></summary>

是。Stacio 是原生 macOS SSH 客户端，提供远程会话、终端、远程文件、SCP 传输、SSH 隧道和设备指标等远程运维工作流。
</details>

<details>
<summary><b>Stacio 与 macOS Terminal 有何不同？</b></summary>

macOS Terminal 是系统自带的终端应用。Stacio 在终端基础上增加会话保存与分组、终端分屏、同步执行、远程文件、SCP 传输、SSH 隧道、设备指标和 AI 辅助排查等能力，便于长期管理多台主机。
</details>

<details>
<summary><b>Stacio 能作为 Xshell for Mac 替代吗？</b></summary>

可以。若你的需求是在 Mac 上管理多个远程会话，并需要会话分组、终端分屏、同步执行、远程文件、SCP 传输和 SSH 隧道，Stacio 可以作为 Xshell for Mac 的替代选择。同时支持导入 Xshell 会话配置。
</details>

<details>
<summary><b>有 Windows 或 Linux 版本吗？</b></summary>

Windows 版正在使用 WinUI 3 / .NET 8 适配开发中，会共享 macOS 版的 Rust Core。Linux 版已有 GTK4 / libadwaita 架构基线。后期还规划国产操作系统（统信 UOS、深度、麒麟、欧拉、鸿蒙）的原生适配。
</details>

<details>
<summary><b>AI 助手是如何工作的？安全吗？</b></summary>

AI 助手读取终端上下文，生成排查建议和命令卡片。每张命令卡片都需要用户明确确认后才会执行——Stacio 不会静默运行 AI 生成的命令。你还可以接入本地 Agent（Codex、Claude、OpenCode、Qwen Code）进行更高级的工作流。
</details>

<details>
<summary><b>Stacio 是否管理数据库？</b></summary>

不管理。Stacio 不提供数据库连接或相关管理功能。
</details>

<details>
<summary><b>如何选择 Apple Silicon 与 Intel 安装包？</b></summary>

在 Mac 的"关于本机"中查看芯片信息。显示 Apple 芯片时选择 Apple Silicon 版本；显示 Intel 时选择 Intel Mac 版本。
</details>

## 下载与安装

请通过 [Stacio 官方下载页](https://www.stacio.cn/#download) 获取当前安装包。下载页分别提供 Apple Silicon 与 Intel Mac 版本。

## 从源码构建

以下依赖和命令仅适用于从源码构建；使用官网安装包不需要安装 Xcode、Swift、Rust 或 Node 开发环境。

**前置条件：** Xcode Command Line Tools、Swift Package Manager、Rust toolchain + Cargo、Node.js + npm。

```bash
# 安装 JavaScript 依赖
npm ci

# 构建 Rust Core
cargo build --manifest-path StacioCore/Cargo.toml --lib

# 运行测试
swift test
cargo test --manifest-path StacioCore/Cargo.toml

# 创建本地 .app
./scripts/package-app.sh
```

打包完成后应用位于 `dist/Stacio.app`。

## 贡献与许可证

欢迎围绕可复现的问题、改进建议和非商业贡献参与项目；提交前请先阅读[贡献指南](CONTRIBUTING.md)。

Stacio 使用 [Stacio Source Available Non-Commercial License](LICENSE) 1.0。该许可证允许个人学习、研究、评估和非商业二次开发；商业使用以及官方品牌二进制、安装包或衍生版本的再分发，均需要事先获得书面授权。

## 链接

- **官网：** [https://www.stacio.cn/](https://www.stacio.cn/)
- **下载：** [https://www.stacio.cn/#download](https://www.stacio.cn/#download)
- **GitHub：** [https://github.com/Fengoffer/Stacio](https://github.com/Fengoffer/Stacio)
- **Gitee：** [https://gitee.com/fengoffer/Stacio](https://gitee.com/fengoffer/Stacio)
- **LLM Context：** [https://www.stacio.cn/llms.txt](https://www.stacio.cn/llms.txt)
- **Full Product Context：** [https://www.stacio.cn/llms-full.txt](https://www.stacio.cn/llms-full.txt)

---

<div align="center">

如果 Stacio 对你有帮助，欢迎给个 Star

**[GitHub](https://github.com/Fengoffer/Stacio)** · **[Gitee](https://gitee.com/fengoffer/Stacio)**

</div>
