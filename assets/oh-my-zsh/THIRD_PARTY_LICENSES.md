# Third-Party Licenses — Oh My Zsh Vendored Snapshot

oh-my-zsh 仓库本体为 MIT 许可（`LICENSE.txt`，Copyright 2009-2026 Robby Russell and contributors）。
本快照内个别插件/文件携带其他许可，随 Stacio app 再分发时按下表处理。

## 已排除组件（不随 Stacio 分发）

以下 GPL-2.0 许可组件因传染性不适合随闭源/商业 app 分发，已从 vendored 快照中移除：

| 组件 | 原路径 | 许可 | 原因 |
|---|---|---|---|
| gitfast | `plugins/gitfast/`（git-prompt.sh、git-completion.bash） | GPL-2.0 | 传染性许可 |
| iterm2 shell integration | `plugins/iterm2/iterm2_shell_integration.zsh` | GPL-2.0 | 传染性许可 |
| term_tab | `plugins/term_tab/term_tab.plugin.zsh` | GPL-2.0 | 传染性许可 |

用户如确实需要以上功能，可通过 `custom/plugins/` 自行添加（Stacio 不代为用户分发）。

## 保留组件（可再分发，随包声明）

| 组件 | 路径 | 许可 | 再分发要求 |
|---|---|---|---|
| kube-ps1 | `plugins/kube-ps1/` | Apache-2.0（目录含 LICENSE） | 保留版权与许可声明 |
| bazel completion | `plugins/bazel/_bazel` | Apache-2.0（Copyright 2015 The Bazel Authors） | 保留版权与许可声明 |
| zsh-interactive-cd | `plugins/zsh-interactive-cd/`（LICENSE） | MPL-2.0（Copyright 2017-2018 Henry Chang） | 保留 MPL-2.0 声明 |
| history-substring-search | `plugins/history-substring-search/history-substring-search.zsh` | BSD 风格（保留版权声明条款） | 保留版权声明 |
| zsh-navigation-tools | `plugins/zsh-navigation-tools/`（LICENSE） | MIT 与 GPLv3 双许可（本快照以 MIT 面分发） | 保留双许可声明 |

## 合规说明

- 本目录（`assets/oh-my-zsh/`）整体随 Stacio 打包到 `Resources/OhMyZsh`。
- 打包/发布流程应包含本文件（随快照一同复制）。
- 若上游更新引入新的非 MIT 许可组件，需重新执行许可审计并更新本表。

## 随 Stacio 分发的终端字体

| 字体 | 路径 | 许可 | 说明 |
|---|---|---|---|
| JetBrainsMonoNLNerdFont-Regular | `Stacio/Resources/Fonts/JetBrainsMonoNLNerdFont-Regular.ttf` | OFL-1.1（`Stacio/Resources/Fonts/NerdFonts-OFL.txt`，源自 ryanoasis/nerd-fonts） | 用于渲染 Oh My Zsh 主题的特殊符号（⚡ ✗ ➜ 等） |
| SarasaTermSC-Regular | `Stacio/Resources/Fonts/SarasaTermSC-Regular.ttf` | 既有（`Stacio/Resources/Fonts/LICENSE.txt`） | 既有 CJK 网格字体 |
