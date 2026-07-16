# Binaries

This folder holds executables embedded in `Cytroll.app/Binaries/` at build time.

## Required at build time

| File | Purpose |
|------|---------|
| `cytrollhelper` | Built from `Cytroll/Core/RootHelper/cytrollhelper.c` by `build.sh` |
| `tar` | Extract Procursus bootstrap archive |
| `zstd` | Decompress `.tar.zst` bootstrap |
| `ldid` | Pseudo-sign binaries after bootstrap extraction |

## Optional (bootstrap)

Bootstrap archives can be **downloaded on-device** (preferred, keeps IPA small) or bundled here:

| File | iOS version |
|------|-------------|
| `bootstrap_1800.tar.zst` | iOS 15.0 – 16.x |
| `bootstrap_1900.tar.zst` | iOS 17.0+ |

Run `Scripts/fetch-binaries.sh` on macOS to download tools and bootstrap archives.

## Security

- All jailbreak files install only under `/var/jb`
- `cytrollhelper` allowlists executables and blocks SSV paths
- Never place system binaries from `/System` here
