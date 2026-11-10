#!/usr/bin/env bash
#本地一键验证：把分散的检查串成一条命令。
#
#用法：
# ./scripts/verify-all.sh #快速验证（约1-2分钟）
# ./scripts/verify-all.sh --full #完整验证（含全部测试与真实打包，约10分钟）
#
#为什么需要这个脚本：
# GitHub托管的 runner无法构建本仓库（需要 Xcode27/SDK26+），
#自托管 runner又受网络限制，所以构建验证放在本地。
#这个脚本把"该验什么"固化下来，不需要记一堆命令。
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MODE="${1:-quick}"
FAILURES=0
CHECKS=0

pass() {
    CHECKS=$((CHECKS +1))
    printf " [PASS] %s\n" "$1"
}

fail() {
    CHECKS=$((CHECKS +1))
    FAILURES=$((FAILURES +1))
    printf " [FAIL] %s\n" "$1"
}

run_check() {
    local label="$1"
    shift
    if "$@" >/tmp/stacio-verify-step.log 2>&1; then
        pass "$label"
    else
        fail "$label"
        tail -20 /tmp/stacio-verify-step.log | sed "s/^/ /"
    fi
}

echo "=========================================="
echo " Stacio验证 ($MODE)"
echo "=========================================="
echo

echo "[1/6]公开仓库边界"
run_check "边界：无内部文档/截图/竞品分析" \
    python3 scripts/verify-public-repo-boundary.py
echo

echo "[2/6]资源清单一致性"
run_check "Package.swift与清单一致" \
    python3 scripts/bundle_resources.py --check-package-swift Package.swift
run_check "package-app.sh拷贝片段与清单一致" \
    python3 scripts/bundle_resources.py --check-package-block scripts/package-app.sh
echo

echo "[3/6]版本号"
run_check "版本可从 config/release.json读取" \
    ./scripts/print-version.sh
echo

echo "[4/6]脚本语法"
run_check "shell语法" \
    bash -c 'for s in scripts/*.sh Tests/Packaging/*.sh; do bash -n "$s" || exit 1; done'
run_check "python编译" \
    python3 -m py_compile scripts/bundle_resources.py scripts/verify-bundle-contents.py scripts/verify-public-repo-boundary.py
echo

echo "[5/6]打包流程"
run_check "打包测试（含产物内容校验+符号一致性）" \
    bash Tests/Packaging/package_app_test.sh
echo

echo "[6/6]测试套件"
if [ "$MODE" = "--full" ]; then
    echo "运行完整 Swift测试（约6分钟）..."
    if DYLD_LIBRARY_PATH="$ROOT_DIR/StacioCore/target/debug" \
        swift test --build-system native >/tmp/stacio-verify-swift.log 2>&1; then
        SUMMARY=$(grep -oE "Executed [0-9]+ tests,.*" /tmp/stacio-verify-swift.log | tail -1)
        pass "Swift测试：$SUMMARY"
    else
        fail "Swift测试"
        grep -E "Test Case.*failed|Executed [0-9]+ tests" /tmp/stacio-verify-swift.log | tail -10 | sed "s/^/ /"
    fi
    echo "运行 Rust测试..."
    if cargo test --manifest-path StacioCore/Cargo.toml --lib >/tmp/stacio-verify-rust.log 2>&1; then
        SUMMARY=$(grep -oE "test result: ok\. [0-9]+ passed.*" /tmp/stacio-verify-rust.log | tail -1)
        pass "Rust测试：$SUMMARY"
    else
        fail "Rust测试"
        tail -15 /tmp/stacio-verify-rust.log | sed "s/^/ /"
    fi
else
    echo "跳过（加 --full运行4937个 Swift测试 +650个 Rust测试）"
fi
echo

echo "=========================================="
if [ "$FAILURES" -eq 0 ]; then
    echo "结果：全部通过（${CHECKS}项检查）"
    echo "=========================================="
    exit 0
else
    echo "结果：${FAILURES}项失败 /共 ${CHECKS}项"
    echo "=========================================="
    exit 1
fi
