#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARIES="$ROOT/Binaries"
HELPER_SRC="$ROOT/Cytroll/Core/RootHelper/cytrollhelper.c"
INSERT_DYLIB_SRC="$ROOT/Cytroll/Core/RootHelper/insert_dylib.c"

mkdir -p "$BINARIES"

echo "[*] Fetching rootless build tools into Binaries/..."

fetch_if_missing() {
    local name="$1"
    local url="$2"
    if [ ! -f "$BINARIES/$name" ]; then
        echo "    -> Downloading $name"
        curl -fsSL "$url" -o "$BINARIES/$name"
        chmod +x "$BINARIES/$name"
    else
        echo "    -> $name already present"
    fi
}

# Static tools commonly used by TrollStore jailbreak apps (update URLs as needed)
fetch_if_missing "ldid" "https://github.com/opa334/ldid/releases/latest/download/ldid_macos_arm64"
fetch_if_missing "tar"  "https://github.com/khcrysalis/ldid/releases/download/v2.1.5-procursus7-iphoneos-arm64/tar"
fetch_if_missing "zstd" "https://github.com/khcrysalis/ldid/releases/download/v2.1.5-procursus7-iphoneos-arm64/zstd"

echo "[*] Bootstrap archives (optional — app can download on-device):"
for ver in 1800 1900; do
    archive="bootstrap_${ver}.tar.zst"
    if [ ! -f "$BINARIES/$archive" ]; then
        echo "    [!] $archive not found — place manually or rely on on-device download"
    else
        echo "    [+] $archive present"
    fi
done

if [ -f "$HELPER_SRC" ]; then
    echo "[*] Compiling cytrollhelper (host preview — final build in build.sh)..."
    xcrun -sdk iphoneos clang -arch arm64 -o "$BINARIES/cytrollhelper" "$HELPER_SRC" 2>/dev/null || \
        echo "    [!] Skip host compile (requires Xcode iphoneos SDK on macOS)"
fi

if [ -f "$INSERT_DYLIB_SRC" ]; then
    echo "[*] Compiling insert_dylib (host preview — final build in build.sh)..."
    echo "    (vendored from https://github.com/Tyilo/insert_dylib for per-app tweak injection)"
    xcrun -sdk iphoneos clang -arch arm64 -o "$BINARIES/insert_dylib" "$INSERT_DYLIB_SRC" 2>/dev/null || \
        echo "    [!] Skip host compile (requires Xcode iphoneos SDK on macOS)"
fi

echo "[+] Done. Binaries directory ready at: $BINARIES"
