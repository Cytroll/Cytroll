# Cytroll

A minimal rootless package manager and bootstrap installer for iOS 15.0 - 17.x, designed to be installed via TrollStore.

## Overview

Cytroll acts as both a bootstrap installer and a package manager. Unlike traditional jailbreak apps that bundle the bootstrap inside the app bundle, Cytroll downloads the required `bootstrap.tar` on-demand to keep the `.ipa` size under 3MB. It uses native Swift parsers to interact with the dpkg status file and APT indices directly, avoiding slow shell wrappers.

## Architecture & AMFI Bypass

Cytroll uses the standard TrollStore Root Helper architecture (similar to Sileo and Filza). To execute commands outside the App Bundle (like `/var/jb/usr/bin/dpkg`) without being killed by Apple Mobile File Integrity (AMFI), Cytroll invokes a bundled command-line utility called `cytrollhelper`.

The `cytrollhelper` binary must be compiled and placed inside the app bundle and signed with the following entitlements:
- `com.apple.private.security.no-sandbox`
- `platform-application`

The Swift UI layer passes execution commands as arguments to `cytrollhelper`, which executes them with `uid 0` (root privileges) securely and flawlessly.

## Features

- **Remote Bootstrap**: Downloads and extracts the Procursus bootstrap to `/var/jb` dynamically.
- **Package Management**: Native Swift implementation for parsing `dpkg` and APT repos.
- **Root Helper Injection**: Uses a secondary binary (`cytrollhelper`) to safely spawn root-level processes.
- **Tweak Management**: Built-in toggle to disable tweak injection (Safe Mode equivalent), plus utilities for `sbreload`, `uicache`, and userspace reboots.
- **Per-App Tweak Injection**: TrollFools-style patching of a single third-party app's executable to load a MobileSubstrate-style tweak's dylib — see [Per-App Tweak Injection](#per-app-tweak-injection) below.
- **Rootless**: Strictly compliant with rootless standards. Never touches the signed system volume (SSV).

## Per-App Tweak Injection

Cytroll's Tweaks tab (`Settings → Manage Injected Tweaks`) can patch a **single third-party app** to load an installed tweak's dylib, in the same spirit as [TrollFools](https://github.com/Lessica/TrollFools): it adds an `LC_LOAD_WEAK_DYLIB` load command to the app's executable with `insert_dylib`, then re-signs it with `ldid`.

**How target apps are chosen:** after installing a tweak `.deb`, Cytroll reads the standard MobileSubstrate `Filter -> Bundles` array from that tweak's companion `.plist` and only ever offers injection into **installed apps whose bundle ID is listed there** — never a blind "inject into anything" picker. If a tweak ships no `Filter`, no target is offered.

**Safety pipeline (every step verified, any failure rolls back automatically):**
1. Full backup of the target `.app` bundle, verified (file count + total size) before anything is touched. A failed/mismatched backup aborts immediately — no modification ever happens without a good backup first.
2. Original entitlements extracted from the backup (`ldid -e`), to be reapplied when re-signing.
3. Tweak dylib copied into the app's `Frameworks/` folder and ad-hoc signed.
4. `insert_dylib --inplace --weak --strip-codesig` patches the main executable.
5. `ldid -S<entitlements>` re-signs the executable with its original entitlements restored.
6. A basic post-injection signature check runs; any failure in steps 3-6 restores the untouched backup immediately.

**Real limitations — please read before using:**
- Works **only** on third-party apps under `Bundle/Application/*.app/` — Apple's own apps and SpringBoard live on the sealed system volume and can never be touched, by construction (not just by policy).
- Depends on the same class of CoreTrust/AMFI bypass TrollStore itself relies on being active on your iOS version — if that bypass doesn't persist system-wide on your device, the patched app simply won't launch until you restore it.
- **Breaks silently on the target app's next update** — App Store/TrollStore updates replace the executable with an unpatched original. The Tweaks tab flags this as "Needs Reapply" (compares the app's current version against the version recorded at injection time) with a one-tap re-inject button.
- The injected app usually needs to be force-quit/restarted (sometimes a full respring) before the tweak takes effect.
- Doesn't handle dylibs loaded dynamically at runtime instead of via a static load command (rare; TrollFools needs a dedicated Mach-O engine for that case, out of scope here).
- Disabling or fully removing (apt purge) the tweak automatically restores every app it was injected into — you never need to do this by hand.

## Compatibility

- iOS 15.0 - 17.x
- Requires [TrollStore](https://github.com/opa334/TrollStore). Cytroll relies on the CoreTrust bug and TrollStore's unsandboxed environment.

## Building

1. Clone this repository.
2. Open the project in Xcode. `Cytroll.entitlements` is already wired as `CODE_SIGN_ENTITLEMENTS` for the main target.
3. Run `Scripts/fetch-binaries.sh` on macOS to fetch `ldid`, `tar`, `zstd` into `Binaries/`.
4. Run `./build.sh` — it compiles `cytrollhelper` and `insert_dylib` from their vendored C sources in `Cytroll/Core/RootHelper/`, pseudo-signs everything with `ldid` using `Cytroll.entitlements`, and packages `Cytroll.tipa`.
5. Alternatively, build the Xcode project directly (`CODE_SIGNING_ALLOWED=NO`) and run the signing steps from `build.sh` manually.
6. Install the resulting `.tipa`/`.ipa` via TrollStore.

## Credits

- The Sileo Team for APT parsing concepts and Root Helper proxy architecture.
- opa334 for TrollStore.
- Tyilo for [`insert_dylib`](https://github.com/Tyilo/insert_dylib), vendored under `Cytroll/Core/RootHelper/insert_dylib.c`.
- Lessica for [TrollFools](https://github.com/Lessica/TrollFools), the reference design for the per-app injection pipeline.
