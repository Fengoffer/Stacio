#!/usr/bin/env bash
set -euo pipefail

if ! command -v cargo >/dev/null 2>&1; then
  if [ -x "$HOME/.cargo/bin/cargo" ]; then
    export PATH="$HOME/.cargo/bin:$PATH"
  else
    echo "cargo is required to generate UniFFI bindings. Install Rust with rustup first." >&2
    exit 127
  fi
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

./scripts/build-core.sh
rm -rf Stacio/Bridge/Generated
mkdir -p \
  Stacio/Bridge/Generated/Sources \
  Stacio/Bridge/Generated/Headers

pushd "$ROOT_DIR/StacioCore" >/dev/null

cargo run \
  --bin uniffi-bindgen-swift \
  -- target/debug/libstacio_core.dylib \
  ../Stacio/Bridge/Generated/Sources \
  --swift-sources

cargo run \
  --bin uniffi-bindgen-swift \
  -- target/debug/libstacio_core.dylib \
  ../Stacio/Bridge/Generated/Headers \
  --headers

cargo run \
  --bin uniffi-bindgen-swift \
  -- target/debug/libstacio_core.dylib \
  ../Stacio/Bridge/Generated/Headers \
  --modulemap \
  --modulemap-filename module.modulemap \
  --module-name stacio_coreFFI

popd >/dev/null

SWIFT_BINDINGS="$ROOT_DIR/Stacio/Bridge/Generated/Sources/stacio_core.swift"
SWIFT_FFI_HEADER="$ROOT_DIR/Stacio/Bridge/Generated/Headers/stacio_coreFFI.h"

