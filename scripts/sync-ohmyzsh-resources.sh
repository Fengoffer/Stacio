#!/usr/bin/env bash
# 同步 oh-my-zsh vendored 快照：assets/oh-my-zsh（事实源）→ Stacio/Resources/OhMyZsh（SwiftPM 资源）。
# 更新上游后必须执行本脚本，保证两份内容一致。
#
# 附加模式：
#   sync-ohmyzsh-resources.sh --release [--version X.Y.Z] [--out DIR]
#     除同步外，额外构建可下载的发布快照：
#       <out>/snapshot.tar.gz     （OhMyZsh 内容 + Nerd Font 及其原始许可证）
#       <out>/manifest.json       （{version, sizeBytes, sha256, downloadPath}，供客户端下载校验）
#   该产物用于后台服务器（ops-platform ohMyZshResources 路由）分发；app 默认不内置 oh-my-zsh 资源。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/assets/oh-my-zsh"
TARGET="$ROOT_DIR/Stacio/Resources/OhMyZsh"
FONT_SOURCE="$ROOT_DIR/Stacio/Resources/Fonts/JetBrainsMonoNLNerdFont-Regular.ttf"
FONT_LICENSE_SOURCE="$ROOT_DIR/Stacio/Resources/Fonts/NerdFonts-OFL.txt"

RELEASE_MODE=0
RELEASE_VERSION="${OMZ_SNAPSHOT_VERSION:-}"
RELEASE_OUT="$ROOT_DIR/dist/oh-my-zsh-resources"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE_MODE=1; shift ;;
    --version) RELEASE_VERSION="$2"; shift 2 ;;
    --out) RELEASE_OUT="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -d "$SOURCE" ]]; then
  echo "oh-my-zsh vendored 快照不存在: $SOURCE" >&2
  echo "请先按 docs/superpowers/plans/2026-08-04-ohmyzsh-integration-plan.md P0-1 流程 vendor。" >&2
  exit 1
fi

# 校验事实源哈希（排除 Stacio 附加元数据 README/THIRD_PARTY_LICENSES.md 及仓库管理文件）。
# 常规文件记录相对路径与内容哈希；符号链接记录相对路径、类型和原始 target，避免链接
# 目标被改写却未进入供应链摘要。
snapshot_source_hash() {
  python3 - "$SOURCE" <<'PY'
import hashlib
import os
import sys

root = os.path.abspath(sys.argv[1])
excluded_names = {"README", "THIRD_PARTY_LICENSES.md", ".gitignore", ".DS_Store"}
records = []
for current, directories, files in os.walk(root, topdown=True, followlinks=False):
    directories.sort()
    files.sort()
    for name in directories + files:
        path = os.path.join(current, name)
        if name in excluded_names:
            continue
        relative = os.path.relpath(path, root)
        if os.path.islink(path):
            records.append(f"L\0{relative}\0{os.readlink(path)}\n".encode())
        elif os.path.isfile(path):
            with open(path, "rb") as stream:
                content_hash = hashlib.sha256(stream.read()).hexdigest()
            records.append(f"F\0{relative}\0{content_hash}\n".encode())
records.sort()
hasher = hashlib.sha256()
for record in records:
    hasher.update(record)
print(hasher.hexdigest())
PY
}

expected="$(grep -oE '[0-9a-f]{64}' "$SOURCE/README" | head -1 || true)"
actual="$(snapshot_source_hash)"
if [[ -z "$expected" ]]; then
  echo "无法从 $SOURCE/README 读取预期哈希" >&2
  exit 1
fi
if [[ "$expected" != "$actual" ]]; then
  echo "oh-my-zsh 快照哈希不匹配（供应链校验失败）" >&2
  echo "预期: $expected" >&2
  echo "实测: $actual" >&2
  echo "请检查 $SOURCE 是否被篡改；如为有意更新，请更新 README 哈希。" >&2
  exit 1
fi

expected_font="$(grep -A2 'Nerd Font SHA-256' "$SOURCE/README" | grep -oE '[0-9a-f]{64}' | head -1 || true)"
if [[ ! -f "$FONT_SOURCE" ]]; then
  echo "缺少 Nerd Font: $FONT_SOURCE" >&2
  exit 1
fi
if [[ ! -f "$FONT_LICENSE_SOURCE" ]]; then
  echo "缺少 Nerd Font 许可证: $FONT_LICENSE_SOURCE" >&2
  exit 1
fi
actual_font="$(shasum -a 256 "$FONT_SOURCE" | awk '{print $1}')"
if [[ -z "$expected_font" ]]; then
  echo "无法从 $SOURCE/README 读取 Nerd Font 预期哈希" >&2
  exit 1
fi
if [[ "$expected_font" != "$actual_font" ]]; then
  echo "Nerd Font 哈希不匹配（供应链校验失败）" >&2
  echo "预期: $expected_font" >&2
  echo "实测: $actual_font" >&2
  echo "请检查 $FONT_SOURCE 是否被篡改；如为有意更新，请更新 README 哈希并提升资源版本。" >&2
  exit 1
fi

rm -rf "$TARGET"
mkdir -p "$TARGET"
cp -R "$SOURCE/." "$TARGET/"
echo "已同步 $SOURCE -> $TARGET"
echo "（如需移除 .DS_Store 等 macOS 杂项，请同步后手动清理）"

if [[ "$RELEASE_MODE" == "1" ]]; then
  if [[ -z "$RELEASE_VERSION" ]]; then
    RELEASE_VERSION="$(date +%Y.%m.%d).$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo local)"
  fi
  echo "构建发布快照 version=$RELEASE_VERSION ..."
  STAGING="$(mktemp -d)"
  trap 'rm -rf "$STAGING"' EXIT
  cp -R "$TARGET/." "$STAGING/"
  mkdir -p "$STAGING/fonts"
  cp "$FONT_SOURCE" "$STAGING/fonts/"
  cp "$FONT_LICENSE_SOURCE" "$STAGING/fonts/"
  mkdir -p "$RELEASE_OUT"
  TARBALL="$RELEASE_OUT/snapshot.tar.gz"
  rm -f "$TARBALL"
  (cd "$STAGING" && tar -czf "$TARBALL" .)
  SHA256="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
  SIZE_BYTES="$(stat -f%z "$TARBALL")"
  cat > "$RELEASE_OUT/manifest.json" <<EOF
{
  "version": "$RELEASE_VERSION",
  "sizeBytes": $SIZE_BYTES,
  "sha256": "$SHA256",
  "downloadPath": "snapshot.tar.gz"
}
EOF
  echo "发布快照: $TARBALL ($SIZE_BYTES bytes)"
  echo "manifest : $RELEASE_OUT/manifest.json (sha256=$SHA256)"
fi
