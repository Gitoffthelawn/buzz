#!/usr/bin/env bash
# Build Buzz as a Linux AppImage.
#
# Prerequisites — install before running:
#   Ubuntu/Debian:
#     sudo apt install ffmpeg libportaudio2 libpulse0 libvulkan-dev ccache cmake \
#       libxkbcommon-x11-0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 \
#       libxcb-randr0 libxcb-render-util0 libxcb-xinerama0 libxcb-shape0 \
#       libxcb-cursor0 libgl1-mesa-dev gettext
#   RHEL/AlmaLinux 9:
#     sudo dnf install epel-release
#     sudo dnf install ffmpeg-free portaudio pulseaudio-libs-devel vulkan-loader-devel \
#       ccache cmake libxkbcommon-x11 libxcb mesa-libGL-devel gettext
#
#   Both: uv, Vulkan SDK (https://vulkan.lunarg.com/sdk/home)
#
# Usage:
#   ./appimage/build-appimage.sh          # standalone
#   uv run make bundle_appimage           # via Makefile

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/appimage"
APPDIR="$BUILD_DIR/Buzz.AppDir"
ARCH="$(uname -m)"
VERSION="$(grep '^version := ' "$PROJECT_DIR/Makefile" | head -1 | awk '{print $3}')"
OUTPUT="$PROJECT_DIR/dist/Buzz-${VERSION}-${ARCH}.AppImage"

echo "==> Building Buzz ${VERSION} AppImage for ${ARCH}"

# ── Step 1: PyInstaller bundle ──────────────────────────────────────────────
# Reuses the existing Buzz.spec (same as macOS/Windows builds).
# Produces dist/Buzz/ with the self-contained application.
if [ ! -d "$PROJECT_DIR/dist/Buzz" ]; then
    echo "==> Running PyInstaller..."
    cd "$PROJECT_DIR"
    uv run make dist/Buzz
fi

# ── Step 2: Create AppDir ───────────────────────────────────────────────────
echo "==> Assembling AppDir..."
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" \
         "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/scalable/apps" \
         "$APPDIR/usr/share/metainfo"

# Copy entire PyInstaller output into usr/bin/
cp -a "$PROJECT_DIR/dist/Buzz/." "$APPDIR/usr/bin/"

# ── Step 2b: Bundle a standalone Python for runtime pip installs ────────────
# Buzz installs CUDA support at runtime with pip (see buzz/cuda_manager.py),
# which needs a real interpreter — the frozen Buzz binary cannot run -m pip,
# and a host python is both optional and usually the wrong version for the
# ABI-specific CUDA wheels. Ship the uv-managed interpreter Buzz was frozen
# with, keeping its bin/ + lib/ layout so its $ORIGIN/../lib RPATH resolves.
echo "==> Bundling standalone Python interpreter..."
cd "$PROJECT_DIR"
PY_VERSION="$(uv run python -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
PY_DEST="$APPDIR/usr/bin/_internal/python"

# Always take uv's managed (python-build-standalone) build: it is relocatable
# and keeps libpython next to the stdlib, unlike a distro interpreter, which
# would leave the bundled tree depending on the build machine's /usr.
uv python install --managed-python "$PY_VERSION" >/dev/null
PY_BIN="$(uv python find --managed-python "$PY_VERSION")"
PY_BASE="$("$PY_BIN" -c 'import sys; print(sys.base_prefix)')"

if [ ! -x "$PY_BASE/bin/python$PY_VERSION" ] || ! compgen -G "$PY_BASE/lib/libpython*.so*" >/dev/null; then
    echo "ERROR: $PY_BASE is not a relocatable standalone Python $PY_VERSION." >&2
    exit 1
fi

rm -rf "$PY_DEST"
mkdir -p "$PY_DEST/bin" "$PY_DEST/lib"
cp -a "$PY_BASE/bin/python$PY_VERSION" "$PY_DEST/bin/"
ln -sf "python$PY_VERSION" "$PY_DEST/bin/python3"
# libpython lives next to the stdlib; both are found via the RPATH above.
cp -a "$PY_BASE"/lib/libpython*.so* "$PY_DEST/lib/" 2>/dev/null || true
cp -a "$PY_BASE/lib/python$PY_VERSION" "$PY_DEST/lib/"

# Trim what a pip subprocess never needs (~40 MB of stdlib).
rm -rf "$PY_DEST/lib/python$PY_VERSION/test" \
       "$PY_DEST/lib/python$PY_VERSION/idlelib" \
       "$PY_DEST/lib/python$PY_VERSION/tkinter" \
       "$PY_DEST/lib/python$PY_VERSION/turtledemo" \
       "$PY_DEST/lib/python$PY_VERSION"/config-*
find "$PY_DEST" -name '__pycache__' -type d -prune -exec rm -rf {} +

# uv's builds are marked as externally managed; the copy is ours to install
# CUDA wheels into, so drop the marker.
rm -f "$PY_DEST/lib/python$PY_VERSION/EXTERNALLY-MANAGED"

