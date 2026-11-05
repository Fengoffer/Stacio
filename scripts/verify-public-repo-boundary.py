#!/usr/bin/env python3
"""守住公开仓库边界：竞品分析、内部文档、内部截图、后台与官网源码不得进入公开仓库。

用法：
  # 检查当前 HEAD 的树（默认）
  python3 scripts/verify-public-repo-boundary.py

  # 检查指定提交/分支
  python3 scripts/verify-public-repo-boundary.py --ref origin/main

  # 检查暂存区（提交前）
  python3 scripts/verify-public-repo-boundary.py --staged

  # 扫描全部历史（用于判断是否需要重写历史，较慢）
  python3 scripts/verify-public-repo-boundary.py --history

  # 只扫密钥特征，不看路径
  python3 scripts/verify-public-repo-boundary.py --secrets-only

退出码：0 未越界；1 发现越界或密钥特征。
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_CONFIG = Path("config/public-repo-boundary.json")


def git(*args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *args], capture_output=True, text=True, check=False
    )
    if check and result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} 失败：{result.stderr.strip()}")
    return result.stdout


def load_config(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as stream:
        config = json.load(stream)
    if config.get("schemaVersion") != 1:
        raise SystemExit("不支持的配置版本")
    return config


def exception_allowed(path: str, exceptions: list[dict]) -> str | None:
    for entry in exceptions:
        prefix = entry.get("path", "")
        if prefix and path.startswith(prefix):
            return entry.get("reason", "")
    return None


def path_violations(paths: list[str], config: dict) -> list[tuple[str, str]]:
    """返回 (违规路径, 命中的禁用前缀) 列表。"""
    forbidden = config.get("forbiddenPaths", [])
    exceptions = config.get("allowedExceptions", [])
    hits: list[tuple[str, str]] = []
    for path in paths:
        if exception_allowed(path, exceptions):
            continue
        for prefix in forbidden:
            if path == prefix.rstrip("/") or path.startswith(prefix):
                hits.append((path, prefix))
                break
    return hits


def tree_paths(ref: str) -> list[str]:
    return [line for line in git("ls-tree", "-r", "--name-only", ref).splitlines() if line]


def staged_paths() -> list[str]:
    return [
        line
        for line in git("diff", "--cached", "--name-only", "--diff-filter=ACMR").splitlines()
        if line
    ]


def compile_patterns(config: dict) -> list[re.Pattern[str]]:
    return [re.compile(pattern) for pattern in config.get("secretPatterns", [])]


def secret_violations(ref: str, config: dict) -> list[tuple[str, str]]:
    patterns = config.get("secretPatterns", [])
    if not patterns:
        return []
    allowlist = [entry.get("path", "") for entry in config.get("secretAllowlist", [])]
    hits: list[tuple[str, str]] = []
    args = ["grep", "-I", "-n", "-E"]
    for pattern in patterns:
        args.extend(["-e", pattern])
    args.extend(["--", "."])
    # 只扫描文本文件；-I 跳过二进制
    output = git(*args, check=False)
    for line in output.splitlines():
        parts = line.split(":", 2)
        if len(parts) < 3:
            continue
        path = parts[0]
        if any(prefix and path.startswith(prefix) for prefix in allowlist):
            continue
        hits.append((path, parts[2].strip()[:120]))
    return hits


def report(title: str, items: list[str]) -> None:
    print(f"{title}：{len(items)} 项")
    for item in items[:50]:
        print(f"  - {item}")
    if len(items) > 50:
        print(f"  …… 另有 {len(items) - 50} 项未显示")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--ref", default="HEAD", help="要检查的提交或分支（默认 HEAD）")
    parser.add_argument("--staged", action="store_true", help="检查暂存区")
    parser.add_argument("--history", action="store_true", help="扫描全部历史（较慢）")
    parser.add_argument("--secrets-only", action="store_true", help="只扫描密钥特征")
    parser.add_argument("--skip-secrets", action="store_true", help="跳过密钥扫描")
    args = parser.parse_args(argv)

    config = load_config(args.config)
    failed = False

    if not args.secrets_only:
        if args.history:
            # 只扫指定引用的历史：本仓库对 GitHub 是 partial clone，
            # --all / --branches 可能触发联网补对象而失败。
            paths = sorted(set(filter(None, git("log", args.ref, "--name-only", "--pretty=format:").splitlines())))
            hits = path_violations(paths, config)
            if hits:
                failed = True
                print("=== 历史中的越界路径 ===")
                report("唯一路径", [f"{path}  (命中: {prefix})" for path, prefix in hits])
                print("\n注意：只要这些路径出现在历史中，推送整段历史就会把它们带上去。")
        else:
            paths = staged_paths() if args.staged else tree_paths(args.ref)
            label = "暂存区" if args.staged else f"{args.ref} 的树"
            hits = path_violations(paths, config)
            if hits:
                failed = True
                print(f"=== {label} 中越界 {len(hits)} 项 ===")
                for path, prefix in hits[:50]:
                    print(f"  - {path}  (命中: {prefix})")
            else:
                print(f"OK: {label} 未发现越界路径（检查 {len(paths)} 个文件）")

    if not args.skip_secrets:
        secrets = secret_violations(args.ref, config)
        if secrets:
            failed = True
            print(f"=== 疑似密钥特征 {len(secrets)} 项 ===")
            for path, snippet in secrets[:20]:
                print(f"  - {path}: {snippet}")
        else:
            print(f"OK: {args.ref} 未发现密钥特征")

    if failed:
        print("\n拒绝推送：内容超出公开仓库边界。请先移出这些文件或修正 .gitignore。")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
