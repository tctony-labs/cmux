#!/usr/bin/env python3
"""Behavioral coverage for the standalone settings writer."""

import json
import os
from pathlib import Path
import runpy
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "skills/cmux-settings/scripts/cmux-settings"


class SettingsSymlinkTests(unittest.TestCase):
    def run_cli(self, path, *args):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--file", str(path), *args],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_set_and_unset_preserve_links_and_target_permissions(self):
        for kind in ("regular", "absolute", "relative", "chain"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                target = root / "stored" / "settings.json"
                target.parent.mkdir()
                target.write_text('{"app":{"preferredEditor":"code"}}\n')
                target.chmod(0o640)
                config = root / "cmux.json"
                links = []
                if kind == "regular":
                    config = target
                elif kind == "absolute":
                    config.symlink_to(target)
                    links.append(config)
                elif kind == "relative":
                    config.symlink_to("stored/settings.json")
                    links.append(config)
                else:
                    intermediate = root / "intermediate.json"
                    intermediate.symlink_to("stored/settings.json")
                    config.symlink_to("intermediate.json")
                    links.extend([config, intermediate])
                destinations = {link: os.readlink(link) for link in links}

                for command in (("set", "app.openMarkdownInCmuxViewer", "true"),
                                ("unset", "app.openMarkdownInCmuxViewer")):
                    self.run_cli(config, *command)
                    for link, destination in destinations.items():
                        self.assertTrue(link.is_symlink())
                        self.assertEqual(os.readlink(link), destination)
                    expected = {"app": {"preferredEditor": "code"}}
                    if command[0] == "set":
                        expected["app"]["openMarkdownInCmuxViewer"] = True
                    self.assertEqual(json.loads(target.read_text()), expected)
                    self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o640)

    def test_unchanged_value_does_not_rewrite(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target.json"
            target.write_text('{ "app": { "openMarkdownInCmuxViewer": true } }\n')
            config = Path(directory) / "cmux.json"
            config.symlink_to(target.name)
            before = target.stat()
            contents = target.read_bytes()
            self.run_cli(config, "set", "app.openMarkdownInCmuxViewer", "true")
            self.assertTrue(config.is_symlink())
            self.assertEqual(target.stat().st_ino, before.st_ino)
            self.assertEqual(target.stat().st_mtime_ns, before.st_mtime_ns)
            self.assertEqual(target.read_bytes(), contents)

    def test_dangling_link_creates_target_without_replacing_link(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "cmux.json"
            target = Path(directory) / "new" / "target.json"
            config.symlink_to("new/target.json")
            self.run_cli(config, "set", "app.openMarkdownInCmuxViewer", "true")
            self.assertTrue(config.is_symlink())
            self.assertTrue(json.loads(target.read_text())["app"]["openMarkdownInCmuxViewer"])

    def test_failed_replace_preserves_files_and_cleans_temporary_file(self):
        writer = runpy.run_path(str(SCRIPT))["atomic_write"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target.json"
            target.write_text('{"app":{}}\n')
            config = root / "cmux.json"
            config.symlink_to(target.name)
            before = target.read_bytes()
            with patch("os.replace", side_effect=PermissionError("simulated write failure")):
                with self.assertRaises(PermissionError):
                    writer(config, {"app": {"openMarkdownInCmuxViewer": True}})
            self.assertTrue(config.is_symlink())
            self.assertEqual(target.read_bytes(), before)
            self.assertEqual(set(root.iterdir()), {config, target})


if __name__ == "__main__":
    unittest.main()
