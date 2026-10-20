#!/usr/bin/env bash
# Build Magpie.app and install it to /Applications, for local use.
#
# WHY THIS EXISTS. `build-dmg.sh` is the release path and it refuses to run
# without a Sparkle signing key, which only the owner can generate. That left
# no supported way to put a local build in /Applications — so it got done by
# hand, and the hand-rolled version dropped a single load-bearing line:
#
#     install_name_tool -add_rpath @executable_path/../Frameworks
#
# SwiftPM builds a binary that does not know it will live inside a bundle, so
# it never adds that rpath. Without it dyld cannot resolve
# @rpath/Sparkle.framework and the app aborts at launch with SIGABRT — the
# framework is sitting right there in Contents/Frameworks and cannot be found.
# The app is `LSUIElement`, so there is no window and no dock icon to fail
# visibly: it simply never appears.
#
# So this script is the missing path, and step 5 is the point of it: the
# assembled app is launched for real and has to survive, before anything is
# written to /Applications. A build that cannot start never reaches the place
# where it would replace a working one.
#
#   ./scripts/install-local.sh
#
# Auto-update does not work from a local install unless scripts/.sparkle-public-key
# exists; that is expected and is called out at the end.

set -euo pipefail
cd "$(dirname "$0")/.."

# Shared constants (APP_NAME, BIN_NAME, BUNDLE_ID, VERSION, MIN_OS,
# SPARKLE_FEED_URL) and the Info.plist / Sparkle-licence helpers.
# shellcheck disable=SC1091
source scripts/release-lib.sh

APP_DIR="dist/${APP_NAME}.app"
INSTALL_PATH="/Applications/${APP_NAME}.app"

if [ -f scripts/.sparkle-public-key ]; then
  # shellcheck disable=SC1091
  source scripts/.sparkle-public-key
fi
# A local build does not need a real key. Sparkle refuses to apply an update it
# cannot verify, which is the safe direction to fail in.
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-LOCAL_BUILD_PLACEHOLDER_NOT_A_REAL_KEY}"

echo "==> 1/6  Building release"
swift build -c release

echo "==> 2/6  Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources" "${APP_DIR}/Contents/Frameworks"

cp ".build/release/${BIN_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# THE line. See the header.
install_name_tool -add_rpath @executable_path/../Frameworks "${APP_DIR}/Contents/MacOS/${APP_NAME}"

if [ -d "Sources/${BIN_NAME}/Resources" ]; then
  cp -R "Sources/${BIN_NAME}/Resources/." "${APP_DIR}/Contents/Resources/" 2>/dev/null || true
fi

if [ ! -f "Sources/${BIN_NAME}/Resources/AppIcon.icns" ]; then
  ICONSET_TMP="$(mktemp -d)/AppIcon.iconset"
  swift scripts/make-icon.swift "${ICONSET_TMP}"
  iconutil -c icns -o "${APP_DIR}/Contents/Resources/AppIcon.icns" "${ICONSET_TMP}"
  rm -rf "${ICONSET_TMP%/*}"
fi

SPARKLE_FRAMEWORK_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "${SPARKLE_FRAMEWORK_SRC}" ]; then
  SPARKLE_FRAMEWORK_SRC="$(find .build -type d -name 'Sparkle.framework' -not -path '*xcframework*' | head -1)"
fi
if [ -z "${SPARKLE_FRAMEWORK_SRC}" ] || [ ! -d "${SPARKLE_FRAMEWORK_SRC}" ]; then
  echo "ERROR: Sparkle.framework not found under .build" >&2
  exit 1
fi
cp -R "${SPARKLE_FRAMEWORK_SRC}" "${APP_DIR}/Contents/Frameworks/"

# Sparkle's MIT licence must ship with every copy of the framework, local
# installs included. Fails loudly if the source licence is missing.
copy_sparkle_license "${APP_DIR}"

write_info_plist "${APP_DIR}"

