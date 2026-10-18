"""Exercise scheduled releases against real local Git remotes and a fixture GitHub API."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/prepare-scheduled-release.py"
PROJECT = "cmux.xcodeproj/project.pbxproj"


class ScheduledReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-scheduled-release-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.remote = self.root / "origin.git"
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.command("git", "init", "--bare", str(self.remote))
        self.command("git", "init", "-b", "develop", str(self.repo))
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release-test@example.com")
        self.git("config", "commit.gpgsign", "false")
        self.git("remote", "add", "origin", str(self.remote))
        (self.repo / PROJECT).parent.mkdir(parents=True)
        (self.repo / PROJECT).write_text(
            "MARKETING_VERSION = 1.2.3;\nCURRENT_PROJECT_VERSION = 10;\n"
        )
        (self.repo / "CHANGELOG.md").write_text("# Changelog\n\n## [1.2.3] - 2026-01-01\n")
        for filename in [
            "scripts/bump-version.sh", "scripts/release-pretag-guard.sh",
            "tests/test_ci_sparkle_build_monotonic.sh",
        ]:
            target = self.repo / filename
            target.parent.mkdir(exist_ok=True)
            shutil.copy2(ROOT / filename, target)
        self.commit("Initial release")
        self.git("tag", "v1.2.3")
        self.git("push", "origin", "HEAD:refs/heads/develop", "refs/tags/v1.2.3")

        self.fixture = self.root / "releases.json"
        self.release_data = {"latest": self.published_release("v1.2.3")}
        self.save_releases()
        appcast = self.root / "appcast.xml"
        appcast.write_text("<sparkle:version>50</sparkle:version>\n")
        binary_dir = self.root / "bin"
        binary_dir.mkdir()
        gh = binary_dir / "gh"
        gh.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "if os.environ.get('MOCK_API_FAILURE'):\n"
            "    print('gh: API unavailable (HTTP 503)', file=sys.stderr)\n"
            "    sys.exit(1)\n"
            "with open(os.environ['MOCK_RELEASES']) as stream:\n"
            "    releases = json.load(stream)\n"
            "selector = sys.argv[2].split('/releases/', 1)[1]\n"
            "if selector not in releases:\n"
            "    print('gh: Not Found (HTTP 404)', file=sys.stderr)\n"
            "    sys.exit(1)\n"
            "print(json.dumps(releases[selector]))\n"
        )
        gh.chmod(0o755)
        self.output = self.root / "output"
        self.env = {
            **os.environ,
            "PATH": str(binary_dir) + os.pathsep + os.environ["PATH"],
            "GITHUB_REPOSITORY": "example/cmux",
            "GITHUB_OUTPUT": str(self.output),
            "GITHUB_STEP_SUMMARY": str(self.root / "summary"),
            "MOCK_RELEASES": str(self.fixture),
            "CMUX_RELEASE_APPCAST_URL": appcast.as_uri(),
        }

    def command(self, *args, cwd=None):
        return subprocess.check_output(
            args, cwd=cwd, text=True, stderr=subprocess.STDOUT
        ).strip()

    def git(self, *args):
        return self.command("git", *args, cwd=self.repo)

    def commit(self, subject):
        self.git("add", ".")
        self.git("commit", "-m", subject)

    def add_change(self, subject="Fix Markdown preview toolbar"):
        path = self.repo / "source.txt"
        path.write_text(path.read_text() + "change\n" if path.exists() else "change\n")
        self.commit(subject)
        self.git("push", "origin", "HEAD:refs/heads/develop")

    def published_release(self, tag):
        return {
            "tag_name": tag,
            "draft": False,
            "prerelease": False,
            "assets": [
                {"name": name, "state": "uploaded"}
                for name in ["cmux-tctony.dmg", "appcast.xml", "cmux-tctony-symbols.zip"]
            ],
        }

    def save_releases(self):
        self.fixture.write_text(json.dumps(self.release_data))

    def prepare(self, success=True, extra_env=None):
        self.output.write_text("")
        result = subprocess.run(
            [sys.executable, str(SCRIPT)], cwd=self.repo,
            env={**self.env, **(extra_env or {})}, capture_output=True, text=True,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def remote_ref(self, ref):
        return self.command("git", "--git-dir", str(self.remote), "rev-parse", ref)

    def install_push_hook(self, rejected_ref):
        hook = self.remote / "hooks/pre-receive"
        hook.write_text(
            "#!/bin/sh\nwhile read old new ref; do\n"
            f"  if [ \"$ref\" = '{rejected_ref}' ]; then exit 1; fi\n"
            "done\n"
        )
        hook.chmod(0o755)
        return hook

    def test_unchanged_develop_skips_release(self):
        original = self.git("rev-parse", "HEAD")
        result = self.prepare()
        self.assertIn("skipping release", result.stdout)
        self.assertEqual(self.output.read_text(), "tag=\n")
        self.assertEqual(self.git("rev-parse", "HEAD"), original)
        self.assertEqual(self.remote_ref("develop"), original)

    def test_update_pushes_patch_version_changelog_and_matching_tag(self):
        self.add_change()
        self.prepare()
        self.assertEqual(self.output.read_text(), "tag=v1.2.4\n")
        project = (self.repo / PROJECT).read_text()
        self.assertIn("MARKETING_VERSION = 1.2.4;", project)
        self.assertIn("CURRENT_PROJECT_VERSION = 51;", project)
        changelog = (self.repo / "CHANGELOG.md").read_text()
        self.assertLess(changelog.index("## [1.2.4]"), changelog.index("## [1.2.3]"))
        self.assertIn("- Fix Markdown preview toolbar", changelog)
        self.assertEqual(self.remote_ref("develop"), self.remote_ref("v1.2.4"))
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_failed_release_reuses_tag_even_with_new_develop_commits(self):
        self.add_change()
        self.prepare()
        prepared = self.remote_ref("v1.2.4")
        self.add_change("Another fix waiting for the next release")
        head = self.git("rev-parse", "HEAD")
        result = self.prepare()
        self.assertIn("Retrying unfinished release v1.2.4", result.stdout)
        self.assertEqual(self.output.read_text(), "tag=v1.2.4\n")
        self.assertEqual(self.git("rev-parse", "HEAD"), head)
        self.assertEqual(self.remote_ref("v1.2.4"), prepared)
        self.assertNotIn("v1.2.5", self.git("tag"))

    def test_successful_release_does_not_create_another_patch_without_updates(self):
        self.add_change()
        self.prepare()
        self.release_data["latest"] = self.published_release("v1.2.4")
        self.save_releases()
        self.prepare()
        self.assertEqual(self.output.read_text(), "tag=\n")
        self.assertNotIn("v1.2.5", self.git("tag"))

    def test_incomplete_assets_retry_existing_version(self):
        self.release_data["latest"]["assets"].pop()
        self.save_releases()
        self.prepare()
        self.assertEqual(self.output.read_text(), "tag=v1.2.3\n")
        self.assertNotIn("v1.2.4", self.git("tag"))

    def test_api_outage_does_not_change_or_publish_anything(self):
        self.add_change()
        original = self.git("rev-parse", "HEAD")
        self.prepare(success=False, extra_env={"MOCK_API_FAILURE": "1"})
        self.assertEqual(self.git("rev-parse", "HEAD"), original)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.output.read_text(), "")

    def test_conflicting_next_tag_fails_before_changing_the_checkout(self):
        self.add_change()
        self.git("tag", "v1.2.4")
        original = self.git("rev-parse", "HEAD")
        result = self.prepare(success=False)
        self.assertIn("v1.2.4 already exists", result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD"), original)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.output.read_text(), "")

    def test_branch_push_failure_does_not_push_a_tag(self):
        self.add_change()
        original = self.remote_ref("develop")
        self.install_push_hook("refs/heads/develop")
        self.prepare(success=False)
        self.assertEqual(self.remote_ref("develop"), original)
        self.assertNotIn("v1.2.4", self.git("tag"))
        self.assertEqual(self.output.read_text(), "")

    def test_tag_push_failure_resumes_prepared_commit_in_a_fresh_checkout(self):
        self.add_change()
        hook = self.install_push_hook("refs/tags/v1.2.4")
        self.prepare(success=False)
        prepared = self.remote_ref("develop")
        hook.unlink()
        self.repo = self.root / "fresh-checkout"
        self.command("git", "clone", "-b", "develop", str(self.remote), str(self.repo))
        self.prepare()
        self.assertEqual(self.output.read_text(), "tag=v1.2.4\n")
        self.assertEqual(self.remote_ref("v1.2.4"), prepared)
        self.assertNotIn("v1.2.5", self.git("tag"))


if __name__ == "__main__":
    unittest.main()
