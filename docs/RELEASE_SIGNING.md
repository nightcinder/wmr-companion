# Release signing (ONY-492; key rotated in ONY-493)

External-tester APKs are signed with a project-owned key so that every build
installs over the previous one and `apksigner` reports a single, stable
certificate instead of `CN=Android Debug`.

The ONY-492 key was regenerated in ONY-493 before any tester build was
distributed: its store and key passwords were not recoverable, so every release
build failed at signing. The current key uses a random store password and a
separate key password, both kept in Paperclip secrets. Two release APKs from
this key install over each other; any build signed with another key (a debug
APK, or a release APK from a throwaway keystore) must be uninstalled once, as
described in [Installing a release APK](#installing-a-release-apk).

## Key facts

| Item | Value |
|---|---|
| Keystore | `apps/wmr_companion_app/android/wmr-release.keystore` (gitignored, never committed) |
| Format | JKS (keeps a distinct key password; PKCS#12 will reuse the store password) |
| Alias | `wmr-companion` |
| Algorithm | RSA 4096-bit |
| Validity | 10,000 days (2026-10-29 to 2054-03-16) |
| Package | `com.onyxlens.wmr_companion` |
| Certificate SHA-256 | `BD:AA:32:B5:1A:D3:AF:D2:67:D0:F8:0F:28:A4:73:B8:53:19:F8:C3:7E:26:28:9C:F1:DC:1F:F7:CF:AA:E2:56` |
| Password secrets | store password: Paperclip `wmr-companion/release-store-password`; key password: Paperclip `wmr-companion/release-key-password` |

The keystore file is attached to the ONY-493 task for the owner's offline
backup (the ONY-492 attachment is the superseded first key). It is not part of
the repository.

## Configuration

`apps/wmr_companion_app/android/app/build.gradle.kts` reads
`apps/wmr_companion_app/android/key.properties` (gitignored):

```properties
storeFile=../wmr-release.keystore
storePassword=<store password>
keyAlias=wmr-companion
keyPassword=<key password>
```

Each value can instead come from an environment variable, which is the CI path:

| Property | Environment variable |
|---|---|
| `storeFile` | `WMR_RELEASE_STORE_FILE` (relative paths resolve from `android/app`) |
| `storePassword` | `WMR_RELEASE_STORE_PASSWORD` |
| `keyAlias` | `WMR_RELEASE_KEY_ALIAS` |
| `keyPassword` | `WMR_RELEASE_KEY_PASSWORD` |

`key.properties` wins over the environment when both exist.

Signing rules:

- **debug** builds (and `flutter run`) keep the Android debug key; no project
  keystore is needed.
- **release** builds require all four values. If any is missing the build stops
  with `Release signing is not configured` and lists the missing properties. It
  never falls back to the debug key.

## Build and verify

```sh
cd apps/wmr_companion_app
tool/build_flavor.sh unified --release
"$ANDROID_HOME"/build-tools/<version>/apksigner verify --print-certs \
  build/app/outputs/flutter-apk/app-unified-release.apk
```

Expected certificate:

```text
Signer #1 certificate DN: CN=WMR Companion, OU=Android, O=OnyxLens, C=US
Signer #1 certificate SHA-256 digest: bdaa32b51ad3afd267d0f80f28a473b85319f8c37e26289cf1dc1ff7cfaae256
```

A release APK signed by the debug key (`CN=Android Debug`) is a regression.

## Installing a release APK

Android replaces an installed app only when the new APK is signed with the same
key. Otherwise the package installer stops with the generic **"Something went
wrong"** dialog and `adb` reports:

```text
INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package
com.onyxlens.wmr_companion signatures do not match newer version; ignoring!
```

That is not a broken download: `SHA256SUMS` still matches. A phone that ever
installed a debug build (`flutter run`, a CI `wmr-companion-debug-apks`
artifact, or a locally signed release) holds the other key, so uninstall it
once and install the release:

```sh
adb uninstall com.onyxlens.wmr_companion
adb uninstall --user 10 com.onyxlens.wmr_companion   # work profile, if present
adb install wmr-companion-X.Y.Z-unified-arm64-v8a.apk
```

Since 0.3.3 debug builds use the `com.onyxlens.wmr_companion.debug` package
(`applicationIdSuffix` in `android/app/build.gradle.kts`), so a debug build no
longer has to be removed before the release APK installs, and both can stay
installed side by side. Release APKs share one key and update in place.

## CI release: tag to downloadable APK (ONY-493, ONY-508, ONY-520)

Pushing a `v*` tag runs one build job in `.github/workflows/ci.yml`; no local
build is needed. It decodes the keystore, checks the APK with `apksigner`, and
attaches the assets to that tag's GitHub Release. `release-checksums` then
writes one `SHA256SUMS` covering the published APKs.

CI publishes only the `unified` flavor. `base` remains buildable locally with
`tool/build_flavor.sh`, but it has no release path (ONY-520). The per-vendor
`viture`/`xreal` flavors are retired (ONY-565).

| Job | Flavor | Build |
|---|---|---|
| `release-unified` | `unified` | downloads the approved export, `tool/install_unity_export.sh unified`, then `tool/build_flavor.sh unified --release --split-per-abi --target-platform android-arm64` |

`unified` is the artifact testers with VITURE or XREAL glasses install: one
APK links a single `unityLibrary` carrying VITURE 0.9.0 and XREAL 3.1.0 and
selects the vendor at runtime. The export is never committed or built in CI;
`release-unified` downloads `unityLibrary.zip` from the `unity-export-1.1`
release (a prerelease on purpose, so the export never takes the repository's
"Latest release" flag), refuses it unless its SHA-256 is
`29a9b9066d1b8dcee7b7acf5dddf7075dbd987c6dcbf29fde9216ed7084d2072` (the ONY-613
export, built from the ONY-612 merge commit), runs `tool/check_unity_export.py`
on the zip to reject a stale export or one that still emits the `mono` stereo
mode, and runs `tool/check_unified_apk.py` on the arm64-v8a APK before
publishing. The Monado config key fetch is not optional: the job fails unless
the key is exactly 1024 bytes and is packaged in the APK. Re-publishing that
asset is a one-off from a machine holding the zip:

```sh
gh release create unity-export-1.1 --prerelease \
  --title unity-export-1.1 \
  --notes "Approved Unity UaaL export (VITURE 0.9.0 + XREAL 3.1.0, ONY-612 stereo stage) used by the unified release job."
gh release upload unity-export-1.1 /paperclip/unity-export/unityLibrary.zip
```

Repository secrets (`Settings → Secrets and variables → Actions`):

| Secret | Value |
|---|---|
| `WMR_RELEASE_KEYSTORE_BASE64` | `base64 -w0 apps/wmr_companion_app/android/wmr-release.keystore` |
| `WMR_RELEASE_STORE_PASSWORD` | keystore store password |
| `WMR_RELEASE_KEY_PASSWORD` | key password from Paperclip `wmr-companion/release-key-password` |

The alias is fixed to `wmr-companion` in the workflow. `key.properties` wins
over the environment, so a tag build never picks up a local key.properties from
the checkout (it is gitignored anyway).

Release assets for tag `vX.Y.Z`:

```text
wmr-companion-X.Y.Z-unified-arm64-v8a.apk    # VITURE + XREAL glasses
SHA256SUMS
```

`wmr-companion-X.Y.Z-unified-arm64-v8a.apk` is the asset testers with VITURE or
XREAL glasses install. The unified flavor is published for `arm64-v8a` only:
the approved export ships `arm64-v8a` natives, so a 32-bit or x86_64 unified
split would install without any Unity runtime and report VITURE and XREAL as
`unavailable`. The job fails if an APK is debug-signed, lacks a
`CN=WMR Companion` signer, or its certificate SHA-256 is not the one above, so a
green tag run means the published APK matches this document.

## Release body

`release-unified` renders the body from first-parent history with
`tool/release_notes.py`: one bullet per pull request merged since the previous
version tag (a squash commit subject ending in `(#123)`), plus the assets the
tag publishes. The body is written to the run summary and passed to
`gh release create --notes-file`; a re-run refreshes an existing release's
notes. The generator and its tests use no network, so `python3 -m unittest -v
tool/test_release_notes.py` runs in the normal `build` job.

A dry-run tag renders the same body without building or publishing:

```sh
git tag v0.3.6-dryrun <commit>
git push origin v0.3.6-dryrun
```

`release-notes-dryrun` prints the body to the run summary and uploads it as the
`release-notes` artifact. `release-unified` and `release-checksums` skip any
tag containing `-dryrun`, so a dry run cannot create a release. Delete the tag
when done:

```sh
git push origin :refs/tags/v0.3.6-dryrun
```

## Offline backup

Do this once now, then after any re-export of the keystore (key rotation).

1. Download `wmr-release.keystore` from the ONY-493 task attachment — the
   ONY-492 attachment is the superseded key — or copy it from
   `apps/wmr_companion_app/android/wmr-release.keystore`.
2. Copy it to **two** offline media in separate physical locations (for example
   two USB sticks or an encrypted archive on a disconnected drive). Do not keep
   the only copy in git, the build workspace, or a synced cloud folder.
3. Record both Paperclip passwords in the owner's password manager next to the
   backup entries. Name the entries `wmr-companion release store password` and
   `wmr-companion release key password`.
4. Verify each backup before storing it:

   ```sh
   keytool -list -v -keystore wmr-release.keystore -alias wmr-companion \
     | grep 'SHA256:'
   ```

   The fingerprint must match `BD:AA:32:B5:…:AA:E2:56` above.
5. Record the backup date and locations in the owner's password-manager entry.

Losing this keystore means installed testers cannot receive an in-place update
from a new key: Android rejects an APK whose signing certificate changed unless
the old app is uninstalled first. Treat the backup as a release blocker.

## versionCode bump

Android requires a strictly increasing `versionCode` for every distributed APK.
The app version lives in `apps/wmr_companion_app/pubspec.yaml`:

```yaml
version: 0.3.6+11   # versionName 0.3.6, versionCode 11
```

Before building a new tester APK, increment the build number after `+`
(`0.3.6+11` → `0.3.6+12`) and commit that change with the release PR. Also bump
`versionName` when the user-facing version changes. `flutter build` maps these
to Android `versionName`/`versionCode`; confirm with:

```sh
"$ANDROID_HOME"/build-tools/<version>/aapt dump badging \
  build/app/outputs/flutter-apk/app-unified-release.apk | grep package:
```
