# 贡献指南

感谢你对 Stacio 项目的兴趣。在提交贡献前，请先阅读以下规范。

## 许可证

Stacio 使用 [Stacio Source Available Non-Commercial License 1.0](LICENSE)。该许可证允许个人学习、研究、评估和非商业二次开发。商业使用以及官方品牌二进制、安装包或衍生版本的再分发，均需要事先获得书面授权。

提交贡献即表示你同意你的贡献将按照同一许可证授权。

## 开发环境

- macOS 14 及以上
- Xcode Command Line Tools
- Swift Package Manager（随 Xcode 安装）
- Rust toolchain + Cargo
- Node.js 与 npm（用于 Monaco 编辑器资源和 ops-platform）

## 本地构建

```bash
# 安装 JS 依赖
npm ci

# 构建 Rust Core
cargo build --manifest-path StacioCore/Cargo.toml --lib

# 构建 Swift 应用
swift build --product Stacio

# 生成本地 .app 安装包
./scripts/package-app.sh
```

## 测试要求

提交前请确保以下测试通过：

```bash
# Swift 测试
swift test

# Rust 测试
cargo test --manifest-path StacioCore/Cargo.toml

# 冒烟测试
./scripts/smoke-local-app.sh dist/Stacio.app
```

如果修改了 Rust UniFFI 接口，必须重新生成绑定并确认无差异：

```bash
./scripts/generate-uniffi.sh
git diff --exit-code
```

## 代码规范

### Swift

- 使用协议导向设计，公共接口用 `public` 标注。
- Coordinator 类负责协调多个服务，不直接操作 UI 控件。
- 敏感信息（凭据、密钥、Token、主机、路径、命令、终端内容）不进日志、UI 和诊断包。
- 错误信息通过 `RuntimeDiagnosticFormatter` 归一化。

### Rust

- 按 domain/infrastructure/services 分层，不跨层直接调用。
- UniFFI 导出接口集中在 `lib.rs`。
- 修改接口后必须执行 `./scripts/generate-uniffi.sh`。
- 使用 `telemetry/redaction.rs` 进行敏感数据脱敏。

### TypeScript（ops-platform）

- `strict: true`，target ES2022。
- 数据契约用 zod schema 定义。
- JSDoc 注释用于公共 API。

## 提交规范

使用 Conventional Commits 格式：

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

**Type**：

- `feat` — 新功能
- `fix` — Bug 修复
- `docs` — 文档变更
- `refactor` — 代码重构（不改变功能）
- `test` — 测试相关
- `chore` — 构建、依赖、配置等杂项

**Scope**（可选）：`terminal`、`ssh`、`scp`、`tunnel`、`ai`、`agent`、`session`、`license`、`ops`、`docs` 等。

示例：

```
feat(scp): 支持远端到远端拖拽传输
fix(terminal): 修复 SSH 快速输入时的幻影空格
docs(glossary): 新增统一术语表
```

## Pull Request 流程

1. Fork 仓库并创建分支：`feat/your-feature` 或 `fix/your-bugfix`。
2. 确保所有测试通过。
3. 如果修改了 Rust 接口，确认 UniFFI 绑定已重新生成且无差异。
4. PR 描述中说明：改动内容、改动原因、测试方式。
5. 等待 CI 检查通过。
6. 等待维护者 review。

## 安全相关贡献

如果贡献涉及安全相关代码（凭据、认证、加密、审计），请额外注意：

- 不要在代码、注释、commit message 或 PR 描述中暴露真实凭据、密钥或敏感路径。
- 安全相关改动需要在 PR 中说明影响范围和测试方法。
- 如果发现安全漏洞，请私下联系维护者，不要在公开 issue 中披露。

## 可复现的 Issue

提交 Issue 时请包含：

- Stacio 版本号和构建号（见"关于"或 llms.txt）。
- macOS 版本和芯片架构（Apple Silicon / Intel）。
- 复现步骤。
- 预期行为和实际行为。
- 如可能，附带脱敏后的诊断信息。
