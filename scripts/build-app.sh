#!/bin/bash
# Created by Василий Маслов on 01.10.2026.
set -euo pipefail
cd "$(dirname "$0")/.."
source "$PWD/scripts/signing-identity.sh"
mimic_resolve_signing_identity "$HOME/Library/Application Support/Mimic/Development/signing-identity"
if [ "$MIMIC_SELECTED_IDENTITY" != '-' ]; then
  SIGNING_INVENTORY="$(security find-identity -v -p codesigning)"
  mimic_validate_signing_identity "$SIGNING_INVENTORY"
fi
INSTALL=false
RELEASE=false
PREFERENCE="$HOME/Library/Application Support/Mimic/Development/install-destination"
DESTINATION="${MIMIC_INSTALL_DESTINATION:-/Applications/Mimic.app}"
# Personal opt-in stays outside the checkout. Explicit artifact paths remain packaging-only.
if [ -z "${MIMIC_APP_PATH:-}" ] && [ -z "${MIMIC_DISTRIBUTION_PATH:-}" ] && [ -f "$PREFERENCE" ]; then
  if [ -z "${MIMIC_INSTALL_DESTINATION:-}" ]; then IFS= read -r DESTINATION < "$PREFERENCE"; fi
  INSTALL=true
fi
for ARGUMENT in "$@"; do
  case "$ARGUMENT" in
    --install) INSTALL=true ;;
    --no-install) INSTALL=false ;;
    --release) RELEASE=true ;;
    *) echo 'Usage: build-app.sh [--install|--no-install] [--release]' >&2; exit 64 ;;
  esac
done
VERSION=$(python3 "$PWD/scripts/build-metadata.py" --version)
UPDATE_CONFIG="${MIMIC_UPDATE_CONFIG:-$PWD/Distribution/Updates.plist}"
if "$RELEASE"; then
  [ "$MIMIC_SELECTED_IDENTITY" != '-' ] || { echo 'Release packaging requires Developer ID signing.' >&2; exit 64; }
  python3 - "$MIMIC_SELECTED_IDENTITY" "$SIGNING_INVENTORY" <<'PYCODE'
import re, sys
choice, inventory = sys.argv[1:]
identities = re.findall(r'\b([0-9A-Fa-f]{40}) "([^"\n]+)"', inventory)
if not any((choice.upper() == fingerprint.upper() or choice == name) and name.startswith('Developer ID Application:') for fingerprint, name in identities):
    sys.exit('Release packaging requires a Developer ID Application certificate.')
PYCODE
  [ "$(uname -m)" = arm64 ] || { echo 'The first release is qualified for Apple Silicon only.' >&2; exit 64; }
