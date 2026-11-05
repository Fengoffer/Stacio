#!/usr/bin/env python3
"""校验一个已打好的 Stacio.app 是否符合 config/bundle-resources.json。

这是"打包漏功能"的闸门：它打开最终产物，逐文件核对，而不是只看 git 是否干净。

用法：
  python3 scripts/verify-bundle-contents.py --app dist/0.15.2/build480-arm64/Stacio.app
  python3 scripts/verify-bundle-contents.py --app <path> --root . --manifest config/bundle-resources.json

退出码：
  0  产物完整（可能有警告）
  1  发现缺失 / 内容不一致 / 不该出现的文件 / 产物里写死了开发者绝对路径
"""

from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bundle_resources import load_manifest  # noqa: E402

IGNORED_NAMES = {".DS_Store"}
BINARY_CONTAINERS = ("MacOS", "Helpers", "Adapters")
USER_PATH_MARKER = b"/Users/"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def relative_files(root: Path) -> set[str]:
    found: set[str] = set()
    if not root.exists():
        return found
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if name in IGNORED_NAMES:
                continue
            found.add(str(Path(dirpath, name).relative_to(root)))
    return found


def resolve_source(entry: dict, repo_root: Path) -> Path | None:
    source = entry.get("source")
    if not source:
        return None
    if entry.get("sourceExternal"):
        override = os.environ.get("STACIO_MONACO_VS_PATH")
        if override:
            return Path(override)
    return repo_root / source


def check_core_symbols(app_dir: Path) -> tuple[list[str], list[str]]:
    """核对 app 主程序需要的 stacio_core 符号，打包进去的 dylib 全都导出。

    背景：Swift 构建默认链接 StacioCore/target/debug 里的 dylib，
    而打包放进去的是 target/release 的 dylib。两者源码不同步时，
    app 会在用户机器上因缺少符号而启动失败——本地却因为 debug 目录存在而正常。
    """
    executable = app_dir / "Contents" / "MacOS" / "Stacio"
    dylib = app_dir / "Contents" / "Frameworks" / "libstacio_core.dylib"
    if not executable.is_file() or not dylib.is_file():
        return [], []
    try:
        undefined_output = subprocess.run(
            ["nm", "-u", str(executable)], capture_output=True, text=True, check=False
        ).stdout
        defined_output = subprocess.run(
            ["nm", "-gU", str(dylib)], capture_output=True, text=True, check=False
        ).stdout
    except OSError:
        return [], ["无法运行 nm，跳过符号一致性检查"]

    required = {
        line.split()[-1]
        for line in undefined_output.splitlines()
        if "stacio_core" in line and line.split()
    }
    if not required:
        return [], ["主程序未引用 stacio_core 符号，跳过符号一致性检查"]
    provided = {line.split()[-1] for line in defined_output.splitlines() if line.split()}
    missing = sorted(required - provided)
    if missing:
        return (
            [
                f"打包的 libstacio_core.dylib 缺少主程序需要的 {len(missing)} 个符号，"
                f"例如 {', '.join(missing[:5])} —— 用户机器上会因缺符号启动失败"
            ],
            [],
        )
    return [], [f"符号一致性：主程序需要 {len(required)} 个 stacio_core 符号，已全部导出"]


