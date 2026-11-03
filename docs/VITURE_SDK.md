# The VITURE C SDK in release builds

The unified release APK bundles `libglasses.so` from the VITURE XR Glasses SDK
for Android 2.4.1. The guided-bench Gate 1, checkerboard and Gate 9 steps call
into it; without it those steps report `sdkUnavailable` (ONY-740).

## Provenance

| Item | Value |
|---|---|
| SDK | VITURE XR Glasses SDK for Android 2.4.1 |
| Archive | `VITURE_XR_Glasses_SDK_for_Android.zip` (link supplied by the owner in ONY-400) |
| Vendored ABI | `arm64-v8a` only |
| `libglasses.so` size | 2,076,360 bytes |
| `libglasses.so` SHA-256 | `8ac615769b76cfe6fa05354b73048117f3d6ba2f54fef5b6ea6b128cbb2eb0a3` |

The binary and its `LICENSE` / `NOTICE` are not in the repository. They live on
the licensed self-hosted release runner at:

```
/home/liesa/.local/share/viture-sdk/2.4.1/
├── libglasses.so
├── LICENSE
└── NOTICE
```

`release-unified` copies `libglasses.so` into
`apps/wmr_companion_app/android/app/src/main/jniLibs/arm64-v8a/` after checking
the size and digest, and fails the job if the file is missing or different. A
provisioned runner therefore needs those three files before it can publish a
release. The debug flavor does not stage the SDK. The job removes its copy in
an `always()` step (the self-hosted workspace survives between runs), and the
`jniLibs/` path is gitignored so a local staging step cannot be committed.

## Licence conditions

VITURE's SDK License Agreement (effective September 2025, ships as
`com.viture.xr/LICENSE.md` in the Unity SDK) governs the distribution:

- **1.3** permits distributing the SDK in object code form **only as a
  component of a Developed Program** — the APK.
- **2.1.2 / 2.1.8** forbid distributing or publishing the SDK itself, so the
  `.so`, the headers, and any archive containing them must never be committed,
  uploaded as a release asset, published as a CI artifact, or handed out on
  their own. Only the built APK travels.
- **2.3.1** requires an end-user licence that forbids reverse engineering the
  SDK and requires users to indemnify VITURE. That text is
  `apps/wmr_companion_app/assets/legal/eula.txt`, shown under **About → Terms**.
- **2.3.2** requires the copyright and third-party notices to ship with the
  app. They are `apps/wmr_companion_app/assets/notices/viture_sdk.txt`, shown
  under **About → Licences**.
- **2.1.7** forbids disclosing SDK performance benchmarks without VITURE's
  written consent. Gate measurements such as the Gate 9 pose rate are
  benchmark results; check before publishing the ONY-736 scorecard.
- **9** forbids using "VITURE" in the application name. The app is
  "WMR Companion"; VITURE appears only in the licence and notice text.

## Multi-vendor builds

The app supports VITURE, XREAL and Android XR devices from one APK. Agreement
2.1.9 forbids using the SDK "to develop applications for other platforms", not
shipping an app that also supports other platforms. The tracking code keeps the
uses separate: `wmr_tracking_dispatch` detects the glasses vendor and selects
the matching source, so `wmr_tracking_viture` (and the VITURE C SDK) is only
used for VITURE devices, and `wmr_tracking_xreal` for XREAL devices. No VITURE
SDK code path runs against another vendor's hardware, and the APK is still a
Developed Program designed to function with VITURE products (1.3). The unified
APK has shipped this way since ONY-354.

## Updating the SDK

Replace the three files on the runner, update the size and digest in
`.github/workflows/ci.yml`, and update the version in
`assets/notices/viture_sdk.txt` and `assets/legal/eula.txt` if the agreement
changes.
