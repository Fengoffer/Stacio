#!/usr/bin/env bash
# P10-5：第二套 URL/模型/CLI 常量扫描。
# 在 Swift/Rust 源码中扫描 V2 创建/修复/空状态/测试路径对 V1 硬编码供应商 URL、
# 预置模型名、CLI 命令常量的引用；断言除 Legacy 迁移适配器外无引用。
set -euo pipefail

PATTERN='\.(defaultBaseURL|defaultModel|suggestedModels)\b|\b(var|let)[[:space:]]+(defaultBaseURL|defaultModel|suggestedModels)[[:space:]]*:|mozheAPIDisplayName|mozheAPIBaseURL|openai\.mozhevip\.top'

# Match the retired provider-profile facts, not legitimate fields such as
# `defaultModelID`. OhMyZsh has an unrelated download-service base URL.
hits=$(rg -n --glob '*.swift' --glob '*.rs' "$PATTERN" Stacio StacioCore/src \
  | rg -v 'Stacio/Services/ConversationPersistence/LegacyConversationHistoryAdapter.swift' \
  | rg -v 'Stacio/Services/OhMyZshResourceManager.swift' \
  | rg -v 'V1ConfigurationMigration.swift' || true)

if [ -n "$hits" ]; then
  echo "FAIL: provider URL/model facts referenced outside the versioned Catalog:" >&2
  echo "$hits" >&2
  echo "second-source constant scan: failed" >&2
  exit 1
fi
echo "second-source constant scan: OK"
