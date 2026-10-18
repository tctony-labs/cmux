#!/usr/bin/env python3
"""Prepare a scheduled patch release, or resume an unfinished release."""

from datetime import datetime
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from zoneinfo import ZoneInfo


PROJECT = "cmux.xcodeproj/project.pbxproj"
ASSETS = {"cmux-tctony.dmg", "appcast.xml", "cmux-tctony-symbols.zip"}


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def run(*args):
    subprocess.run(args, check=True)


def version_number(tag):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise RuntimeError(f"Invalid release tag: {tag}")
    return tuple(int(part) for part in tag[1:].split("."))


def project_version():
    text = Path(PROJECT).read_text()
    versions = set(re.findall(r"MARKETING_VERSION = ([0-9.]+);", text))
    builds = set(re.findall(r"CURRENT_PROJECT_VERSION = ([0-9]+);", text))
    if len(versions) != 1 or len(builds) != 1:
        raise RuntimeError("Expected one consistent marketing version and build number")
    version = versions.pop()
    version_number(f"v{version}")
    return version


def release(repository, selector):
    result = subprocess.run(
        ["gh", "api", f"repos/{repository}/releases/{selector}"],
        capture_output=True,
        text=True,
    )
    if result.returncode:
        if "(HTTP 404)" in result.stderr:
            return None
        raise RuntimeError(f"Unable to read release metadata: {result.stderr.strip()}")
    return json.loads(result.stdout)


def is_published(metadata):
    if not metadata or metadata["draft"] or metadata["prerelease"]:
        return False
    uploaded = {asset["name"] for asset in metadata["assets"] if asset["state"] == "uploaded"}
    return ASSETS <= uploaded


def output(tag, message):
    print(message, flush=True)
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        stream.write(f"tag={tag}\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as stream:
            stream.write(message + "\n")


def push_tag(tag):
    run("git", "tag", tag)
    run("git", "push", "origin", f"refs/tags/{tag}")
    output(tag, f"Prepared {tag}; continuing with the existing build and release jobs.")


def update_changelog(version, previous_tag):
    subjects = git("log", "--reverse", "--format=%s", f"{previous_tag}..HEAD").splitlines()
    entries = ["- " + html.escape(subject, quote=False) for subject in subjects]
    date = datetime.now(ZoneInfo("Asia/Shanghai")).date().isoformat()
    section = f"## [{version}] - {date}\n\n### Changed\n" + "\n".join(entries) + "\n\n"
    path = Path("CHANGELOG.md")
    text = path.read_text()
    if re.search(rf"^## \[{re.escape(version)}\]", text, re.MULTILINE):
        raise RuntimeError(f"Changelog already contains {version}")
    first_version = re.search(r"^## \[", text, re.MULTILINE)
    if not first_version:
        raise RuntimeError("Unable to find the existing changelog releases")
    path.write_text(text[:first_version.start()] + section + text[first_version.start():])


def prepare():
    if git("status", "--porcelain"):
        raise RuntimeError("Scheduled releases require a clean checkout")
    repository = os.environ["GITHUB_REPOSITORY"]
    version = project_version()
    tag = f"v{version}"
    latest = release(repository, "latest")
    if latest and version_number(latest["tag_name"]) > version_number(tag):
        raise RuntimeError("develop is older than the latest release; refusing to publish")

    tag_exists = subprocess.run(
        ["git", "show-ref", "--verify", "--quiet", f"refs/tags/{tag}"]
    ).returncode == 0
    if not tag_exists:
        # A previous run may have pushed its version commit before the tag push failed.
        subject = f"Release {tag} (scheduled)"
        prepared = git("log", "-1", "--format=%H", "--fixed-strings", f"--grep={subject}")
        if not prepared or git("show", "-s", "--format=%s", prepared) != subject:
            raise RuntimeError(f"Missing {tag}; finish the pending manual release first")
        run("git", "switch", "--detach", prepared)
        run("./scripts/release-pretag-guard.sh")
        push_tag(tag)
        return

    run("git", "merge-base", "--is-ancestor", tag, "HEAD")
    metadata = latest if latest and latest["tag_name"] == tag else release(
        repository, f"tags/{tag}"
    )
    if not is_published(metadata):
        output(tag, f"Retrying unfinished release {tag}; the version will not be incremented.")
        return
    if git("rev-parse", "HEAD") == git("rev-parse", f"{tag}^{{commit}}"):
        output("", f"No new commits on develop since {tag}; skipping release.")
        return

    major, minor, patch = version_number(tag)
    expected_version = f"{major}.{minor}.{patch + 1}"
    new_tag = f"v{expected_version}"
    if subprocess.run(
        ["git", "show-ref", "--verify", "--quiet", f"refs/tags/{new_tag}"]
    ).returncode == 0:
        raise RuntimeError(f"{new_tag} already exists; refusing to prepare a conflicting release")
    run("./scripts/bump-version.sh", "patch")
    new_version = project_version()
    if new_version != expected_version:
        raise RuntimeError("The scheduled release must increment exactly one patch version")
    update_changelog(new_version, tag)
    run("./scripts/release-pretag-guard.sh")
    run("git", "add", "--", PROJECT, "CHANGELOG.md")
    run(
        "git", "-c", "user.name=github-actions[bot]",
        "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
        "commit", "-m", f"Release {new_tag} (scheduled)",
    )
    run("git", "push", "origin", "HEAD:refs/heads/develop")
    push_tag(new_tag)


if __name__ == "__main__":
    try:
        prepare()
    except (RuntimeError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Scheduled release preparation failed: {error}", file=sys.stderr)
        sys.exit(1)
