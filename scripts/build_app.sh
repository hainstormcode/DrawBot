#!/usr/bin/env bash
# Builds build/DrawBot.app (release) and signs it.
#
#   ./scripts/build_app.sh
#
# Optional environment:
#   DRAWBOT_SCRATCH   SwiftPM scratch directory, relative to the project root (default: .build)
#   DRAWBOT_CONFIG    release (default) or debug
#
# Signing: uses the first "Apple Development" identity in your keychain if there is one (the
# Accessibility permission then survives rebuilds), otherwise signs ad-hoc.
set -euo pipefail

# Work from the project root no matter where the script is called from. Every path below is
# relative to it, so the project folder can live anywhere.
cd "$(dirname "$0")/.."

CONFIG="${DRAWBOT_CONFIG:-release}"
BUILD_ARGS=(-c "$CONFIG")
if [[ -n "${DRAWBOT_SCRATCH:-}" ]]; then
    BUILD_ARGS+=(--scratch-path "$DRAWBOT_SCRATCH")
fi

echo "==> swift build ${BUILD_ARGS[*]}"
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
EXECUTABLE="$BIN_DIR/DrawBot"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "error: built executable not found at $EXECUTABLE" >&2
    exit 1
fi

APP="build/DrawBot.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXECUTABLE" "$APP/Contents/MacOS/DrawBot"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Extended attributes copied along (Finder info, quarantine from a downloaded project folder)
# make codesign fail with "resource fork, Finder information, or similar detritus not allowed".
xattr -cr "$APP"

# First "Apple Development" identity (by SHA-1 hash, so duplicate names can't confuse codesign).
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development/ { print $2; exit }' || true)"

signed=""
if [[ -n "$IDENTITY" ]]; then
    IDENTITY_NAME="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -v id="$IDENTITY" '$2 == id { sub(/^[^"]*"/, ""); sub(/"$/, ""); print; exit }' || true)"
    echo "==> Signing with $IDENTITY_NAME"
    if codesign --force --timestamp=none --sign "$IDENTITY" "$APP"; then
        signed="$IDENTITY_NAME"
    else
        echo "warning: signing with $IDENTITY_NAME failed; falling back to ad-hoc signing" >&2
    fi
fi
if [[ -z "$signed" ]]; then
    echo "==> Signing ad-hoc (no Apple Development identity found)"
    echo "    Note: after each rebuild you may need to remove DrawBot from"
    echo "    System Settings → Privacy & Security → Accessibility and add it again."
    codesign --force --sign - "$APP"
    signed="ad-hoc"
fi
codesign --verify --strict "$APP"

echo
echo "Built $(pwd)/$APP  (signed: $signed)"
echo "Run it with:  open $APP"