fi
if "$INSTALL"; then
  case "$DESTINATION" in /*/Mimic.app) ;; *) echo 'Invalid Mimic installation destination.' >&2; exit 64 ;; esac
  mkdir -p "$PWD/.local"
  # Serialize build and deployment so another build cannot mutate the validated source bundle.
  LOCK="$PWD/.local/development-install.lock"
  mkdir "$LOCK" 2>/dev/null || { echo "Development installation is already running: $LOCK" >&2; exit 1; }
  trap 'rmdir "$LOCK"' EXIT
  DEFAULT_APP="$PWD/.local/Development/Mimic.app"
else
  DEFAULT_APP="$PWD/.local/Mimic.app"
fi
APP="${MIMIC_APP_PATH:-$DEFAULT_APP}"
if "$INSTALL"; then
  python3 -c 'import pathlib, sys; sys.exit(0 if pathlib.Path(sys.argv[1]).resolve() != pathlib.Path(sys.argv[2]).resolve() else 1)' "$APP" "$DESTINATION" || {
    echo 'Build into a separate bundle before installation.' >&2; exit 64
  }
fi
BUILD_PATH="${MIMIC_BUILD_PATH:-$PWD/.build}"
# Explicit opt-in only; never pick a developer/team identity automatically.
MIMIC_SIGNING_IDENTITY="$MIMIC_SELECTED_IDENTITY"
MIMIC_SIGN_FLAGS=(--force --sign "$MIMIC_SIGNING_IDENTITY")
if [ "$MIMIC_SIGNING_IDENTITY" != '-' ]; then
  MIMIC_SIGN_FLAGS+=(--options runtime --timestamp)
fi
MIMIC_BUILD_FLAGS=(-Xswiftc -debug-prefix-map -Xswiftc "$PWD=./Mimic" -Xcc "-fdebug-prefix-map=$PWD=./Mimic")
if [ "${MIMIC_SWIFTPM_DISABLE_SANDBOX:-false}" = true ]; then MIMIC_BUILD_FLAGS+=(--disable-sandbox); fi
BUILD_SYSTEM="${MIMIC_BUILD_SYSTEM:-}"
if "$INSTALL" && [ -z "$BUILD_SYSTEM" ] && [ -f "$(dirname "$PREFERENCE")/build-system" ]; then
  IFS= read -r BUILD_SYSTEM < "$(dirname "$PREFERENCE")/build-system"
fi
if [ -n "$BUILD_SYSTEM" ]; then MIMIC_BUILD_FLAGS+=(--build-system "$BUILD_SYSTEM"); fi
swift build "${MIMIC_BUILD_FLAGS[@]}" --scratch-path "$BUILD_PATH" -c release -j 4
PRODUCTS=$(swift build "${MIMIC_BUILD_FLAGS[@]}" --scratch-path "$BUILD_PATH" -c release --show-bin-path)
# Build every release bundle in a fresh staging tree.
FINAL_APP="$APP"
case "$FINAL_APP" in /*/Mimic.app) ;; *) echo 'Output must be an absolute Mimic.app path.' >&2; exit 64 ;; esac
mkdir -p "$(dirname "$FINAL_APP")"
STAGING=$(mktemp -d "$(dirname "$FINAL_APP")/MimicBuild.XXXXXX")
APP="$STAGING/Mimic.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Frameworks"
ditto "$PRODUCTS/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$PRODUCTS/Mimic" "$APP/Contents/MacOS/Mimic"
cp "$PRODUCTS/TaskHost" "$APP/Contents/Helpers/TaskHost"
cp "$PRODUCTS/MimicMCP" "$APP/Contents/Helpers/MimicMCP"
cp "$PRODUCTS/MimicCLI" "$APP/Contents/Helpers/MimicCLI"
cp "$PRODUCTS/SimulatorVideoHost" "$APP/Contents/Helpers/SimulatorVideoHost"
cp "$PRODUCTS/SimulatorInputHost" "$APP/Contents/Helpers/SimulatorInputHost"
for resource_name in Mimic_Mimic Mimic_MimicCore Mimic_MimicMCP SwiftTerm_SwiftTerm ZIPFoundation_ZIPFoundation; do
  resource="$PRODUCTS/$resource_name.bundle"
  [ -d "$resource" ] || continue
  cp -R "$resource" "$APP/Contents/Resources/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Created by Василий Маслов on 01.10.2026. -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Mimic</string>
<key>CFBundleIdentifier</key><string>local.vmaslov.Mimic</string>
<key>CFBundleName</key><string>Mimic</string>
<key>CFBundleDisplayName</key><string>Mimic</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>LSMultipleInstancesProhibited</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDevelopmentRegion</key><string>ru</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 "$PWD/scripts/build-metadata.py" --app "$APP" --config "$UPDATE_CONFIG"
# Icon Composer source compiles to Liquid Glass assets plus a macOS 14/15 fallback.
xcrun actool "$PWD/Artwork/Mimic.icon" \
  --compile "$APP/Contents/Resources" \
  --app-icon Mimic --platform macosx --target-device mac \
  --minimum-deployment-target 14.0 \
  --output-partial-info-plist "$BUILD_PATH/Mimic-icon-info.plist" \
  --output-format human-readable-text
/usr/libexec/PlistBuddy -c "Merge $BUILD_PATH/Mimic-icon-info.plist" "$APP/Contents/Info.plist"
# Validate every Composer source; only the primary catalog supplies bundle metadata.
for ICON_VARIANT in MimicEnamel MimicFrostedGlass; do
  ICON_OUTPUT="$BUILD_PATH/IconVariants/$ICON_VARIANT"
  mkdir -p "$ICON_OUTPUT"
  xcrun actool "$PWD/Artwork/AppIcons/$ICON_VARIANT.icon" \
    --compile "$ICON_OUTPUT" --app-icon "$ICON_VARIANT" \
    --platform macosx --target-device mac --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$ICON_OUTPUT/icon-info.plist" \
    --output-format human-readable-text
