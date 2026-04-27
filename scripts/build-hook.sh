#!/bin/bash
# Build the miomini-hook CLI via SwiftPM and copy it into the app bundle.
# Invoked from Xcode as a postBuild script. Xcode's final code-sign step then
# signs the embedded binary as part of the .app bundle.
#
# Required env vars (provided by Xcode):
#   PROJECT_DIR        — path to the SwiftPM package root
#   TARGET_BUILD_DIR   — Xcode build products dir
#   WRAPPER_NAME       — e.g. "Mio Mini.app"
#   CONFIGURATION      — "Debug" | "Release"
#   ARCHS              — space-separated arch list ("arm64" "x86_64")

set -euo pipefail

cd "$PROJECT_DIR"

# Map Xcode configuration to SwiftPM configuration.
case "$CONFIGURATION" in
    Debug)   SWIFT_CONFIG="debug" ;;
    Release) SWIFT_CONFIG="release" ;;
    *)       SWIFT_CONFIG="release" ;;
esac

# Build for the same arch(s) Xcode is building for. SwiftPM doesn't natively
# do universal binaries in one shot — we build each arch and lipo if needed.
ARCH_ARGS=()
for arch in $ARCHS; do
    ARCH_ARGS+=("--arch" "$arch")
done

echo "[build-hook] swift build --product miomini-hook -c $SWIFT_CONFIG ${ARCH_ARGS[*]}"
swift build --product miomini-hook -c "$SWIFT_CONFIG" "${ARCH_ARGS[@]}"

# SwiftPM's binary path: with --arch flag it lands in arch-specific subdirs;
# without it, in $SWIFT_CONFIG. Pick whichever exists.
BIN_PATHS=(
    ".build/$SWIFT_CONFIG/miomini-hook"
    ".build/apple/Products/$([[ $SWIFT_CONFIG == debug ]] && echo Debug || echo Release)/miomini-hook"
)
SRC=""
for p in "${BIN_PATHS[@]}"; do
    if [[ -f "$p" ]]; then
        SRC="$p"
        break
    fi
done

if [[ -z "$SRC" ]]; then
    # Fallback: find any miomini-hook executable under .build that was just built.
    SRC=$(find .build -type f -name miomini-hook -perm +111 -newer Package.swift 2>/dev/null | head -1 || true)
fi

if [[ -z "$SRC" ]]; then
    echo "[build-hook] error: could not locate built miomini-hook binary" >&2
    exit 1
fi

DEST_DIR="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/MacOS"
mkdir -p "$DEST_DIR"
cp -f "$SRC" "$DEST_DIR/miomini-hook"
chmod 755 "$DEST_DIR/miomini-hook"
echo "[build-hook] embedded $SRC → $DEST_DIR/miomini-hook"
