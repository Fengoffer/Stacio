#!/usr/bin/env python3
"""Verify the authoritative, committed app source and record its provenance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

SOURCE_PATHS = [
    "Package.swift", "Package.resolved", "Stacio", "StacioCore", "StacioAdapters",
    "StacioAgentBridge", "StacioCLI", "StacioExecutable", "Vendor", "Tests",
    "scripts", "config", "packaging", "logo/icon-legacy.icns",
    "package.json", "package-lock.json",
]
IGNORED_DIRECTORIES = {".git", ".build", "target", "node_modules", "__pycache__"}
IGNORED_FILES = {".DS_Store"}


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.PIPE)


def provenance(root, expected_root=None):
    root = root.resolve()
    top = Path(os.fsdecode(git(root, "rev-parse", "--show-toplevel")).strip()).resolve()
    common = Path(os.fsdecode(git(root, "rev-parse", "--path-format=absolute", "--git-common-dir")).strip()).resolve()
    if root != top or common != root / ".git" or not (root / ".git").is_dir():
        raise ValueError("Packaging requires the primary checkout; hidden/linked worktrees are recovery sources only.")
    if expected_root is not None and root != expected_root.expanduser().resolve():
        raise ValueError(f"Authoritative source is {expected_root.expanduser().resolve()}, not {root}.")
    changes = git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--", *SOURCE_PATHS)
    if changes:
        raise ValueError("App source has uncommitted or untracked changes. Review and commit the integrated source before packaging.")
    files = sorted(p for p in git(root, "ls-files", "-z", "--", *SOURCE_PATHS).split(b"\0") if p)
    tracked = {os.fsdecode(p) for p in files}
    for name in SOURCE_PATHS:
        path = root / name
        if not path.is_dir():
            continue
        for directory, children, names in os.walk(path):
            children[:] = [child for child in children if child not in IGNORED_DIRECTORIES]
            for name in names:
                candidate = Path(directory) / name
                relative = candidate.relative_to(root).as_posix()
                if name not in IGNORED_FILES and relative not in tracked:
                    raise ValueError(f"Unversioned build input (including ignored files): {relative}")
    digest = hashlib.sha256()
    for name in files:
        path = root / os.fsdecode(name)
        content = os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes()
        digest.update(name + b"\0" + hashlib.sha256(content).digest())
    return {
        "schemaVersion": 1,
        "sourceRoot": str(root),
        "commit": os.fsdecode(git(root, "rev-parse", "HEAD")).strip(),
        "branch": os.fsdecode(git(root, "rev-parse", "--abbrev-ref", "HEAD")).strip(),
        "sourceFileCount": len(files),
        "sourceSHA256": digest.hexdigest(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--expected-root", type=Path)
    parser.add_argument("--check-manifest", type=Path)
    args = parser.parse_args()
    try:
        result = provenance(args.root, args.expected_root)
        if args.check_manifest and json.loads(args.check_manifest.read_text()) != result:
            raise ValueError("Source changed during packaging; rebuild from a single reviewed commit.")
        print(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Source checkout verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
