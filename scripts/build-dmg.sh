#!/usr/bin/env bash
# Build Magpie.app from the Magpie SwiftPM target, sign it, and package a DMG
# with an /Applications symlink.
#
# Signing has two modes, decided automatically:
#   - Developer ID + hardened runtime + notarization + stapling, when the
#     machine has a "Developer ID Application" identity in the keychain AND
#     notarytool credentials stored under the keychain profile named below.
#   - Ad-hoc otherwise (the DMG works, but Gatekeeper quarantines it and the
#     user must clear the flag once — the README documents that fallback).

set -euo pipefail

cd "$(dirname "$0")/.."

# Shared constants (APP_NAME, BIN_NAME, BUNDLE_ID, VERSION, MIN_OS,
# SPARKLE_FEED_URL) and the Info.plist / Sparkle-licence helpers.
# shellcheck disable=SC1091
source scripts/release-lib.sh

# Sparkle EdDSA public key — embedded in Info.plist as SUPublicEDKey.
# Generated once via the Sparkle generate_keys tool and stored in
# scripts/.sparkle-public-key (gitignored). The matching private key
# lives in the macOS Keychain on the release machine.
if [ -f scripts/.sparkle-public-key ]; then
  # shellcheck disable=SC1091
  source scripts/.sparkle-public-key
fi
if [ -z "${SPARKLE_PUBLIC_KEY:-}" ]; then
  echo "ERROR: SPARKLE_PUBLIC_KEY is not set."
  echo "Run the Sparkle generate_keys tool and write"
  echo "  SPARKLE_PUBLIC_KEY=<key>"
  echo "into scripts/.sparkle-public-key."
  exit 1
fi

APP_DIR="dist/${APP_NAME}.app"
DMG_ROOT="dist/dmgroot"
DMG_PATH="${APP_NAME}.dmg"

echo "==> Cleaning dist/"
rm -rf dist
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

echo "==> Regenerating the app icon (light and dark)"
scripts/make-icon.sh "Sources/${BIN_NAME}/Resources"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling .app bundle"
cp ".build/release/${BIN_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# Swift Package Manager builds a binary that doesn't know it'll live inside
# an .app bundle, so it doesn't add the standard Frameworks rpath. Without
# this, dyld can't find Sparkle.framework at runtime and the app won't launch.
install_name_tool -add_rpath @executable_path/../Frameworks "${APP_DIR}/Contents/MacOS/${APP_NAME}"

if [ -d "Sources/${BIN_NAME}/Resources" ]; then
  cp -R "Sources/${BIN_NAME}/Resources/." "${APP_DIR}/Contents/Resources/" 2>/dev/null || true
fi

echo "==> Embedding Sparkle.framework"
# The Sparkle xcframework artifact ships in .build/artifacts/ after `swift
# build` resolves the SPM dependency. Prefer the xcframework's macos slice
# (canonical, fully-signed by the Sparkle project) over a per-arch debug
# copy that swift build might leave under .build/<triple>/.
SPARKLE_FRAMEWORK_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "${SPARKLE_FRAMEWORK_SRC}" ]; then
  # Fall back to whatever swift build left behind.
  SPARKLE_FRAMEWORK_SRC="$(find .build -type d -name 'Sparkle.framework' -not -path '*xcframework*' | head -1)"
fi
if [ -z "${SPARKLE_FRAMEWORK_SRC}" ] || [ ! -d "${SPARKLE_FRAMEWORK_SRC}" ]; then
  echo "ERROR: Sparkle.framework not found under .build — run 'swift build -c release' first."
  exit 1
fi
mkdir -p "${APP_DIR}/Contents/Frameworks"
cp -R "${SPARKLE_FRAMEWORK_SRC}" "${APP_DIR}/Contents/Frameworks/"

echo "==> Embedding Sparkle's licence"
copy_sparkle_license "${APP_DIR}"

write_info_plist "${APP_DIR}"

# Release signing needs two things, checked independently so the message
# names exactly what is missing:
#   1. a "Developer ID Application" identity in the login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application)
#   2. notarytool credentials stored under the keychain profile "magpie-notary"
#      (xcrun notarytool store-credentials — the exact command is printed below)
NOTARY_PROFILE="magpie-notary"
SIGN_IDENTITY="$({ security find-identity -v -p codesigning 2>/dev/null || true; } \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"

NOTARIZE=1
if [ -z "${SIGN_IDENTITY}" ]; then
  echo "NOTE: no 'Developer ID Application' identity in the keychain."
  echo "      Fix: Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application."
  echo "      Building ad-hoc: this machine is not set up to cut a public release."
  NOTARIZE=0
fi

