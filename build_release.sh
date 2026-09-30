#!/usr/bin/env bash
# Builds OpenNotebook.app — a SwiftUI shell around the Open Notebook stack.
#
# The bundle is code only. Databases, uploads and the encryption key live in
# ~/Library/Application Support/OpenNotebook so replacing the .app never costs the
# user their notebooks.
#
#   ./build_release.sh              build into ./release
#   ./build_release.sh --skip-web   reuse the existing frontend production build
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_REPO="${OPEN_NOTEBOOK_SRC:-$REPO_ROOT/../open-notebook}"
RELEASE_DIR="$REPO_ROOT/release"
APP_NAME="OpenNotebook"
BUNDLE_ID="app.opennotebook.mac"
STAGE="$RELEASE_DIR/.stage"
APP="$RELEASE_DIR/$APP_NAME.app"

NODE_VERSION="v22.14.0"
NODE_URL="https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-darwin-arm64.tar.gz"
CACHE_DIR="$REPO_ROOT/.build-cache"
PYTHON_VERSION="3.12"

SKIP_WEB=0
[[ "${1:-}" == "--skip-web" ]] && SKIP_WEB=1

step() { printf '\n\033[1;36m▸ %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

for tool in swift node npm uv; do
  command -v "$tool" >/dev/null || fail "$tool not found on PATH"
done
[[ -d "$SOURCE_REPO" ]] || fail "Open Notebook source not found at $SOURCE_REPO (override with OPEN_NOTEBOOK_SRC)"

# ---------------------------------------------------------------- swift binary
step "Compiling $APP_NAME (release)"
swift build -c release --package-path "$REPO_ROOT"
BINARY="$(swift build -c release --package-path "$REPO_ROOT" --show-bin-path)/$APP_NAME"
[[ -x "$BINARY" ]] || fail "swift build produced no binary at $BINARY"

# ------------------------------------------------------------------ staging
step "Staging bundle"
rm -rf "$STAGE" "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

# SurrealDB — 2.x, because 3.x rejects the project's FLEXIBLE migration syntax.
step "Staging SurrealDB"
SURREAL_BIN="$CACHE_DIR/surreal"
if [[ ! -x "$SURREAL_BIN" ]]; then
  mkdir -p "$CACHE_DIR"
  curl -fsSL "https://github.com/surrealdb/surrealdb/releases/download/v2.7.0/surreal-v2.7.0.darwin-arm64.tgz" \
    | tar xz -C "$CACHE_DIR"
  mv "$CACHE_DIR/surreal" "$SURREAL_BIN"
fi
mkdir -p "$APP/Contents/Resources/surreal"
cp "$SURREAL_BIN" "$APP/Contents/Resources/surreal/surreal"

# Node runtime — the Next.js standalone server is a Node program.
step "Staging Node runtime $NODE_VERSION"
if [[ ! -x "$CACHE_DIR/node-dist/bin/node" ]]; then
  mkdir -p "$CACHE_DIR"
  NODE_TARBALL="node-${NODE_VERSION}-darwin-arm64"
  curl -fsSL "$NODE_URL" | tar xz -C "$CACHE_DIR"
  mv "$CACHE_DIR/$NODE_TARBALL" "$CACHE_DIR/node-dist"
fi
mkdir -p "$APP/Contents/Resources/node"
cp -R "$CACHE_DIR/node-dist/." "$APP/Contents/Resources/node/"

# Python backend: sources from the repo, dependencies in a venv built on uv's
# self-contained interpreter so the app does not need Homebrew Python.
step "Building bundled Python venv"
PYTHON_BIN="$(uv python find "$PYTHON_VERSION" 2>/dev/null || true)"
if [[ -z "$PYTHON_BIN" ]]; then
  uv python install "$PYTHON_VERSION"
  PYTHON_BIN="$(uv python find "$PYTHON_VERSION")"
fi

BACKEND="$APP/Contents/Resources/backend"
mkdir -p "$BACKEND"
for item in api open_notebook commands prompts run_api.py; do
  [[ -e "$SOURCE_REPO/$item" ]] && cp -R "$SOURCE_REPO/$item" "$BACKEND/"
done
[[ -d "$BACKEND/api" ]] || fail "backend sources missing from $SOURCE_REPO"

# Resolve dependencies with `uv sync` rather than `uv pip install` from a freeze.
# The project overrides moviepy's `pillow<12` cap in pyproject.toml, and freezing
# the dev venv loses that override and yields an unsatisfiable set.
VENV_DIR="$CACHE_DIR/venv"
if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  rm -rf "$VENV_DIR"
  # Reuse the committed uv.lock so the bundled app runs the versions already
  # verified end to end.
  (cd "$SOURCE_REPO" && UV_PROJECT_ENVIRONMENT="$VENV_DIR" uv sync --frozen --python "$PYTHON_BIN")
  # python-magic is installed outside the lock (added for PDF handling); it needs
  # libmagic present on the system at runtime.
  uv pip install --python "$VENV_DIR/bin/python" python-magic
fi
rm -rf "$BACKEND/.venv"
cp -R "$VENV_DIR" "$BACKEND/.venv"

# The cached venv has its own absolute path baked into pyvenv.cfg, the script
# shebangs and any .pth files. Rewrite them to the location inside the bundle.
"$SOURCE_REPO/.venv/bin/python" - "$VENV_DIR" "$BACKEND/.venv" <<'PY'
import pathlib, sys

old_root, new_root = (pathlib.Path(p) for p in sys.argv[1:3])
old_str, new_str = str(old_root), str(new_root)

def rewrite(path: pathlib.Path) -> bool:
    try:
        original = path.read_text()
    except (UnicodeDecodeError, OSError):
        return False
    if old_str not in original:
        return False
    path.write_text(original.replace(old_str, new_str))
    path.chmod(0o755)
    return True

rewritten = sum(rewrite(p) for p in new_root.rglob("*") if p.is_file())
print(f"  rebased {rewritten} venv files onto the bundle path")
PY

# Ship uv's self-contained interpreter so the app does not need Homebrew Python.
BUNDLED_PY="$APP/Contents/Resources/python"
mkdir -p "$BUNDLED_PY"
PYTHON_HOME="$(dirname "$(dirname "$PYTHON_BIN")")"
cp -R "$PYTHON_HOME/." "$BUNDLED_PY/"

# The venv's interpreter symlink still points at uv's install; aim it at ours.
# It must stay *relative*: codesign rejects absolute symlink destinations inside
# a bundle even when they resolve back into it.
rm -f "$BACKEND/.venv/bin/python" "$BACKEND/.venv/bin/python3" "$BACKEND/.venv/bin/python3.12"
ln -s "../../../python/bin/python3.12" "$BACKEND/.venv/bin/python"
ln -s python "$BACKEND/.venv/bin/python3"

# pyvenv.cfg's `home` locates the base interpreter; leaving it on uv's install
# makes the bundle depend on ~/.local/share/uv surviving.
"$SOURCE_REPO/.venv/bin/python" - "$BACKEND/.venv/pyvenv.cfg" "$BUNDLED_PY/bin" <<'PY'
import pathlib, sys

cfg_path, bundled_bin = pathlib.Path(sys.argv[1]), sys.argv[2]
lines = cfg_path.read_text().splitlines()
updated = [
    f"home = {bundled_bin}" if line.startswith("home =") else line
    for line in lines
]
if not any(line.startswith("home =") for line in lines):
    updated.insert(0, f"home = {bundled_bin}")
cfg_path.write_text("\n".join(updated) + "\n")
print("  pyvenv.cfg home ->", bundled_bin)
PY

# Prove the bundled interpreter actually resolves the project's dependencies
# before spending the rest of the build on it.
"$BACKEND/.venv/bin/python" - <<'PY'
import sys
import fastapi, surrealdb, langgraph
print("  bundled interpreter:", sys.version.split()[0], "| fastapi", fastapi.__version__)
PY

# ------------------------------------------------------------- web frontend
step "Building Next.js production bundle"
WEB="$APP/Contents/Resources/web"
if [[ $SKIP_WEB -eq 0 ]]; then
  (cd "$SOURCE_REPO/frontend" && npm run build)
fi
STANDALONE="$SOURCE_REPO/frontend/.next/standalone"
[[ -d "$STANDALONE" ]] || fail "frontend build missing; run without --skip-web"
mkdir -p "$WEB"
cp -R "$STANDALONE/." "$WEB/"
# `output: "standalone"` leaves these out of the bundle; without them the app
# serves a page with no CSS or JS. Replace rather than merge — a plain `cp -R`
# into an existing directory nests a second copy under static/static.
rm -rf "$WEB/.next/static" "$WEB/public"
cp -R "$SOURCE_REPO/frontend/.next/static" "$WEB/.next/static"
mkdir -p "$WEB/public"
[[ -d "$SOURCE_REPO/frontend/public" ]] && cp -R "$SOURCE_REPO/frontend/public/." "$WEB/public/"
# The standalone server has the /api rewrite inlined at build time, so the env
# var name never appears — assert on the resolved destination instead.
grep -q '/api/:path\*' "$WEB/server.js" || fail "standalone server.js is missing the /api rewrite"
grep -q '5055' "$WEB/server.js" || fail "standalone server.js does not target the API port"
[[ -d "$WEB/.next/static" ]] || fail "static assets missing; the app would render unstyled"

# ------------------------------------------------------------------- app icon
step "Generating app icon"
LOGO="$REPO_ROOT/Sources/logo.png"
[[ -f "$LOGO" ]] || fail "app icon source missing at $LOGO"
ICONSET="$CACHE_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
# iconutil requires one file per size, with @2x being the retina double.
for entry in icon_16x16:16 icon_16x16@2x:32 icon_32x32:32 icon_32x32@2x:64 \
             icon_128x128:128 icon_128x128@2x:256 icon_256x256:256 \
             icon_256x256@2x:512 icon_512x512:512 icon_512x512@2x:1024; do
  name="${entry%%:*}"
  px="${entry##*:}"
  sips -z "$px" "$px" "$LOGO" --out "$ICONSET/$name.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# ------------------------------------------------------------------ metadata
step "Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>Open Notebook</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- The app serves its own UI from http://127.0.0.1:8502 over WebKit. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
    <key>NSHumanReadableCopyright</key><string>Open Notebook by lfnovo, wrapped for macOS</string>
</dict>
</plist>
PLIST

# ------------------------------------------------------------------- sign off
step "Signing (ad-hoc)"
# Ad-hoc signature rather than Developer ID: enough for local launch, and it
# seals the bundle so the copied Python venv stays valid.
codesign --force --deep --sign - "$APP"
# A bad signature here means Gatekeeper will refuse the app, so fail the build
# rather than shipping something that only runs on this machine by accident.
codesign --verify --deep --strict "$APP"
echo "  signature valid"

rm -rf "$STAGE"
step "Done"
du -sh "$APP"
echo
echo "  Install:  cp -R \"$APP\" /Applications/"
echo "  Run:      open \"$APP\""
echo "  Data:     ~/Library/Application Support/OpenNotebook"