# Make sure pip is present now: the mounted AppImage is read-only, so ensurepip
# cannot bootstrap it on the user's machine.
if ! env -u LD_LIBRARY_PATH -u PYTHONPATH -u PYTHONHOME \
        "$PY_DEST/bin/python3" -m pip --version >/dev/null 2>&1; then
    env -u LD_LIBRARY_PATH -u PYTHONPATH -u PYTHONHOME \
        "$PY_DEST/bin/python3" -m ensurepip --upgrade >/dev/null
fi
env -u LD_LIBRARY_PATH -u PYTHONPATH -u PYTHONHOME \
    "$PY_DEST/bin/python3" -m pip --version

# Smoke-test the trimmed tree, including the modules pip pulls in (ssl for
# downloads, expat via xmlrpc) — a missing one only shows up at install time.
env -u LD_LIBRARY_PATH -u PYTHONPATH -u PYTHONHOME \
    "$PY_DEST/bin/python3" -c 'import ssl, lzma, ctypes, sqlite3, xml.parsers.expat'

# ── Step 3: Desktop integration ─────────────────────────────────────────────
# Desktop file — Exec must be just the binary name for AppImage spec
cat > "$APPDIR/Buzz.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Buzz
GenericName=Audio Transcriber
Comment=Transcribe and translate audio offline
Exec=Buzz
Icon=Buzz
Terminal=false
Categories=AudioVideo;Audio;
MimeType=audio/mpeg;audio/wav;audio/ogg;audio/flac;video/mp4;video/webm;
EOF
cp "$APPDIR/Buzz.desktop" "$APPDIR/usr/share/applications/"

# Icon (SVG at AppDir root + XDG hicolor location)
cp "$PROJECT_DIR/share/icons/io.github.chidiwilliams.Buzz.svg" "$APPDIR/Buzz.svg"
cp "$PROJECT_DIR/share/icons/io.github.chidiwilliams.Buzz.svg" \
   "$APPDIR/usr/share/icons/hicolor/scalable/apps/Buzz.svg"

# AppStream metainfo (appimagetool expects .appdata.xml suffix)
cp "$PROJECT_DIR/share/metainfo/io.github.chidiwilliams.Buzz.metainfo.xml" \
   "$APPDIR/usr/share/metainfo/io.github.chidiwilliams.Buzz.appdata.xml"
APPSTREAM_FILE="$APPDIR/usr/share/metainfo/io.github.chidiwilliams.Buzz.appdata.xml"

# ── Step 4: AppRun entry point ──────────────────────────────────────────────
cat > "$APPDIR/AppRun" << 'APPRUN'
#!/bin/bash
SELF="$(readlink -f "$0")"
APPDIR="$(dirname "$SELF")"

export PATH="$APPDIR/usr/bin:$PATH"
export LD_LIBRARY_PATH="$APPDIR/usr/bin:${LD_LIBRARY_PATH:-}"
export QT_MEDIA_BACKEND=ffmpeg
export PULSE_LATENCY_MSEC=30

exec "$APPDIR/usr/bin/Buzz" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

# ── Step 5: Build AppImage ──────────────────────────────────────────────────
echo "==> Packaging AppImage..."
mkdir -p "$BUILD_DIR" "$PROJECT_DIR/dist"

APPIMAGETOOL="$BUILD_DIR/appimagetool-${ARCH}"
if [ ! -x "$APPIMAGETOOL" ]; then
    echo "==> Downloading appimagetool..."
    curl -fSL -o "$APPIMAGETOOL" \
        "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${ARCH}.AppImage"
    chmod +x "$APPIMAGETOOL"
fi

# Download AppImage runtime (appimagetool's built-in download can fail)
RUNTIME="$BUILD_DIR/runtime-${ARCH}"
if [ ! -f "$RUNTIME" ]; then
    echo "==> Downloading AppImage runtime..."
    curl -fSL -o "$RUNTIME" \
        "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-${ARCH}"
fi

# Use APPIMAGETOOL_EXTRACT_AND_RUN when FUSE is unavailable (CI, containers)
EXTRA_ARGS=(--runtime-file "$RUNTIME" --no-appstream)
if [ "${CI:-}" = "true" ] || ! command -v fusermount &>/dev/null; then
    export APPIMAGETOOL_EXTRACT_AND_RUN=1
fi

# Validate AppStream metadata ourselves in offline mode. appimagetool's internal
# appstream-util invocation performs network checks for remote screenshots,
# which breaks in proxied or restricted build environments even when the
# metadata itself is otherwise valid.
if command -v appstreamcli >/dev/null 2>&1; then
    echo "==> Validating AppStream metadata with appstreamcli (--no-net)..."
    appstreamcli validate --no-net "$APPSTREAM_FILE"
fi

if command -v appstream-util >/dev/null 2>&1; then
    echo "==> Validating AppStream metadata with appstream-util (--nonet)..."
    appstream-util validate-relax --nonet "$APPSTREAM_FILE"
fi

ARCH="$ARCH" "$APPIMAGETOOL" "${EXTRA_ARGS[@]}" "$APPDIR" "$OUTPUT"

echo "==> Done: $OUTPUT"
