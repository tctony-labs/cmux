"""Exercise the CI entry point with isolated sources and downloadable archives."""
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHA = 'a' * 40


class PrebuiltRequiredTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / 'scripts'
        scripts.mkdir()
        for name in ('ensure-ghosttykit.sh', 'download-prebuilt-ghosttykit.sh',
                     'validate-xcframework-archive.py'):
            shutil.copy2(ROOT / 'scripts' / name, scripts / name)
        (self.root / 'ghostty/include').mkdir(parents=True)
        (self.root / 'ghostty/include/ghostty.h').touch()
        (self.root / 'ghostty.h').write_text('#include "ghostty/include/ghostty.h"\n')
        self.archive = self.root / 'fixture.tar.gz'
        self.make_archive('GhosttyKit.xcframework/marker')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.stub('git', f'case "$*" in *rev-parse*) echo {SHA} ;; esac\n')
        self.stub('curl', '''echo called >> "$TEST_ROOT/downloads"
if [ "${TEST_DOWNLOAD_FAIL:-0}" = 1 ]; then exit 22; fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then cp "$TEST_ROOT/fixture.tar.gz" "$2"; exit; fi
  shift
done
exit 1
''')
        self.stub('zig', 'touch "$TEST_ROOT/source-build"; exit 99\n')
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        TEST_ROOT=str(self.root), CMUX_GHOSTTYKIT_REQUIRE_PREBUILT='1',
                        CMUX_GHOSTTYKIT_CACHE_DIR=str(self.root / 'cache'))
        self.env.pop('CMUX_GHOSTTYKIT_NO_PREBUILT', None)

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\nset -eu\n' + body)
        path.chmod(0o755)

    def make_archive(self, member):
        with tarfile.open(self.archive, 'w:gz') as archive:
            directory = tarfile.TarInfo('GhosttyKit.xcframework')
            directory.type = tarfile.DIRTYPE
            directory.mode = 0o755
            archive.addfile(directory)
            info = tarfile.TarInfo(member)
            info.size = 2
            archive.addfile(info, io.BytesIO(b'ok'))
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        (self.root / 'scripts/ghosttykit-checksums.txt').write_text(f'{SHA} {digest}\n')

    def run_entry(self, success):
        result = subprocess.run([str(self.root / 'scripts/ensure-ghosttykit.sh')],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.assertFalse((self.root / 'source-build').exists())
        return result

    def test_download_then_verified_cache_without_network(self):
        self.run_entry(True)
        self.env['TEST_DOWNLOAD_FAIL'] = '1'
        result = self.run_entry(True)
        self.assertIn('Reusing cached', result.stdout)
        self.assertEqual((self.root / 'downloads').read_text().splitlines(), ['called'])

    def test_missing_checksum(self):
        (self.root / 'scripts/ghosttykit-checksums.txt').write_text('')
        self.run_entry(False)
        self.assertFalse((self.root / 'downloads').exists())

    def test_wrong_checksum(self):
        (self.root / 'scripts/ghosttykit-checksums.txt').write_text(f'{SHA} {"0" * 64}\n')
        self.run_entry(False)

    def test_download_failure(self):
        self.env['TEST_DOWNLOAD_FAIL'] = '1'
        self.run_entry(False)

    def test_unsafe_archive(self):
        self.make_archive('../escape')
        self.run_entry(False)
        self.assertFalse((self.root / 'escape').exists())

    def test_source_built_cache_is_not_accepted(self):
        cached = self.root / 'cache' / SHA / 'GhosttyKit.xcframework'
        cached.mkdir(parents=True)
        self.env['TEST_DOWNLOAD_FAIL'] = '1'
        self.run_entry(False)


if __name__ == '__main__':
    unittest.main()