patch_swift_error_descriptions() {
  local swift_file="$1"

  perl -0pi -e 's#extension FilesError: Foundation\.LocalizedError \{\n    public var errorDescription: String\? \{\n        String\(reflecting: self\)\n    }\n}#extension FilesError: Foundation.LocalizedError {\n    public var errorDescription: String? {\n        switch self {\n        case .InvalidListingRow:\n            return "远程目录列表格式无效"\n        case .InvalidFileKind:\n            return "远程文件类型无效"\n        case .InvalidFileSize:\n            return "远程文件大小无效"\n        case .UnsafePath:\n            return "远程路径不安全"\n        }\n    }\n}#s' "$swift_file"

  perl -0pi -e 's#extension ScpTransferError: Foundation\.LocalizedError \{\n    public var errorDescription: String\? \{\n        String\(reflecting: self\)\n    }\n}#extension ScpTransferError: Foundation.LocalizedError {\n    public var errorDescription: String? {\n        switch self {\n        case .PermissionDenied:\n            return "文件传输权限不足"\n        case .Interrupted:\n            return "文件传输中断"\n        }\n    }\n}#s' "$swift_file"

  perl -0pi -e 's#extension SshRuntimeError: Foundation\.LocalizedError \{\n    public var errorDescription: String\? \{\n        String\(reflecting: self\)\n    }\n}#extension SshRuntimeError: Foundation.LocalizedError {\n    public var errorDescription: String? {\n        switch self {\n        case .InvalidConfig:\n            return "SSH 配置无效"\n        case .AuthFailed:\n            return "SSH 认证失败"\n        case .Timeout:\n            return "SSH 连接超时"\n        case .HostKeyChanged:\n            return "SSH 主机密钥已变更"\n        case .UnknownHostKey:\n            return "SSH 主机密钥未知"\n        case let .Transport(message):\n            return stacioUserFacingRuntimeMessage(message, prefix: "SSH")\n        }\n    }\n}#s' "$swift_file"

  perl -0pi -e 's#extension TerminalRuntimeError: Foundation\.LocalizedError \{\n    public var errorDescription: String\? \{\n        String\(reflecting: self\)\n    }\n}#extension TerminalRuntimeError: Foundation.LocalizedError {\n    public var errorDescription: String? {\n        switch self {\n        case .RuntimeNotFound:\n            return "终端会话不存在"\n        case .RuntimeClosed:\n            return "终端会话已关闭"\n        case let .RuntimeIo(message):\n            return "终端读写失败：" + stacioUserFacingRuntimeMessage(message)\n        }\n    }\n}#s' "$swift_file"

  cat >> "$swift_file" <<'SWIFT'

fileprivate func stacioUserFacingRuntimeMessage(_ message: String, prefix: String? = nil) -> String {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowercased = trimmed.lowercased()

    if lowercased.contains("would block") || trimmed.contains("Session(-37)") {
        return prefixed("通道暂时不可用，请稍后重试", prefix: prefix)
    }

    switch trimmed {
    case "FILES_PERMISSION_DENIED":
        return "文件传输权限不足"
    case "FILES_TRANSFER_INTERRUPTED":
        return "文件传输中断"
    case "FILES_TRANSFER_CANCELED":
        return "文件传输已取消"
    case "FILES_LOCAL_FILE_MISSING":
        return "本地文件不存在"
    case "FILES_LOCAL_WRITE_FAILED":
        return "本地文件写入失败"
    case "FILES_SIZE_MISMATCH":
        return "文件大小不一致"
    case "FILES_UNSAFE_PATH":
        return "远程路径不安全"
    case "FILES_REMOTE_COMMAND_FAILED":
        return "远程文件操作失败"
    case "FILES_REMOTE_LIST_PARSE_FAILED":
        return "远程目录列表解析失败"
    default:
        break
    }

    let replacements: [(String, String)] = [
        ("Input/output error", "设备输入输出错误"),
        ("input/output error", "设备输入输出错误"),
        ("No such file or directory", "设备不存在"),
        ("no such file or directory", "设备不存在"),
        ("Resource busy", "设备正忙"),
        ("resource busy", "设备正忙"),
        ("Device not configured", "设备未就绪"),
        ("device not configured", "设备未就绪"),
        ("Operation not permitted", "没有操作权限"),
        ("operation not permitted", "没有操作权限"),
        ("Inappropriate ioctl for device", "设备不支持该操作"),
        ("inappropriate ioctl for device", "设备不支持该操作"),
        ("Invalid argument", "参数无效"),
        ("invalid argument", "参数无效"),
        ("No such device", "设备不存在"),
        ("no such device", "设备不存在"),
        ("Bad file descriptor", "设备句柄无效"),
        ("bad file descriptor", "设备句柄无效"),
        ("Broken pipe", "连接管道已断开"),
        ("broken pipe", "连接管道已断开"),
        ("Authentication failed", "认证失败"),
        ("authentication failed", "认证失败"),
        ("Host key verification failed", "主机密钥验证失败"),
        ("host key verification failed", "主机密钥验证失败"),
        ("Connection closed", "连接已关闭"),
        ("connection closed", "连接已关闭"),
        ("Permission denied", "权限被拒绝"),
        ("permission denied", "权限被拒绝"),
        ("Connection reset by peer", "连接被远端重置"),
        ("connection reset by peer", "连接被远端重置"),
        ("Network is unreachable", "网络不可达"),
        ("network is unreachable", "网络不可达"),
        ("Connection refused", "连接被拒绝"),
        ("connection refused", "连接被拒绝"),
        ("No route to host", "无法到达主机"),
        ("no route to host", "无法到达主机"),
        ("Operation timed out", "连接超时"),
        ("operation timed out", "连接超时"),
        ("Connection timed out", "连接超时"),
        ("connection timed out", "连接超时"),
        ("Timed out", "连接超时"),
        ("timed out", "连接超时"),
        ("Timeout", "连接超时"),
        ("timeout", "连接超时")
    ]

    var translated = trimmed
    for (needle, replacement) in replacements {
        translated = translated.replacingOccurrences(of: needle, with: replacement)
    }

    if translated == trimmed {
        return trimmed
    }
    return prefixed(translated, prefix: prefix)
}

fileprivate func prefixed(_ message: String, prefix: String?) -> String {
    guard let prefix, !message.hasPrefix(prefix) else {
        return message
    }
    return "\(prefix) \(message)"
}
SWIFT

  if ! grep -q 'stacioUserFacingRuntimeMessage(message, prefix: "SSH")' "$swift_file"; then
    echo "failed to patch SshRuntimeError localized descriptions" >&2
    exit 1
  fi
  if ! grep -q "终端读写失败" "$swift_file"; then
    echo "failed to patch TerminalRuntimeError localized descriptions" >&2
    exit 1
  fi
  if ! grep -q "文件传输权限不足" "$swift_file"; then
    echo "failed to patch file transfer localized descriptions" >&2
    exit 1
  fi
}

patch_swift_error_descriptions "$SWIFT_BINDINGS"
perl -0pi -e 's/[ \t]+$//mg' "$SWIFT_BINDINGS" "$SWIFT_FFI_HEADER"
