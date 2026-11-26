#!/bin/bash
# Fetch VYRA's embedded Python runtime and Python packages into Vendor/.
#
#   Vendor/Python.xcframework   CPython for iOS (BeeWare Python-Apple-support)
#   Vendor/app_packages/        yt-dlp + yt-dlp-ejs + certifi (pure Python)
#                               + the bgutil PO-token provider plugin
#                               (yt_dlp_plugins/, HTTP mode only — the
#                               script-mode module is deleted below
#                               because it spawns subprocesses, which
#                               iOS forbids)
#
# Vendor/ is gitignored: this script runs in CI before xcodebuild, and
# can be run locally on a Mac the same way. Versions are pinned; bump
# the variables below to update.
set -euo pipefail

PY_VERSION="${PY_VERSION:-3.14}"
PY_BUILD="${PY_BUILD:-b14}"
YTDLP_VERSION="${YTDLP_VERSION:-2026.11.23}"
EJS_VERSION="${EJS_VERSION:-0.8.0}"
BGUTIL_VERSION="${BGUTIL_VERSION:-2.0.2}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
mkdir -p "$VENDOR"

if [ ! -d "$VENDOR/Python.xcframework" ]; then
    echo "==> Downloading Python $PY_VERSION ($PY_BUILD) for iOS (BeeWare)"
    TMP="$(mktemp -d)"
    curl -fL --progress-bar \
        "https://github.com/beeware/Python-Apple-support/releases/download/$PY_VERSION-$PY_BUILD/Python-$PY_VERSION-iOS-support.$PY_BUILD.tar.gz" \
        | tar -xz -C "$TMP"
    mv "$TMP/Python.xcframework" "$VENDOR/"
    rm -rf "$TMP"

    echo "==> Trimming unused standard library modules"
    STDLIB="$VENDOR/Python.xcframework/lib/python$PY_VERSION"
    for m in test idlelib tkinter turtledemo ensurepip lib2to3 pydoc_data venv _pyrepl \
             turtle.py pydoc.py antigravity.py this.py doctest.py; do
        rm -rf "${STDLIB:?}/$m"
    done
    find "$STDLIB" -type d -name tests -prune -exec rm -rf {} + 2>/dev/null || true

    # Precompile bytecode only when a matching host interpreter exists;
    # the .py sources load fine without it.
    HOST_PY="$(command -v "python$PY_VERSION" || true)"
    if [ -n "$HOST_PY" ]; then
        echo "==> Precompiling the standard library with $HOST_PY"
        "$HOST_PY" -m compileall -q -j0 --invalidation-mode unchecked-hash "$STDLIB" || true
    fi
fi

# Fast path for CI cache hits: when app_packages was restored from the
# actions/cache entry keyed by this script's hash, the marker written
# at install time matches the pinned versions and reinstalling the
# exact same wheels would be wasted work.
VERSION_MARKER="$VENDOR/app_packages/.vyra-versions"
EXPECTED_MARKER="yt-dlp==$YTDLP_VERSION yt-dlp-ejs==$EJS_VERSION bgutil-ytdlp-pot-provider==$BGUTIL_VERSION"
if [ -f "$VERSION_MARKER" ] && [ "$(cat "$VERSION_MARKER")" = "$EXPECTED_MARKER" ]; then
    echo "==> app_packages already at pinned versions ($EXPECTED_MARKER), skipping install"
    echo "==> Done. Python $PY_VERSION + yt-dlp $YTDLP_VERSION ready in Vendor/"
    du -sh "$VENDOR/Python.xcframework" "$VENDOR/app_packages"
    exit 0
fi

echo "==> Installing yt-dlp $YTDLP_VERSION + yt-dlp-ejs $EJS_VERSION + certifi + bgutil POT plugin $BGUTIL_VERSION"
rm -rf "$VENDOR/app_packages"
python3 -m pip install --quiet --no-deps --no-compile --target "$VENDOR/app_packages" \
    "yt-dlp==$YTDLP_VERSION" "yt-dlp-ejs==$EJS_VERSION" certifi \
    "bgutil-ytdlp-pot-provider==$BGUTIL_VERSION"
rm -rf "$VENDOR/app_packages/bin" "$VENDOR/app_packages"/yt_dlp-*.data
# The bgutil plugin ships two provider modules: HTTP (base_url) and
# script (spawns a local Node/Deno process). iOS forbids subprocesses,
# so delete the script module outright — with the file gone, nothing
# in the app can ever select that mode.
rm -f "$VENDOR/app_packages/yt_dlp_plugins/extractor/getpot_bgutil_script.py"
echo "$EXPECTED_MARKER" > "$VERSION_MARKER"

HOST_PY="$(command -v "python$PY_VERSION" || true)"
if [ -n "$HOST_PY" ]; then
    "$HOST_PY" -m compileall -q -j0 --invalidation-mode unchecked-hash "$VENDOR/app_packages" || true
fi

echo "==> Done. Python $PY_VERSION + yt-dlp $YTDLP_VERSION ready in Vendor/"
du -sh "$VENDOR/Python.xcframework" "$VENDOR/app_packages"
