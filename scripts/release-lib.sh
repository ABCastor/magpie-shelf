# Shared constants and helpers for build-dmg.sh and install-local.sh.
# Sourced, not executed; callers have already cd'd to the repo root and set
# `set -euo pipefail`.
#
# WHY THIS FILE EXISTS. The two build scripts each carried their own
# VERSION="…" literal and their own copy of the Info.plist heredoc. The
# literals could drift apart silently, and at one point both sat at the exact
# version the published appcast already claimed — so a fresh install would
# never have been offered an update. The version now has one home: here.

APP_NAME="Magpie"
BIN_NAME="Magpie"
BUNDLE_ID="com.anneo22.magpie"
# VERSION drives both CFBundleShortVersionString and CFBundleVersion so the
# value Sparkle compares (sparkle:version vs CFBundleVersion) lines up with
# the same dotted form we publish in appcast.xml.
VERSION="1.7.0"
MIN_OS="13.0"

# Sparkle appcast feed — raw GitHub URL on main.
SPARKLE_FEED_URL="https://raw.githubusercontent.com/ABCastor/Magpie/main/appcast.xml"

# Copy Sparkle's licence text into the embedded framework's Resources.
# MIT's notice condition applies to binary redistribution too: shipping
# Sparkle.framework without its licence text would violate the licence, so a
# missing source file is a hard error, never a silent skip. Call after the
# framework is embedded and before signing, so the copy is inside the seal.
copy_sparkle_license() {
  local app_dir="$1"
  local license_src=".build/artifacts/sparkle/Sparkle/LICENSE"
  local license_dst="${app_dir}/Contents/Frameworks/Sparkle.framework/Resources/LICENSE"
  if [ ! -f "${license_src}" ]; then
    echo "ERROR: Sparkle licence not found at ${license_src}." >&2
    echo "Refusing to embed Sparkle.framework without its licence text (MIT requires the notice ship with the copy)." >&2
    exit 1
  fi
  cp "${license_src}" "${license_dst}"
}

# Write the bundle's Info.plist. Uses the constants above plus
# SPARKLE_PUBLIC_KEY, which the caller must have set (build-dmg.sh requires a
# real key; install-local.sh substitutes a placeholder for local builds).
write_info_plist() {
  local app_dir="$1"
  cat > "${app_dir}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <!-- Inbound links only: magpie://add?path=…&amp;shelf=…, handled by
       AppDelegate.application(_:open:). Deliberately NOT CFBundleDocumentTypes
       for public.item, which would put Magpie in the Open With menu of every
       file on the system. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>${BUNDLE_ID}.url</string>
      <key>CFBundleURLSchemes</key>
      <array><string>magpie</string></array>
    </dict>
  </array>
  <key>LSMinimumSystemVersion</key><string>${MIN_OS}</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
  <key>SUEnableInstallerLauncherService</key><false/>
</dict>
</plist>
PLIST
}
