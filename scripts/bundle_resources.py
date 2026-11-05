#!/usr/bin/env python3
"""Stacio 应用包资源清单的单一真源工具。

用法：
  # 打印 package-app.sh 中应出现的资源拷贝片段（供人工核对或写入）
  python3 scripts/bundle_resources.py --write-package-block

  # 把生成的片段写入 package-app.sh 的标记区（先备份）
  python3 scripts/bundle_resources.py --apply-package-block scripts/package-app.sh

  # 校验 package-app.sh 的标记区与清单是否一致（CI / 打包前使用）
  python3 scripts/bundle_resources.py --check-package-block scripts/package-app.sh

退出码：0 一致；1 不一致或出错。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

BEGIN_MARKER = "# BEGIN GENERATED: bundle-resources"
END_MARKER = "# END GENERATED: bundle-resources"

COPY_KINDS = {"tree", "tree-contents", "file"}


def load_manifest(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as stream:
        manifest = json.load(stream)
    if manifest.get("schemaVersion") != 1:
        raise SystemExit(f"unsupported manifest schemaVersion: {manifest.get('schemaVersion')!r}")
    seen = set()
    for entry in manifest.get("entries", []):
        entry_id = entry.get("id")
        if not entry_id:
            raise SystemExit("every manifest entry needs an id")
        if entry_id in seen:
            raise SystemExit(f"duplicate manifest entry id: {entry_id}")
        seen.add(entry_id)
        kind = entry.get("kind")
        if kind not in COPY_KINDS and kind != "build-product":
            raise SystemExit(f"{entry_id}: unsupported kind {kind!r}")
        if not entry.get("destination"):
            raise SystemExit(f"{entry_id}: missing destination")
        if kind in COPY_KINDS and not entry.get("source"):
            raise SystemExit(f"{entry_id}: missing source")
    return manifest


def copy_entries(manifest: dict) -> list[dict]:
    """需要由 package-app.sh 执行的拷贝项（按清单顺序）。"""
    return [
        entry
        for entry in manifest.get("entries", [])
        if entry.get("kind") in COPY_KINDS
        and entry.get("container", "Resources") == "Resources"
        and entry.get("shipped", True) is not False
    ]


def all_entries(manifest: dict) -> list[dict]:
    return list(manifest.get("entries", []))


def _source_path(entry: dict) -> str:
    """返回可放进双引号里的源路径表达式（不含外层引号）。"""
    explicit = entry.get("sourceExpression")
    if explicit:
        return explicit
    return f"$ROOT_DIR/{entry['source']}"


def shell_lines(manifest: dict) -> list[str]:
    """生成 package-app.sh 的资源拷贝片段（不含首尾标记）。"""
    lines: list[str] = []
    created_dirs: set[str] = set()

    def mkdir(dir_expression: str) -> str:
        if dir_expression in created_dirs:
            return ""
        created_dirs.add(dir_expression)
        return f'mkdir -p "{dir_expression}"'

    for entry in copy_entries(manifest):
        destination = entry["destination"]
        kind = entry["kind"]
        source = _source_path(entry)
        target = f"$RESOURCES_DIR/{destination}"
        target_dir = _parent_dir(destination)

        body: list[str] = []
        if kind == "file":
            if target_dir:
                line = mkdir(f"$RESOURCES_DIR/{target_dir}")
                if line:
                    body.append(line)
            body.append(f'cp "{source}" "{target}"')
        elif kind == "tree-contents":
            line = mkdir(target)
            if line:
                body.append(line)
            body.append(f'cp -R "{source}/." "{target}/"')
        elif kind == "tree":
            if target_dir:
                line = mkdir(f"$RESOURCES_DIR/{target_dir}")
                if line:
                    body.append(line)
            body.append(f'cp -R "{source}" "{target}"')
        else:  # pragma: no cover - guarded by load_manifest
            raise SystemExit(f"{entry['id']}: cannot generate copy for kind {kind!r}")

        if entry.get("xattrClean") and kind in {"tree", "tree-contents"}:
            body.append(f'/usr/bin/xattr -cr "{target}"')

        if entry.get("sourceOptional"):
            body = [f'if [[ -d "{source}" ]]; then'] + [f"  {line}" for line in body] + ["fi"]

        if lines:
            lines.append("")
        lines.extend(body)
    return lines


def full_block(manifest: dict) -> str:
    header = [
        BEGIN_MARKER,
        "# 由 scripts/bundle_resources.py --apply-package-block 生成，请勿手改。",
        "# 清单来源：config/bundle-resources.json",
    ]
    footer = [END_MARKER]
    return "\n".join(header + shell_lines(manifest) + footer)


def _parent_dir(destination: str) -> str:
    if "/" not in destination:
        return ""
    return destination.rsplit("/", 1)[0]


def extract_block(script_text: str) -> str | None:
    pattern = re.compile(
        re.escape(BEGIN_MARKER) + r".*?" + re.escape(END_MARKER),
        re.DOTALL,
    )
    match = pattern.search(script_text)
    return match.group(0) if match else None


def check_package_block(script_path: Path, manifest: dict) -> int:
    script_text = script_path.read_text(encoding="utf-8")
    actual = extract_block(script_text)
    if actual is None:
        print(
            f"ERROR: {script_path} 缺少生成标记 {BEGIN_MARKER} … {END_MARKER}",
            file=sys.stderr,
        )
        return 1
    expected = full_block(manifest)
    if actual.strip() != expected.strip():
        print(
            f"ERROR: {script_path} 的资源拷贝片段与 config/bundle-resources.json 不一致。\n"
            f"       运行 python3 scripts/bundle_resources.py --apply-package-block {script_path} 重新生成。",
            file=sys.stderr,
        )
        return 1
    print(f"OK: {script_path} 的资源拷贝片段与清单一致")
    return 0


def apply_package_block(script_path: Path, manifest: dict) -> int:
    script_text = script_path.read_text(encoding="utf-8")
    actual = extract_block(script_text)
    if actual is None:
        print(
            f"ERROR: {script_path} 缺少生成标记 {BEGIN_MARKER} … {END_MARKER}，拒绝改写。",
            file=sys.stderr,
        )
        return 1
    expected = full_block(manifest)
    if actual.strip() == expected.strip():
        print(f"OK: {script_path} 已是最新，无需修改")
        return 0
    backup = script_path.with_suffix(script_path.suffix + ".bak")
    backup.write_text(script_text, encoding="utf-8")
    script_path.write_text(script_text.replace(actual, expected), encoding="utf-8")
    print(f"已更新 {script_path}（备份：{backup}）")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path("config/bundle-resources.json"),
        help="清单路径（默认 config/bundle-resources.json）",
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--write-package-block", action="store_true", help="打印资源拷贝片段")
    group.add_argument("--apply-package-block", type=Path, metavar="SCRIPT", help="写入 package-app.sh 标记区")
    group.add_argument("--check-package-block", type=Path, metavar="SCRIPT", help="校验标记区与清单一致")
    group.add_argument("--print-entries", action="store_true", help="打印清单条目摘要")
    args = parser.parse_args(argv)

    manifest = load_manifest(args.manifest)

    if args.write_package_block:
        print(full_block(manifest))
        return 0
    if args.apply_package_block:
        return apply_package_block(args.apply_package_block, manifest)
    if args.check_package_block:
        return check_package_block(args.check_package_block, manifest)
    if args.print_entries:
        for entry in all_entries(manifest):
            print(
                f"{entry['id']:<26} {entry.get('container', 'Resources'):<11} "
                f"{entry['kind']:<15} required={str(entry.get('required', True)):<5} "
                f"-> {entry['destination']}"
            )
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
