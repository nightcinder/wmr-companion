# Release signing (ONY-492; key rotated in ONY-493)

External-tester APKs are signed with a project-owned key so that every build
installs over the previous one and `apksigner` reports a single, stable
certificate instead of `CN=Android Debug`.

The ONY-492 key was regenerated in ONY-493 before any tester build was
distributed: its store and key passwords were not recoverable, so every release
build failed at signing. The current key uses a random store password and a
separate key password, both kept in Paperclip secrets. No
installed app uses a different certificate, so in-place updates are unaffected.

## Key facts

| Item | Value |
|---|---|
| Keystore | `apps/wmr_companion_app/android/wmr-release.keystore` (gitignored, never committed) |
| Format | JKS (keeps a distinct key password; PKCS#12 would reuse the store password) |
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

## CI release: tag to downloadable APK (ONY-493, ONY-508, ONY-520)

Pushing a `v*` tag runs one build job in `.github/workflows/ci.yml`; no local
build is needed. It decodes the keystore, checks the APK with `apksigner`, and
attaches the assets to that tag's GitHub Release. `release-checksums` then
writes one `SHA256SUMS` covering the published APKs.

CI publishes only the `unified` flavor. `base`, `viture` and `xreal` remain
buildable locally with `tool/build_flavor.sh`, but they have no release path
(ONY-520).

| Job | Flavor | Build |
|---|---|---|
| `release-unified` | `unified` | downloads the approved export, `tool/install_unity_export.sh unified`, then `tool/build_flavor.sh unified --release --split-per-abi --target-platform android-arm64` |

`unified` is the artifact testers with VITURE or XREAL glasses install: one
APK links a single `unityLibrary` carrying VITURE 0.9.0 and XREAL 3.1.0 and
selects the vendor at runtime. The export is never committed or built in CI;
`release-unified` downloads `unityLibrary.zip` from the `unity-export-1.0`
release, refuses it unless its SHA-256 is
`945bd4254310766313fac81d0daa472408223c82cbee55186bcbcf3d144333b5` (the ONY-354
export), and runs `tool/check_unified_apk.py` on the arm64-v8a APK before
publishing. The Monado config key fetch is not optional: the job fails unless
the key is exactly 1024 bytes and is packaged in the APK. Re-publishing that
asset is a one-off from a machine holding the zip:

```sh
gh release create unity-export-1.0 --prerelease \
  --title unity-export-1.0 \
  --notes "Approved Unity UaaL export (VITURE 0.9.0 + XREAL 3.1.0) used by the unified release job."
gh release upload unity-export-1.0 /paperclip/unity-export/unityLibrary.zip
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
version: 0.2.2+4   # versionName 0.2.2, versionCode 4
```

Before building a new tester APK, increment the build number after `+`
(`0.2.2+4` → `0.2.2+5`) and commit that change with the release PR. Also bump
`versionName` when the user-facing version changes. `flutter build` maps these
to Android `versionName`/`versionCode`; confirm with:

```sh
"$ANDROID_HOME"/build-tools/<version>/aapt dump badging \
  build/app/outputs/flutter-apk/app-unified-release.apk | grep package:
```
