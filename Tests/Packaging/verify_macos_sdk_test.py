#!/usr/bin/env python3
"""Exercise deployment checks across executable/dylib and universal inputs."""

import contextlib
import importlib.util
import io
from pathlib import Path
import struct
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("macos_sdk", ROOT / "scripts/verify-macos-sdk.py")
SDK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SDK)


def thin(cpu=0x100000C, file_type=6, minimum="14.0", sdk="27.0"):
    header = struct.pack("<8I", 0xFEEDFACF, cpu, 0, file_type, 1, 24, 0, 0)
    return header + struct.pack("<6I", 0x32, 24, 1, SDK.version_number(minimum), SDK.version_number(sdk), 0)


def universal(arm64, x86_64):
    # Two valid architecture-table entries; offset alignment is 2**0.
    offset = 8 + 2 * 20
    return (struct.pack(">2I", 0xCAFEBABE, 2)
            + struct.pack(">5I", 0x100000C, 0, offset, len(arm64), 0)
            + struct.pack(">5I", 0x1000007, 0, offset + len(arm64), len(x86_64), 0)
            + arm64 + x86_64)


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.binary = Path(self.temp.name) / "component"

    def check(self, data):
        self.binary.write_bytes(data)
        with contextlib.redirect_stdout(io.StringIO()):
            SDK.verify_deployment(self.binary)

    def test_accepts_helpers_and_core_with_macos_14(self):
        for file_type in (2, 6):
            with self.subTest(file_type=file_type):
                self.check(thin(file_type=file_type))

    def test_rejects_newer_core_despite_valid_main_executable(self):
        self.binary.write_bytes(thin(file_type=2))
        with contextlib.redirect_stdout(io.StringIO()):
            SDK.verify(self.binary, "27.0")
        with self.assertRaisesRegex(ValueError, "minimum macOS 15.0.0 must remain 14.0"):
            self.check(thin(minimum="15.0"))

    def test_rejects_older_core_target_too(self):
        with self.assertRaisesRegex(ValueError, "minimum macOS 11.0.0 must remain 14.0"):
            self.check(thin(minimum="11.0"))

    def test_checks_every_universal_slice(self):
        arm = thin()
        self.check(universal(arm, thin(cpu=0x1000007)))
        with self.assertRaisesRegex(ValueError, "x86_64 minimum macOS 15.0.0"):
            self.check(universal(arm, thin(cpu=0x1000007, minimum="15.0")))

    def test_rejects_non_binary_and_object_files(self):
        for data in (b"#!/bin/sh\n", thin(file_type=1)):
            with self.subTest(data=data), self.assertRaises(ValueError):
                self.check(data)

    def test_main_sdk_guard_still_requires_executable_and_selected_sdk(self):
        self.binary.write_bytes(thin())
        with self.assertRaises(ValueError):
            SDK.verify(self.binary, "27.0")
        self.binary.write_bytes(thin(file_type=2, sdk="14.0"))
        with self.assertRaisesRegex(ValueError, "linked SDK 14.0.0"):
            SDK.verify(self.binary, "27.0")


if __name__ == "__main__":
    unittest.main()
