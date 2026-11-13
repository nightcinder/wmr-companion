# Bridge update checks and pre-release installs

This document explains how WMR Companion inspects Raspberry Pi bridge versions. It describes manual update checks, stable releases, pre-release builds, and package upgrades. Use these steps when you maintain or update a bridge.

## Manual bridge update checks

The Connect screen shows the firmware and package version of the connected bridge.

You can select **Check for updates** next to the bridge version row. When you tap the button, the app queries GitHub Releases for newer builds. The app limits forced checks to one request every 30 seconds. This limit protects GitHub rate limits during repeated selections.

The screen displays the outcome in place with the local time of the request:

- If the bridge runs the newest version, the app reports that the build is up to date.
- If a newer release exists, the app displays the new version and opens an update banner.
- If the network fails or times out, the app shows an error message.

## Default stable releases

By default, bridge update lookups only inspect official stable releases.

The app queries the GitHub `releases/latest` API endpoint. GitHub excludes pre-release builds and drafts from this endpoint. If your bridge runs an older stable release, the check only offers newer stable releases. Release candidate builds do not appear in this default mode.

## Pre-release opt-in

You can opt in to test pre-release bridge builds.

Under the bridge version row, select the **Include pre-release bridge builds** checkbox. The application saves this choice in local device storage. When this option is active, the app queries the full GitHub release list. It evaluates the newest release candidate tags, such as `0.3.27-rc.2`.

When a pre-release build is newer than the connected bridge, the update banner shows the pre-release target. In-app automated upgrades over the WebSocket daemon only track stable releases. Because the daemon tracks stable releases, the banner shows the manual terminal command for the pre-release target.

## Installing a pre-release build on Raspberry Pi

GitHub `releases/latest` does not return pre-release builds.

To install a pre-release build on the Raspberry Pi, run the installer with pinned environment variables:

```bash
curl -fsSL \
  https://github.com/nightcinder/WMR_Bridge/releases/download/v<version>/install.sh \
  | WMR_BRIDGE_VERSION=<version> WMR_BRIDGE_TAG=v<version> sudo -E bash
```

For release candidate `0.3.27-rc.2`, run this exact command on the Raspberry Pi:

```bash
curl -fsSL \
  https://github.com/nightcinder/WMR_Bridge/releases/download/v0.3.27-rc.2/install.sh \
  | WMR_BRIDGE_VERSION=0.3.27-rc.2 WMR_BRIDGE_TAG=v0.3.27-rc.2 sudo -E bash
```

You must pass `sudo -E` so the root shell keeps the environment variables. If you omit `WMR_BRIDGE_VERSION`, the script falls back to the latest stable release. The installer downloads the release package, makes sure that signatures match, and installs the package with `apt-get`.

## Upgrading from release candidate to stable

Debian package versioning treats hyphenated suffixes as package revisions. Under standard `dpkg` version comparison rules, `0.3.27-rc.2` ranks higher than `0.3.27`. Semantic versioning uses the opposite order, where `0.3.27` is newer than `0.3.27-rc.2`. Without special handling, `apt-get` rejects the final stable release as a downgrade.

The bridge installer converts hyphenated pre-release tags to tilde notation during version checks. Because Debian treats `0.3.27~rc.2` as older than `0.3.27`, package checks agree with semantic versioning. When you upgrade from an installed pre-release to a newer stable release, the installer passes `--allow-downgrades` to `apt-get`. When the final stable release arrives, you can upgrade your bridge without reinstallation.