def scan_for_user_paths(app_dir: Path) -> tuple[list[str], list[str]]:
    """扫描构建产物里的开发者绝对路径。

    区分两类：
      · 致命：路径指向构建目录（含 /.build/）或以 .bundle 结尾 —— 这是运行时会去读的资源回退路径，
        在用户机器上不存在，可能直接 fatalError。
      · 告警：普通源码路径（__FILE__ / panic 回溯 / 调试信息）—— 不会导致崩溃，但会泄露开发者用户名
        与工程目录结构，属于隐私与信息泄露问题。

    返回 (errors, warnings)。
    """
    errors: list[str] = []
    warnings: list[str] = []
    candidates: list[Path] = []
    contents = app_dir / "Contents"
    for container in BINARY_CONTAINERS:
        container_dir = contents / container
        if container_dir.is_dir():
            candidates.extend(p for p in container_dir.rglob("*") if p.is_file())
    frameworks = contents / "Frameworks"
    if frameworks.is_dir():
        candidates.extend(p for p in frameworks.rglob("*") if p.is_file() and p.suffix in {".dylib", ""})
    plist = contents / "Info.plist"
    if plist.is_file():
        candidates.append(plist)

    needle = USER_PATH_MARKER
    for path in candidates:
        dangerous: set[bytes] = set()
        other = 0
        other_sample: bytes | None = None
        try:
            data = path.read_bytes()
        except OSError:
            continue
        for raw in data.split(b"\x00"):
            index = raw.find(needle)
            while index != -1:
                snippet = raw[index:]
                # 只取到第一个换行/不可见位置附近，避免把整段二进制当成路径
                snippet = snippet[:512]
                if b".bundle" in snippet:
                    dangerous.add(snippet.strip())
                else:
                    other += 1
                    if other_sample is None:
                        other_sample = snippet.strip()
                index = raw.find(needle, index + 1)
        if dangerous:
            for sample in sorted(dangerous)[:3]:
                errors.append(
                    f"{path.relative_to(app_dir)}: 内嵌构建目录路径 "
                    f"{sample.decode('utf-8', 'replace')} —— 该路径在用户机器上不存在"
                )
        if other:
            sample_text = (other_sample or b"").decode("utf-8", "replace")
            warnings.append(
                f"{path.relative_to(app_dir)}: 含 {other} 处开发者源码路径（不会导致崩溃，"
                f"但泄露工程目录，建议发布构建剥离调试信息）。例如：{sample_text}"
            )
    return errors, warnings


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="Stacio.app 路径")
    parser.add_argument("--root", type=Path, default=Path("."), help="仓库根目录")
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path("config/bundle-resources.json"),
        help="资源清单",
    )
    parser.add_argument(
        "--strict-decisions",
        action="store_true",
        help="把尚未决策的条目（decisionPending）也当作错误",
    )
    parser.add_argument(
        "--skip-absolute-path-scan",
        action="store_true",
        help="跳过 /Users/ 绝对路径扫描（仅用于调试旧产物）",
    )
    args = parser.parse_args(argv)

    app_dir = args.app.resolve()
    if not (app_dir / "Contents").is_dir():
        print(f"ERROR: 不是有效的 .app：{app_dir}", file=sys.stderr)
        return 1

    repo_root = args.root.resolve()
    manifest = load_manifest(args.manifest)

    errors: list[str] = []
    warnings: list[str] = []
    checked = 0

    for entry in manifest.get("entries", []):
        entry_id = entry["id"]
        container = entry.get("container", "Resources")
        destination = entry["destination"]
        kind = entry["kind"]
        required = entry.get("required", True)
        target = app_dir / "Contents" / container / destination
        checked += 1

        # 有意不打包的资源
        if entry.get("shipped") is False:
            if target.exists():
                errors.append(
                    f"{entry_id}: 按清单不应打包，但产物里存在 {target.relative_to(app_dir)}"
                )
            elif entry.get("decisionPending") and args.strict_decisions:
                errors.append(
                    f"{entry_id}: 决策未定（{entry['decisionPending']}）且未打包，--strict-decisions 下视为错误"
                )
            elif entry.get("decisionPending"):
                warnings.append(
                    f"{entry_id}: 决策未定（{entry['decisionPending']}），当前按「不打包」处理"
                )
            continue

        # 构建产物：只查存在性
        if kind == "build-product":
            if required and not target.exists():
                errors.append(f"{entry_id}: 缺少构建产物 {target.relative_to(app_dir)}")
            continue

        # 源码资源
        if target.exists():
            # 存在：进一步核对内容
            source = resolve_source(entry, repo_root)
            if kind == "file":
                if source is not None and source.is_file():
                    if source.stat().st_size != target.stat().st_size:
                        errors.append(
                            f"{entry_id}: 大小不一致（源码 {source.stat().st_size} B，产物 {target.stat().st_size} B）"
                        )
                    elif sha256_file(source) != sha256_file(target):
                        errors.append(f"{entry_id}: 内容不一致（sha256 不同）")
            elif kind in {"tree", "tree-contents"}:
                if source is not None and source.is_dir():
                    expected_files = relative_files(source)
                    actual_files = relative_files(target)
                    missing = sorted(expected_files - actual_files)
                    if missing:
                        errors.append(
                            f"{entry_id}: 目录内缺少 {len(missing)} 个文件，例如 "
                            + ", ".join(missing[:5])
                        )
        else:
            source = resolve_source(entry, repo_root)
            if entry.get("sourceOptional"):
                continue
            if kind in {"tree", "tree-contents"} and source is not None and not source.is_dir():
                errors.append(f"{entry_id}: 源码目录不存在，无法打包：{entry.get('source')}")
            elif required:
                errors.append(f"{entry_id}: 缺少 {target.relative_to(app_dir)}")

    # 主程序与打包 dylib 的符号一致性
    symbol_errors, symbol_notes = check_core_symbols(app_dir)
    errors.extend(symbol_errors)
    warnings.extend(symbol_notes)

    # 产物中的开发者绝对路径
    if not args.skip_absolute_path_scan:
        path_errors, path_warnings = scan_for_user_paths(app_dir)
        errors.extend(path_errors)
        warnings.extend(path_warnings)

    print(f"校验对象：{app_dir}")
    print(f"清单条目：{checked}")
    for warning in warnings:
        print(f"  [警告] {warning}")
    if errors:
        print(f"\n发现 {len(errors)} 个问题：")
        for index, message in enumerate(errors, start=1):
            print(f"  {index:>2}. {message}")
        return 1

    print("结果：通过（产物内容与 config/bundle-resources.json 一致）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