done
# The plugin always uses its own borderless mark, independently of desktop preferences.
cp "$PWD/Artwork/Plugin/MimicPluginIcon.png" "$APP/Contents/Resources/MimicPluginIcon.png"
cp -R "$PWD/ThirdPartyNotices" "$APP/Contents/Resources/ThirdPartyNotices"
cp "$PWD/LICENSE" "$APP/Contents/Resources/LICENSE"
# Object-file debug maps contain local build paths; keep them out of the distributable executables.
for executable in "$APP/Contents/MacOS/Mimic" "$APP/Contents/Helpers/TaskHost" "$APP/Contents/Helpers/MimicMCP" "$APP/Contents/Helpers/MimicCLI" "$APP/Contents/Helpers/SimulatorVideoHost" "$APP/Contents/Helpers/SimulatorInputHost"; do
  /usr/bin/strip -S "$executable"
done
codesign "${MIMIC_SIGN_FLAGS[@]}" --identifier local.vmaslov.Mimic.TaskHost "$APP/Contents/Helpers/TaskHost"
codesign "${MIMIC_SIGN_FLAGS[@]}" --identifier local.vmaslov.Mimic.MimicMCP "$APP/Contents/Helpers/MimicMCP"
codesign "${MIMIC_SIGN_FLAGS[@]}" --identifier local.vmaslov.Mimic.MimicCLI "$APP/Contents/Helpers/MimicCLI"
codesign "${MIMIC_SIGN_FLAGS[@]}" --identifier local.vmaslov.Mimic.SimulatorVideoHost "$APP/Contents/Helpers/SimulatorVideoHost"
codesign "${MIMIC_SIGN_FLAGS[@]}" --identifier local.vmaslov.Mimic.SimulatorInputHost "$APP/Contents/Helpers/SimulatorInputHost"
# Sign nested Sparkle code from the inside out, retaining its identifiers and symlink layout.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for SERVICE in "$SPARKLE/XPCServices/"*.xpc; do
  [ ! -d "$SERVICE" ] || codesign "${MIMIC_SIGN_FLAGS[@]}" --preserve-metadata=identifier,entitlements "$SERVICE"
done
codesign "${MIMIC_SIGN_FLAGS[@]}" --preserve-metadata=identifier,entitlements "$SPARKLE/Autoupdate"
codesign "${MIMIC_SIGN_FLAGS[@]}" --preserve-metadata=identifier,entitlements "$SPARKLE/Updater.app"
codesign "${MIMIC_SIGN_FLAGS[@]}" --preserve-metadata=identifier,entitlements "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${MIMIC_SIGN_FLAGS[@]}" --identifier local.vmaslov.Mimic "$APP/Contents/MacOS/Mimic"
codesign "${MIMIC_SIGN_FLAGS[@]}" --identifier local.vmaslov.Mimic "$APP"
codesign --verify --strict "$APP"
codesign --verify --deep --strict "$APP/Contents/Frameworks/Sparkle.framework"
for helper in "$APP/Contents/Helpers/"*; do codesign --verify --strict "$helper"; done
if [ -e "$FINAL_APP" ]; then mv "$FINAL_APP" "$STAGING/PreviousMimic.app"; fi
mv "$APP" "$FINAL_APP"
APP="$FINAL_APP"
rm -rf "$STAGING"
DISTRIBUTION="${MIMIC_DISTRIBUTION_PATH:-$PWD/.local/MimicSetup-$VERSION}"
case "$DISTRIBUTION" in /*/MimicSetup-*) ;; *) echo 'Invalid distribution path.' >&2; exit 64 ;; esac
rm -rf "$DISTRIBUTION"
rm -f "$DISTRIBUTION.zip"
mkdir -p "$DISTRIBUTION"
ditto "$APP" "$DISTRIBUTION/Mimic.app"
cp "$PWD/scripts/setup-mimic.command" "$PWD/scripts/setup-mimic.ru.plist" "$DISTRIBUTION/"
cp "$PWD/docs/MimicSetup.md" "$DISTRIBUTION/README.md"
cp "$PWD/docs/AgentChecks.md" "$DISTRIBUTION/AgentChecks.md"
cp "$PWD/LICENSE" "$DISTRIBUTION/LICENSE"
chmod +x "$DISTRIBUTION/setup-mimic.command"
ditto -c -k --sequesterRsrc --keepParent "$DISTRIBUTION" "$DISTRIBUTION.zip"
if "$RELEASE"; then
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$(dirname "$DISTRIBUTION")/Mimic-$VERSION.zip"
  echo 'Release candidate prepared. Notarization, Gatekeeper qualification and publication are separate explicit actions.'
fi
printf '%s\n' "$APP" "$DISTRIBUTION.zip"
if "$INSTALL"; then
  python3 "$PWD/scripts/deploy-development.py" --app "$APP" --destination "$DESTINATION"
fi
