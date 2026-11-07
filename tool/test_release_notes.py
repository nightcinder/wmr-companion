#!/usr/bin/env python3
"""Tests for tool/release_notes.py; no network access is needed.

The history tests build a throwaway git repository in a temp directory and run
in it, because ``previous_tag`` and ``changes_since`` shell out to git.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release_notes  # noqa: E402


class VersionFromTagTest(unittest.TestCase):
    def test_release_tag(self) -> None:
        self.assertEqual(release_notes.version_from_tag("v0.3.6"), "0.3.6")

    def test_dry_run_tag_names_the_next_version(self) -> None:
        self.assertEqual(release_notes.version_from_tag("v0.3.6-dryrun"), "0.3.6")

    def test_tag_without_v(self) -> None:
        self.assertEqual(release_notes.version_from_tag("0.3.6"), "0.3.6")


class ParseSubjectTest(unittest.TestCase):
    def test_squash_commit_is_a_pull_request(self) -> None:
        change = release_notes.parse_subject(
            "Android XR: request the full permission set and start crash-safely (ONY-614) (#145)",
            "b1ae413000000000000000000000000000000000",
        )
        self.assertEqual(change.number, 145)
        self.assertEqual(
            change.title,
            "Android XR: request the full permission set and start crash-safely (ONY-614)",
        )

    def test_merge_commit_is_a_pull_request(self) -> None:
        change = release_notes.parse_subject(
            "Merge pull request #123 from nightcinder/ony-123-thing",
            "a" * 40,
        )
        self.assertEqual(change.number, 123)

    def test_direct_commit_has_no_pull_request(self) -> None:
        change = release_notes.parse_subject("Fix a typo", "abc1234")
        self.assertIsNone(change.number)
        self.assertEqual(change.sha, "abc1234")


class ThrowawayGitRepositoryTest(unittest.TestCase):
    """Runs each test in a fresh repository, since ``release_notes.git`` uses cwd."""

    def setUp(self) -> None:
        self._original_cwd = Path.cwd()
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self._tmp.name)
        os.chdir(self.repo)
        self.git("init", "--quiet", "--initial-branch=main")
        self.git("config", "user.name", "Release Notes Test")
        self.git("config", "user.email", "release-notes@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")

    def tearDown(self) -> None:
        os.chdir(self._original_cwd)
        self._tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", *args], check=True, capture_output=True, text=True
        ).stdout.strip()

    def commit(self, subject: str, tag: str | None = None) -> str:
        history = self.repo / "history.txt"
        previous = history.read_text(encoding="utf-8") if history.exists() else ""
        history.write_text(f"{previous}{subject}\n", encoding="utf-8")
        self.git("add", "history.txt")
        self.git("commit", "--quiet", "-m", subject)
        if tag is not None:
            self.git("tag", tag)
        return self.git("rev-parse", "HEAD")


class PreviousTagTest(ThrowawayGitRepositoryTest):
    def test_no_previous_tag_is_reported(self) -> None:
        self.commit("Initial release", tag="v0.3.6")

        with self.assertRaises(SystemExit) as raised:
            release_notes.previous_tag("v0.3.6")

        self.assertIn("no previous version tag", str(raised.exception))

    def test_previous_tag_is_the_stable_tag_before_it(self) -> None:
        self.commit("Release 0.3.5", tag="v0.3.5")
        pr_sha = self.commit("Companion: host the player (#146)")
        release_sha = self.commit("Release: bump to 0.3.6", tag="v0.3.6")

        self.assertEqual(release_notes.previous_tag("v0.3.6"), "v0.3.5")
        self.assertEqual(
            release_notes.changes_since("v0.3.5", "v0.3.6"),
            [
                release_notes.Change("Companion: host the player", 146, pr_sha),
                release_notes.Change("Release: bump to 0.3.6", None, release_sha),
            ],
        )

    def test_dry_run_tag_is_not_the_previous_tag(self) -> None:
        self.commit("Release 0.3.5", tag="v0.3.5")
        self.commit("Companion: host the player (#146)", tag="v0.3.6-dryrun")
        self.commit("Release: bump to 0.3.6", tag="v0.3.6")

        self.assertEqual(release_notes.previous_tag("v0.3.6"), "v0.3.5")

    def test_pre_release_tags_are_skipped(self) -> None:
        self.commit("Release 0.3.5", tag="v0.3.5")
        self.commit("Companion: host the player (#146)", tag="v0.3.6-test")
        rc_sha = self.commit("Fix a typo (#147)", tag="v0.3.6-rc1")
        self.commit("Release: bump to 0.3.6", tag="v0.3.6")

        self.assertEqual(release_notes.previous_tag("v0.3.6"), "v0.3.5")
        self.assertEqual(release_notes.previous_tag("v0.3.6-rc1"), "v0.3.5")

        changes = release_notes.changes_since("v0.3.5", "v0.3.6")
        self.assertEqual(
            [change.title for change in changes],
            [
                "Companion: host the player",
                "Fix a typo",
                "Release: bump to 0.3.6",
            ],
        )
        self.assertEqual(changes[1].sha, rc_sha)


class RenderBodyTest(unittest.TestCase):
    def render(self, assets: list[str], changes: list[release_notes.Change]) -> str:
        return release_notes.render_body(
            version="0.3.6",
            tag="v0.3.6",
            sha="0123456789abcdef",
            previous="v0.3.5",
            changes=changes,
            assets=assets,
            repo="nightcinder/wmr-companion",
        )

    def test_body_names_pull_requests_and_assets(self) -> None:
        body = self.render(
            [
                "wmr-companion-0.3.6-unified-arm64-v8a.apk",
                "SHA256SUMS",
            ],
            [
                release_notes.Change("Companion: host the player", 146, "a" * 40),
                release_notes.Change("Fix a typo", None, "b" * 40),
            ],
        )
        self.assertIn("WMR Companion 0.3.6", body)
        self.assertIn("since v0.3.5", body)
        self.assertIn("**Companion: host the player**", body)
        self.assertIn("[#146](https://github.com/nightcinder/wmr-companion/pull/146)", body)
        self.assertIn("Fix a typo (`bbbbbbb`)", body)
        self.assertIn("`wmr-companion-0.3.6-unified-arm64-v8a.apk`", body)
        self.assertIn("unified tester APK (VITURE + XREAL, arm64-v8a)", body)
        self.assertIn("`SHA256SUMS`", body)
        self.assertIn("sha256sum -c SHA256SUMS", body)

    def test_no_apk_omits_the_install_steps(self) -> None:
        body = self.render(["SHA256SUMS"], [])
        self.assertNotIn("### Install", body)
        self.assertIn("No pull requests merged since the previous tag.", body)

    def test_no_assets_is_stated(self) -> None:
        body = self.render([], [])
        self.assertIn("No assets were attached to this release.", body)


if __name__ == "__main__":
    unittest.main()
