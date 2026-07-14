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
- **Rootless**: Strictly compliant with rootless standards. Never touches the signed system volume (SSV).

## Compatibility

- iOS 15.0 - 17.x
- Requires [TrollStore](https://github.com/opa334/TrollStore). Cytroll relies on the CoreTrust bug and TrollStore's unsandboxed environment.

## Building

1. Clone this repository.
2. Open the project in Xcode.
3. Make sure `Cytroll.entitlements` is selected in the Target's Signing & Capabilities for the main app.
4. Compile your `cytrollhelper` binary in C/Swift, sign it with root entitlements, and embed it in the App Bundle.
5. Build the Xcode project.
6. Export as `.ipa` or `.tipa` and install via TrollStore.

## Credits

- The Sileo Team for APT parsing concepts and Root Helper proxy architecture.
- opa334 for TrollStore.
