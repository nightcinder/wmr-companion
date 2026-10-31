#!/usr/bin/env python3
"""Render the GitHub release body for a WMR Companion tag.

The body lists every pull request merged into ``main`` since the previous
version tag, plus the release assets. It is read from first-parent history, so
a squash commit whose subject ends in ``(#123)`` becomes a PR bullet; a direct
commit is listed with its short SHA. No network access is needed.

    python3 tool/release_notes.py --tag v0.3.6 \
        --asset wmr-companion-0.3.6-unified-arm64-v8a.apk --asset SHA256SUMS

A dry-run tag (``v0.3.6-dryrun``) renders the same body for ``0.3.6`` without
publishing anything; pass ``--version`` to override the derived version.

Exit codes: 0 = body rendered, 1 = no previous tag or git failed,
64 = bad usage.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

SQUASH_SUBJECT = re.compile(r"^(?P<title>.+?) \(#(?P<number>\d+)\)$")
MERGE_SUBJECT = re.compile(
    r"^Merge pull request #(?P<number>\d+) from (?P<branch>\S+)"
)
COMMIT_FORMAT = "%H%x1f%s%x1f%aI"


@dataclass(frozen=True)
class Change:
    title: str
    number: int | None
    sha: str


def version_from_tag(tag: str) -> str:
    """``v0.3.6`` and ``v0.3.6-dryrun`` both name app version ``0.3.6``."""
    version = tag[1:] if tag.startswith("v") else tag
    if version.endswith("-dryrun"):
        version = version[: -len("-dryrun")]
    return version


def parse_subject(subject: str, sha: str) -> Change:
    match = SQUASH_SUBJECT.match(subject)
    if match:
        return Change(match.group("title").strip(), int(match.group("number")), sha)
    match = MERGE_SUBJECT.match(subject)
    if match:
        return Change(subject, int(match.group("number")), sha)
    return Change(subject.strip(), None, sha)


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def default_repo() -> str:
    """``owner/name`` from CI or from the origin remote."""
    from_env = os.environ.get("GITHUB_REPOSITORY")
    if from_env:
        return from_env
    url = git("remote", "get-url", "origin")
    match = re.search(r"github\.com[:/](?P<repo>[^/]+/[^/]+?)(?:\.git)?$", url)
    if not match:
        raise SystemExit(f"cannot derive a GitHub repository from {url!r}")
    return match.group("repo")


def previous_tag(tag: str) -> str:
    """The newest non-dry-run version tag reachable from the tag itself.

    The tag being released is excluded, so a real tag resolves to the release
    before it. A dry-run tag that points at the previous release's commit
    resolves to that same release and therefore reports no new changes.
    """
    try:
        return git(
            "describe",
            "--tags",
            "--abbrev=0",
            "--match",
            "v[0-9]*",
            "--exclude",
            "*-dryrun*",
            "--exclude",
            tag,
            tag,
        )
    except subprocess.CalledProcessError:
        raise SystemExit(
            f"no previous version tag reachable from {tag}; "
            "fetch tags (git fetch --tags) or pass --previous-tag"
        ) from None


def changes_since(previous: str, tag: str) -> list[Change]:
    output = git(
        "log",
        "--first-parent",
        "--reverse",
        f"--format={COMMIT_FORMAT}",
        f"{previous}..{tag}",
    )
    changes = []
    for line in output.splitlines():
        if not line:
            continue
        sha, subject, _authored = line.split("\x1f", 2)
        changes.append(parse_subject(subject, sha))
    return changes


def describe_asset(name: str) -> str:
    if name.endswith(".apk"):
        if "unified-arm64-v8a" in name:
            return "unified tester APK (VITURE + XREAL, arm64-v8a)"
        return "release APK"
    if name == "SHA256SUMS":
        return "SHA-256 digest of every APK above"
    return "release asset"


def render_body(
    *,
    version: str,
    tag: str,
    sha: str,
    previous: str,
    changes: list[Change],
    assets: list[str],
    repo: str,
) -> str:
    repo_url = f"https://github.com/{repo}"
    lines = [
        f"## WMR Companion {version} — tester build",
        "",
        "Signed tester APK for VITURE and XREAL glasses. One APK carries both "
        f"runtimes; it also runs on Galaxy XR. Built by CI from the `{tag}` tag "
        f"(`{sha[:7]}`).",
        "",
        f"### What changed since {previous}",
        "",
    ]
    if changes:
        for change in changes:
            if change.number is None:
                lines.append(f"- {change.title} (`{change.sha[:7]}`)")
            else:
                lines.append(
                    f"- **{change.title}** "
                    f"([#{change.number}]({repo_url}/pull/{change.number}))"
                )
    else:
        lines.append("- No pull requests merged since the previous tag.")

    apk = next((name for name in assets if name.endswith(".apk")), None)
    if apk and "SHA256SUMS" in assets:
        lines += [
            "",
            "### Install",
            "",
            f"1. Download `{apk}`.",
            "2. Check the download: `sha256sum -c SHA256SUMS`.",
        ]

    lines += ["", "### Assets", ""]
    if assets:
        for name in assets:
            lines.append(f"- `{name}` — {describe_asset(name)}")
    else:
        lines.append("- No assets were attached to this release.")
    lines.append("")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="tag being released")
    parser.add_argument(
        "--release-tag",
        help="tag to name in the body (default: --tag; dry runs name the release they preview)",
    )
    parser.add_argument("--version", help="app version (default: derived from --tag)")
    parser.add_argument("--previous-tag", help="override the detected previous tag")
    parser.add_argument("--repo", default=None, help="owner/name (default: origin)")
    parser.add_argument(
        "--asset",
        action="append",
        default=[],
        help="release asset name; repeat for each asset",
    )
    parser.add_argument("--output", help="write the body here instead of stdout")
    args = parser.parse_args(argv)

    tag = args.tag
    version = args.version or version_from_tag(tag)
    previous = args.previous_tag or previous_tag(tag)
    repo = args.repo or default_repo()
    try:
        sha = git("rev-parse", f"{tag}^{{commit}}")
    except subprocess.CalledProcessError:
        raise SystemExit(f"cannot resolve {tag!r} to a commit") from None

    body = render_body(
        version=version,
        tag=args.release_tag or tag,
        sha=sha,
        previous=previous,
        changes=changes_since(previous, tag),
        assets=args.asset,
        repo=repo,
    )
    if args.output:
        Path(args.output).write_text(body, encoding="utf-8")
    else:
        sys.stdout.write(body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