# Prefer the Developer ID identity when the machine has one, and fall back to
# ad-hoc when it does not.
#
# This is not about distribution — a local install is never notarized. It is
# about macOS privacy prompts. TCC remembers a grant against the app's code
# signing identity, and an ad-hoc signature is derived from the binary itself,
# so *every rebuild is a different app* as far as TCC is concerned. The result
# is that "Magpie would like to access files in your Downloads folder" returns
# after every single install, forever. A Developer ID signature is stable
# across rebuilds (team plus bundle id), so the grant is asked once and kept.
SIGN_IDENTITY="$({ security find-identity -v -p codesigning 2>/dev/null || true; } \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
if [ -n "${SIGN_IDENTITY}" ]; then
  echo "==> 3/6  Signing with '${SIGN_IDENTITY}' (inner-out)"
  SIGN_ARGS=(--force --deep --sign "${SIGN_IDENTITY}")
else
  echo "==> 3/6  Ad-hoc signing (inner-out) — privacy prompts will repeat each install"
  SIGN_ARGS=(--force --deep --sign -)
fi

SPARKLE_FX="${APP_DIR}/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_ARGS[@]}" "${SPARKLE_FX}/Versions/Current/XPCServices/Installer.xpc" 2>/dev/null || true
codesign "${SIGN_ARGS[@]}" "${SPARKLE_FX}/Versions/Current/XPCServices/Downloader.xpc" 2>/dev/null || true
codesign "${SIGN_ARGS[@]}" "${SPARKLE_FX}/Versions/Current/Updater.app" 2>/dev/null || true
codesign "${SIGN_ARGS[@]}" "${SPARKLE_FX}/Versions/Current/Autoupdate" 2>/dev/null || true
codesign "${SIGN_ARGS[@]}" "${SPARKLE_FX}"
codesign "${SIGN_ARGS[@]}" "${APP_DIR}"

echo "==> 4/6  Checking the bundle links"
if ! otool -l "${APP_DIR}/Contents/MacOS/${APP_NAME}" | grep -q "@executable_path/../Frameworks"; then
  echo "ERROR: the Frameworks rpath is missing — the app would abort at launch." >&2
  exit 1
fi
codesign --verify --deep "${APP_DIR}"

echo "==> 5/6  Launch test (must survive, or nothing is installed)"
# The check that matters. An LSUIElement app that dies at launch shows no
# window and no dock icon, so a broken build looks exactly like a working one
# until you reach for it.
#
# The build folder is hidden for the duration. SwiftPM bakes the absolute path
# of its resource bundle into the binary as a fallback, so on this Mac a build
# that cannot find its own resources still launches, and the same build
# crashes everywhere else, or here as soon as .build is cleaned. That is how
# a build that crashed at launch everywhere else passed this test.
LAUNCH_LOG="$(mktemp)"
BUILD_HIDDEN=".build.launch-test-hidden"
mv .build "${BUILD_HIDDEN}"
trap '[ -d "${BUILD_HIDDEN}" ] && mv "${BUILD_HIDDEN}" .build' EXIT
"${APP_DIR}/Contents/MacOS/${APP_NAME}" > "${LAUNCH_LOG}" 2>&1 &
LAUNCH_PID=$!
sleep 5
mv "${BUILD_HIDDEN}" .build
trap - EXIT
if ! ps -p "${LAUNCH_PID}" > /dev/null 2>&1; then
  echo "ERROR: the freshly built app died within 5 seconds. NOT installing." >&2
  echo "--- output ---" >&2
  head -30 "${LAUNCH_LOG}" >&2
  rm -f "${LAUNCH_LOG}"
  exit 1
fi
kill "${LAUNCH_PID}" 2>/dev/null || true
rm -f "${LAUNCH_LOG}"
echo "    survived 5s"

echo "==> 6/6  Installing to ${INSTALL_PATH}"
# Quit the running copy first so the relaunch below is the new build and not
# the old process still holding its inode.
pkill -f "${INSTALL_PATH}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
sleep 1
ditto "${APP_DIR}" "${INSTALL_PATH}"
xattr -dr com.apple.quarantine "${INSTALL_PATH}" 2>/dev/null || true
open -a "${INSTALL_PATH}"

echo
echo "Installed and relaunched: ${INSTALL_PATH}"
if [ "${SPARKLE_PUBLIC_KEY}" = "LOCAL_BUILD_PLACEHOLDER_NOT_A_REAL_KEY" ]; then
  echo "NOTE: placeholder Sparkle key — auto-update is inert in this build."
fi
