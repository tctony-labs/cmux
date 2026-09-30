"""Exercise the archive entry point with real Mach-O binaries and dSYMs."""

import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/archive-release-symbols.py"


def command(*args):
    return subprocess.check_output(args, text=True).strip()


class ReleaseSymbolsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = tempfile.TemporaryDirectory(prefix="cmux-symbol-fixtures-")
        cls.addClassCleanup(cls.fixtures.cleanup)
        cls.products = Path(cls.fixtures.name) / "Release with spaces"
        cls.app = cls.products / "cmux.app"
        cls.binaries = [
            cls.app / "Contents/MacOS/cmux",
            cls.app / "Contents/Resources/bin/cmux",
            cls.app / "Contents/PlugIns/CmuxDockTilePlugin.plugin/Contents/MacOS/CmuxDockTilePlugin",
        ]
        cls.dsym_names = ["cmux.app.dSYM", "cmux.dSYM", "CmuxDockTilePlugin.plugin.dSYM"]
        source = Path(cls.fixtures.name) / "fixture.c"
        source.write_text("int cmux_symbol_fixture(void) { return 42; }\nint main(void) { return 0; }\n")
        for index, (binary, name) in enumerate(zip(cls.binaries, cls.dsym_names)):
            binary.parent.mkdir(parents=True, exist_ok=True)
            obj = Path(cls.fixtures.name) / f"fixture-{index}.o"
            subprocess.run(["xcrun", "clang", "-g", "-O1", "-arch", "arm64", str(source),
                            "-c", "-o", str(obj)], check=True)
            subprocess.run(["xcrun", "clang", "-arch", "arm64", str(obj),
                            "-o", str(binary)], check=True)
            subprocess.run(["xcrun", "dsymutil", str(binary), "-o", str(cls.products / name)], check=True)
            subprocess.run(["xcrun", "strip", "-S", str(binary)], check=True)
        with (cls.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": "cmux", "CFBundleShortVersionString": "1.2.3",
                          "CFBundleVersion": "456"}, stream)
        # A separate build provides a real UUID mismatch and an unsupported architecture.
        source.write_text("int main(void) { return 7; }\n")
        cls.other = Path(cls.fixtures.name) / "other"
        subprocess.run(["xcrun", "clang", "-g", "-arch", "arm64", str(source),
                        "-o", str(cls.other)], check=True)
        cls.intel = Path(cls.fixtures.name) / "intel"
        subprocess.run(["xcrun", "clang", "-g", "-arch", "x86_64", str(source),
                        "-o", str(cls.intel)], check=True)
        cls.no_debug = Path(cls.fixtures.name) / "no-debug"
        subprocess.run(["xcrun", "clang", "-arch", "arm64", str(source),
                        "-o", str(cls.no_debug)], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-symbol-test-")
        self.addCleanup(self.temp.cleanup)
        self.products = Path(self.temp.name) / "Release with spaces"
        shutil.copytree(type(self).products, self.products)
        self.app = self.products / "cmux.app"
        self.output = Path(self.temp.name) / "cmux-tctony-symbols.zip"

    def run_archive(self, error=None):
        result = subprocess.run(["python3", str(SCRIPT), str(self.app), str(self.output)],
                                cwd=ROOT, text=True, capture_output=True)
        if error is None:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(error, result.stderr)
            self.assertFalse(self.output.exists())
        return result

    def dwarf(self, index=0):
        return self.products / self.dsym_names[index] / "Contents/Resources/DWARF" / self.binaries[index].name

    def test_archive_round_trip_and_symbolication(self):
        self.run_archive()
        with zipfile.ZipFile(self.output) as archive:
            self.assertIsNone(archive.testzip())
            archive.extractall(Path(self.temp.name) / "extracted")
        extracted = Path(self.temp.name) / "extracted/cmux-tctony-symbols"
        metadata = json.loads((extracted / "metadata.json").read_text())
        self.assertEqual(metadata["source_commit"], command("git", "rev-parse", "HEAD"))
        self.assertEqual(metadata["app_version"], "1.2.3")
        self.assertEqual(metadata["build_number"], "456")
        self.assertEqual(metadata["xcode_version"], command("xcodebuild", "-version"))
        self.assertEqual(len(metadata["symbols"]), 3)
        for record in metadata["symbols"]:
            dwarf = extracted / record["dsym"] / "Contents/Resources/DWARF" / Path(record["executable"]).name
            binary = self.app / record["executable"]
            self.assertTrue(dwarf.is_file())
            self.assertEqual(record["architecture"], "arm64")
            self.assertIn(record["uuid"], command("xcrun", "dwarfdump", "--uuid", str(binary)))
            self.assertIn(record["uuid"], command("xcrun", "dwarfdump", "--uuid", str(dwarf)))
        dwarf = extracted / "cmux.app.dSYM/Contents/Resources/DWARF/cmux"
        symbol = next(line for line in command("xcrun", "nm", str(dwarf)).splitlines()
                      if line.endswith(" _cmux_symbol_fixture"))
        resolved = command("xcrun", "atos", "-arch", "arm64", "-o", str(dwarf), "0x" + symbol.split()[0])
        self.assertIn("cmux_symbol_fixture", resolved)

    def test_missing_dsym(self):
        for name in self.dsym_names:
            with self.subTest(dsym=name):
                original = self.products / name
                moved = self.products / (name + ".saved")
                original.rename(moved)
                self.run_archive("Missing dSYM")
                moved.rename(original)

    def test_missing_dwarf(self):
        self.dwarf().unlink()
        self.run_archive("Missing or empty DWARF")

    def test_missing_executable(self):
        (self.app / "Contents/Resources/bin/cmux").unlink()
        self.run_archive("Missing executable")

    def test_empty_dwarf(self):
        self.dwarf().write_bytes(b"")
        self.run_archive("Missing or empty DWARF")

    def test_uuid_mismatch(self):
        shutil.copy2(self.other, self.app / "Contents/MacOS/cmux")
        self.run_archive("UUID mismatch")

    def test_wrong_executable_architecture(self):
        shutil.copy2(self.intel, self.app / "Contents/MacOS/cmux")
        self.run_archive("Expected one arm64 UUID")

    def test_wrong_dwarf_architecture(self):
        shutil.copy2(self.intel, self.dwarf())
        self.run_archive("Expected one arm64 UUID")

    def test_uuid_without_debug_info_is_rejected(self):
        shutil.copy2(self.no_debug, self.app / "Contents/MacOS/cmux")
        shutil.copy2(self.no_debug, self.dwarf())
        self.run_archive("Missing DWARF compile units")


if __name__ == "__main__":
    unittest.main()
