# WMR Companion Run Sheets

This directory contains run sheets for WMR Companion hardware testing and tracking validation.

## Active Run Sheets

The `sheets/` directory contains five active run sheets:

- [external-test-user.md](sheets/external-test-user.md): Quickstart for external testers. It covers Setup A (bridge and WMR controllers on v0.3.19), Setup B (6DoF glasses on v0.3.19 or URXR One day-one discovery with a post-ONY-1137 build), and Setup C (bridge and PSVR2 controllers).
- [pose-androidxr.md](sheets/pose-androidxr.md): 6DoF pose validation for Android XR headsets such as Google Aura and Samsung Galaxy XR. It covers permissions, joint tracking, and 10 to 50 cm/s guided speed checks.
- [pose-filter.md](sheets/pose-filter.md): Pose filter tuning against recorded captures. It documents the rev 4 grid search, acceptance criteria, and replay harness for recorded motion data.
- [pose-viture.md](sheets/pose-viture.md): Pose and camera validation on the VITURE Pro Neckband with Luma Ultra glasses. It covers stereo rendering, gripping hand tracking, and Carina diagnostics.
- [pose-xreal.md](sheets/pose-xreal.md): Pose validation for XREAL Air 2 Ultra glasses. It covers the Unity relay, hand joint rates while gripping, and 10 to 50 cm/s guided speed checks.

## Closed Sheets

- `latency-2.md`: Removed. The Flutter against native GATT probe comparison closed under ONY-23 with the verdict to stay on Flutter. No more runs are required. The decision rule and thresholds are preserved at git commit `4c6e6ac` and summarised in `docs/LATENCY.md`.
