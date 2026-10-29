# Release signing (ONY-492)

External-tester APKs are signed with a project-owned key so that every build
installs over the previous one and `apksigner` reports a single, stable
certificate instead of `CN=Android Debug`.

## Key facts

| Item | Value |
|---|---|
| Keystore | `apps/wmr_companion_app/android/wmr-release.keystore` (gitignored, never committed) |
| Format | JKS (keeps a distinct key password; PKCS#12 would reuse the store password) |
| Alias | `wmr-companion` |
| Algorithm | RSA 4096-bit |
| Validity | 10,000 days (2026-10-29 to 2054-03-16) |
| Package | `com.onyxlens.wmr_companion` |
| Certificate SHA-256 | `31:54:43:40:04:05:EC:7D:CB:7D:75:F8:47:41:83:45:0C:74:1A:E1:BF:34:84:FC:1B:DF:32:87:A6:41:FC:A2` |
| Password secrets | Paperclip `wmr-companion/release-store-password`, `wmr-companion/release-key-password` |

The keystore file is attached to the ONY-492 task for the owner's offline
backup. It is not part of the repository.

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
tool/build_flavor.sh base --release
"$ANDROID_HOME"/build-tools/<version>/apksigner verify --print-certs \
  build/app/outputs/flutter-apk/app-base-release.apk
```

Expected certificate:

```text
Signer #1 certificate DN: CN=WMR Companion, OU=Android, O=OnyxLens, C=US
Signer #1 certificate SHA-256 digest: 315443400405ec7dcb7d75f8474183450c741ae1bf3484fc1bdf3287a641fca2
```

A release APK signed by the debug key (`CN=Android Debug`) is a regression.

## CI release: tag to downloadable APK (ONY-493)

Pushing a `v*` tag runs the `release` job in `.github/workflows/ci.yml`; no local
build is needed. The job decodes the keystore, builds
`tool/build_flavor.sh base --release --split-per-abi`, checks each APK with
`apksigner`, and attaches the assets to that tag's GitHub Release.

Repository secrets (`Settings → Secrets and variables → Actions`):

| Secret | Value |
|---|---|
| `WMR_RELEASE_KEYSTORE_BASE64` | `base64 -w0 apps/wmr_companion_app/android/wmr-release.keystore` |
| `WMR_RELEASE_STORE_PASSWORD` | keystore store password |
| `WMR_RELEASE_KEY_PASSWORD` | `wmr-companion` key password |

The alias is fixed to `wmr-companion` in the workflow. `key.properties` wins
over the environment, so a tag build never picks up a local key.properties from
the checkout (it is gitignored anyway).

Release assets for tag `vX.Y.Z`:

```text
wmr-companion-X.Y.Z-base-arm64-v8a.apk
wmr-companion-X.Y.Z-base-armeabi-v7a.apk
wmr-companion-X.Y.Z-base-x86_64.apk    # emulator
SHA256SUMS
```

`wmr-companion-X.Y.Z-base-arm64-v8a.apk` is the phone/tablet asset testers
should install. The job fails if an APK is debug-signed, lacks a
`CN=WMR Companion` signer, or its certificate SHA-256 is not the one above, so
a green tag run means the published APKs match this document.

## Offline backup

Do this once now, then after any re-export of the keystore (key rotation).

1. Download `wmr-release.keystore` from the ONY-492 task attachment (or copy it
   from `apps/wmr_companion_app/android/wmr-release.keystore`).
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

   The fingerprint must match `31:54:43:40:04:05:EC:7D:…:41:FC:A2` above.
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
  build/app/outputs/flutter-apk/app-base-release.apk | grep package:
```
