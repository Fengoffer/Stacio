#!/usr/bin/env python3
"""Verify Stacio's linked SDK and deployment targets, including prebuilt inputs."""

import argparse
import json
import plistlib
import re
import struct
from pathlib import Path


def version_number(value):
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError(f"Invalid macOS SDK version: {value!r}")
    parts = [int(part) for part in value.split(".")]
    parts += [0] * (3 - len(parts))
    if parts[0] > 65535 or any(part > 255 for part in parts[1:]):
        raise ValueError(f"Invalid macOS SDK version: {value!r}")
    return (parts[0] << 16) | (parts[1] << 8) | parts[2]


def format_version(value):
    return f"{value >> 16}.{(value >> 8) & 255}.{value & 255}"


def sdk_version(path):
    path = Path(path)
    if (path / "SDKSettings.json").is_file():
        settings = json.loads((path / "SDKSettings.json").read_text())
    else:
        with (path / "SDKSettings.plist").open("rb") as stream:
            settings = plistlib.load(stream)
    version = str(settings["Version"])
    if version_number(version) < version_number("26.0"):
        raise ValueError(f"macOS SDK {version} is too old for Stacio's native toolbar appearance; use SDK 26 or newer.")
    return version


def macho_sdks(data, file_types=(2,)):
    """Read every native slice without depending on the selected Xcode tools."""
    magic = data[:4]
    fat = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
           b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
    if magic in fat:
        endian, wide = fat[magic]
        count = struct.unpack_from(endian + "I", data, 4)[0]
        entry_size = 32 if wide else 20
        if count == 0 or 8 + count * entry_size > len(data):
            raise ValueError("Invalid universal Mach-O architecture table")
        result = []
        for index in range(count):
            entry = 8 + index * entry_size
            offset, size = struct.unpack_from(endian + ("QQ" if wide else "II"), data, entry + 8)
            if offset < 8 + count * entry_size or size == 0 or offset + size > len(data):
                raise ValueError("Invalid universal Mach-O slice")
            if data[offset:offset + 4] in fat:
                raise ValueError("Nested universal Mach-O slice")
            result.extend(macho_sdks(data[offset:offset + size], file_types))
        return result

    thin = {b"\xcf\xfa\xed\xfe": ("<", 32), b"\xce\xfa\xed\xfe": ("<", 28),
            b"\xfe\xed\xfa\xcf": (">", 32), b"\xfe\xed\xfa\xce": (">", 28)}
    if magic not in thin:
        raise ValueError("Input is not a Mach-O binary")
    endian, header_size = thin[magic]
    _, cpu, _, file_type, count, commands_size, _ = struct.unpack_from(endian + "7I", data)
    end = header_size + commands_size
    if file_type not in file_types or end > len(data):
        raise ValueError("Invalid Mach-O binary header or file type")
    offset = header_size
    versions = []
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError("Truncated Mach-O load command")
        command, size = struct.unpack_from(endian + "II", data, offset)
        if size < 8 or offset + size > end:
            raise ValueError("Invalid Mach-O load command size")
        if command == 0x32:  # LC_BUILD_VERSION
            if size < 24:
                raise ValueError("Truncated LC_BUILD_VERSION")
            platform, minimum, sdk = struct.unpack_from(endian + "III", data, offset + 8)
            if platform != 1:
                raise ValueError("Mach-O binary contains a non-macOS slice")
            versions.append((cpu, minimum, sdk))
        offset += size
    if offset != end or len(versions) != 1:
        raise ValueError("Mach-O binary must contain one macOS LC_BUILD_VERSION per architecture")
    return versions


def verify(path, expected_sdk):
    expected = version_number(expected_sdk)
    if expected < version_number("26.0"):
        raise ValueError("Stacio requires macOS SDK 26 or newer to retain its native toolbar appearance")
    slices = macho_sdks(Path(path).read_bytes())
    for cpu, minimum, sdk in slices:
        arch = {0x100000c: "arm64", 0x1000007: "x86_64"}.get(cpu, hex(cpu))
        if sdk != expected:
            raise ValueError(f"Stacio {arch} linked SDK {format_version(sdk)} does not match selected SDK {expected_sdk}; "
                             "rebuild with scripts/package-app.sh. An incorrect SDK changes native macOS controls.")
        if minimum != version_number("14.0"):
            raise ValueError(f"Stacio {arch} minimum macOS {format_version(minimum)} must remain 14.0")
    print(f"Verified Stacio linked macOS SDK {expected_sdk} ({len(slices)} architecture(s)); minimum macOS 14.0")


def verify_deployment(path):
    path = Path(path)
    # MH_EXECUTE and MH_DYLIB: check every slice of our helpers and Rust core.
    for cpu, minimum, _ in macho_sdks(path.read_bytes(), file_types=(2, 6)):
        arch = {0x100000c: "arm64", 0x1000007: "x86_64"}.get(cpu, hex(cpu))
        if minimum != version_number("14.0"):
            raise ValueError(f"{path.name} {arch} minimum macOS {format_version(minimum)} must remain 14.0")
    print(f"Verified {path.name} minimum macOS 14.0")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    version = commands.add_parser("sdk-version")
    version.add_argument("sdk_path")
    check = commands.add_parser("verify")
    check.add_argument("binary")
    check.add_argument("expected_sdk")
    deployment = commands.add_parser("verify-deployment")
    deployment.add_argument("binaries", nargs="+")
    args = parser.parse_args()
    try:
        if args.command == "sdk-version":
            print(sdk_version(args.sdk_path))
        elif args.command == "verify":
            verify(args.binary, args.expected_sdk)
        else:
            for binary in args.binaries:
                verify_deployment(binary)
    except (OSError, ValueError, KeyError, struct.error) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
