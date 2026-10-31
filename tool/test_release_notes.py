#!/usr/bin/env python3
"""Tests for tool/release_notes.py; no network or git repository needed."""

from __future__ import annotations

import sys
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
