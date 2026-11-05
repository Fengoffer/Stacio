import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/verify-source-checkout.py"
spec = importlib.util.spec_from_file_location("source_checkout", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SourceCheckoutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "Stacio"
        self.root.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Source Test")
        self.git("config", "user.email", "source-test@invalid.local")
        (self.root / "Stacio").mkdir()
        (self.root / "Stacio/Main.swift").write_text("// integrated app\n")
        (self.root / "Package.swift").write_text("// package\n")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True)

    def test_primary_checkout_records_committed_content(self):
        result = module.provenance(self.root, self.root)
        self.assertEqual(result["sourceFileCount"], 2)
        self.assertEqual(len(result["sourceSHA256"]), 64)
        self.assertEqual(result, module.provenance(self.root, self.root))

    def test_hidden_linked_worktree_is_rejected(self):
        hidden = Path(self.temp.name) / ".hidden/Stacio"
        self.git("worktree", "add", "--detach", str(hidden), "HEAD")
        with self.assertRaisesRegex(ValueError, "primary checkout"):
            module.provenance(hidden, self.root)

    def test_dirty_and_untracked_source_are_rejected(self):
        source = self.root / "Stacio/Main.swift"
        original = source.read_text()
        source.write_text(original + "// pending fix\n")
        with self.assertRaisesRegex(ValueError, "uncommitted"):
            module.provenance(self.root)
        source.write_text(original)
        (self.root / "Stacio/MissingFeature.swift").write_text("// untracked feature\n")
        with self.assertRaisesRegex(ValueError, "untracked"):
            module.provenance(self.root)

    def test_ignored_source_cannot_silently_enter_package(self):
        (self.root / ".git/info/exclude").write_text("Stacio/Hidden.swift\n")
        (self.root / "Stacio/Hidden.swift").write_text("// hidden build input\n")
        with self.assertRaisesRegex(ValueError, "Unversioned build input"):
            module.provenance(self.root)

    def test_ignored_resources_in_hidden_directory_are_rejected(self):
        resource = self.root / "Stacio/Resources/.recovered/icon.svg"
        resource.parent.mkdir(parents=True)
        (self.root / ".git/info/exclude").write_text("Stacio/Resources/\n")
        resource.write_text("<svg/>\n")
        with self.assertRaisesRegex(ValueError, "Unversioned build input"):
            module.provenance(self.root)

    def test_finder_metadata_does_not_block_packaging(self):
        (self.root / ".git/info/exclude").write_text(".DS_Store\n")
        (self.root / "Stacio/.DS_Store").write_bytes(b"finder metadata")
        self.assertEqual(module.provenance(self.root)["sourceFileCount"], 2)

    def test_changed_commit_invalidates_saved_provenance(self):
        manifest = Path(self.temp.name) / "SourceProvenance.json"
        manifest.write_text(json.dumps(module.provenance(self.root)))
        (self.root / "Stacio/Main.swift").write_text("// another release\n")
        self.git("add", ".")
        self.git("commit", "-qm", "changed source")
        result = subprocess.run(["python3", str(SCRIPT), "--root", str(self.root),
                                 "--check-manifest", str(manifest)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Source changed during packaging", result.stderr)


if __name__ == "__main__":
    unittest.main()