# The identity is the signal for "this machine is meant to cut releases".
# Once it is present, a failing notarytool check must STOP the build rather
# than quietly downgrade it: `notarytool history` also fails when the network
# is down, so a silent fallback would hand back an ad-hoc DMG that looks
# exactly like a notarized one and gets published as if it were. An
# unnotarized build that announces itself is recoverable; one that does not
# is discovered by strangers.
if [ "${NOTARIZE}" = "1" ] \
  && ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
  if [ "${MAGPIE_ALLOW_ADHOC:-0}" = "1" ]; then
    echo "NOTE: notarytool profile '${NOTARY_PROFILE}' unusable, and MAGPIE_ALLOW_ADHOC=1."
    echo "      Building ad-hoc deliberately. Do not publish this DMG."
    NOTARIZE=0
  else
    echo "ERROR: a Developer ID identity is present, so this looks like a release"
    echo "       machine, but notarytool could not use profile '${NOTARY_PROFILE}'."
    echo "       Refusing to silently produce an ad-hoc DMG that would be"
    echo "       indistinguishable from a notarized one."
    echo
    echo "       Either the profile is missing:"
    echo "         xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id <apple-id> --team-id <team-id>"
    echo "         (prompts for an app-specific password from appleid.apple.com)"
    echo "       or this machine is offline — notarization needs the network."
    echo
    echo "       To build an ad-hoc DMG on purpose: MAGPIE_ALLOW_ADHOC=1 bash scripts/build-dmg.sh"
    exit 1
  fi
fi

SPARKLE_FX="${APP_DIR}/Contents/Frameworks/Sparkle.framework"
if [ "${NOTARIZE}" = "1" ]; then
  echo "==> Signing with '${SIGN_IDENTITY}' (hardened runtime, inner-out)"
  # Sparkle 2.x contains XPC services and helper apps that must each be signed
  # before the outer framework is sealed. Sign them explicitly with the
  # hardened runtime (notarization requires it on every nested executable),
  # preserving any entitlements Sparkle shipped them with.
  for NESTED in \
    "${SPARKLE_FX}/Versions/Current/XPCServices/Installer.xpc" \
    "${SPARKLE_FX}/Versions/Current/XPCServices/Downloader.xpc" \
    "${SPARKLE_FX}/Versions/Current/Updater.app" \
    "${SPARKLE_FX}/Versions/Current/Autoupdate"; do
    [ -e "${NESTED}" ] || continue
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
      --sign "${SIGN_IDENTITY}" "${NESTED}"
  done
  codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${SPARKLE_FX}"
  codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${APP_DIR}"
  codesign --verify --strict --verbose=2 "${APP_DIR}"
else
  echo "==> Ad-hoc signing (inner-out) — Gatekeeper will quarantine this build"
  # Sparkle 2.x framework contains XPC services and helper apps that must each
  # be signed before the outer framework is sealed. `codesign --deep` does the
  # right thing for ad-hoc signing because we don't have an entitlement profile
  # that varies per nested binary.
  codesign --force --deep --sign - "${SPARKLE_FX}/Versions/Current/XPCServices/Installer.xpc" 2>/dev/null || true
  codesign --force --deep --sign - "${SPARKLE_FX}/Versions/Current/XPCServices/Downloader.xpc" 2>/dev/null || true
  codesign --force --deep --sign - "${SPARKLE_FX}/Versions/Current/Updater.app" 2>/dev/null || true
  codesign --force --deep --sign - "${SPARKLE_FX}/Versions/Current/Autoupdate" 2>/dev/null || true
  codesign --force --deep --sign - "${SPARKLE_FX}"
  codesign --force --deep --sign - "${APP_DIR}"
  codesign --verify --verbose=2 "${APP_DIR}" || true
fi

echo "==> Building DMG"
mkdir -p "${DMG_ROOT}"
cp -R "${APP_DIR}" "${DMG_ROOT}/${APP_NAME}.app"
ln -sfn /Applications "${DMG_ROOT}/Applications"

rm -f "${DMG_PATH}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_ROOT}" -ov -format UDZO "${DMG_PATH}"

if [ "${NOTARIZE}" = "1" ]; then
  echo "==> Signing DMG"
  codesign --force --sign "${SIGN_IDENTITY}" "${DMG_PATH}"
  echo "==> Notarizing (waits for Apple — minutes, not seconds)"
  xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
  echo "==> Stapling the notarization ticket"
  xcrun stapler staple "${DMG_PATH}"
fi

echo
echo "Done. Built: ${DMG_PATH}"
if [ "${NOTARIZE}" = "1" ]; then
  echo "Developer ID signed, notarized and stapled — installs clean, no quarantine step."
else
  echo "Ad-hoc signed, NOT notarized. First launch on a new machine:"
  echo "  xattr -dr com.apple.quarantine /Applications/${APP_NAME}.app"
fi
