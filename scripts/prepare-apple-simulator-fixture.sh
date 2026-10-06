#!/bin/bash
# Created by Василий Маслов on 04.10.2026.
# Explicit, disposable iOS acceptance only. Never touches ios3 or global xcode-select.
set -euo pipefail
MIMIC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIMIC_DEVELOPER=""
MIMIC_RUNTIME=""
MIMIC_DEVICE_TYPE=""
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || { echo 'Expected --developer PATH --runtime ID --device-type ID' >&2; exit 2; }
  case "$1" in
    --developer) MIMIC_DEVELOPER="$2";;
    --runtime) MIMIC_RUNTIME="$2";;
    --device-type) MIMIC_DEVICE_TYPE="$2";;
    *) echo 'Unknown fixture argument' >&2; exit 2;;
  esac
  shift 2
done
[ -d "$MIMIC_DEVELOPER" ] || { echo 'Select the installed Xcode 27 developer directory' >&2; exit 2; }
case "$MIMIC_RUNTIME" in com.apple.CoreSimulator.SimRuntime.iOS-*) ;; *) echo 'Only an installed iOS runtime is allowed' >&2; exit 2;; esac
case "$MIMIC_DEVICE_TYPE" in com.apple.CoreSimulator.SimDeviceType.iPhone-*|com.apple.CoreSimulator.SimDeviceType.iPad-*) ;; *) echo 'Only iPhone/iPad are allowed' >&2; exit 2;; esac
command -v xcodegen >/dev/null || { echo 'Developer fixture preparation requires XcodeGen' >&2; exit 2; }
export DEVELOPER_DIR="$MIMIC_DEVELOPER"
# Gate before creating or booting a device. Native agent access is configured by the user.
"$MIMIC_ROOT/scripts/probe-apple-simulator.sh" --developer "$MIMIC_DEVELOPER"
MIMIC_FIXTURE="$(mktemp -d /private/tmp/MimicAppleProbe-XXXXXXXX)"
cp -R "$MIMIC_ROOT/Tests/Fixtures/AppleSimulatorProbe/." "$MIMIC_FIXTURE/"
# Date of copied fixture files, without changing their source templates.
MIMIC_COPY_DATE="$(date +%d.%m.%Y)"
for MIMIC_COPY_FILE in "$MIMIC_FIXTURE/project.yml" "$MIMIC_FIXTURE/Sources/ProbeApp.swift" "$MIMIC_FIXTURE/Sources/ru.lproj/Localizable.strings"; do
  sed -E -i '' "s/Created by Василий Маслов on [0-9]{2}\.[0-9]{2}\.[0-9]{4}/Created by Василий Маслов on $MIMIC_COPY_DATE/" "$MIMIC_COPY_FILE"
done
xcodegen generate --spec "$MIMIC_FIXTURE/project.yml" --project "$MIMIC_FIXTURE" >/dev/null
xcodebuild -project "$MIMIC_FIXTURE/MimicAppleFixture.xcodeproj" -scheme MimicAppleFixture -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$MIMIC_FIXTURE/DerivedData" CODE_SIGNING_ALLOWED=NO build > "$MIMIC_FIXTURE/build.log" 2>&1
MIMIC_UDID="$(xcrun simctl create 'Mimic Apple Probe' "$MIMIC_DEVICE_TYPE" "$MIMIC_RUNTIME")"
# Keep only this exact newly created UUID for any following mutation.
printf 'Fixture directory: %s\nDisposable device UUID: %s\n' "$MIMIC_FIXTURE" "$MIMIC_UDID"
xcrun simctl boot "$MIMIC_UDID"
xcrun simctl bootstatus "$MIMIC_UDID" -b
xcrun simctl install "$MIMIC_UDID" "$MIMIC_FIXTURE/DerivedData/Build/Products/Debug-iphonesimulator/MimicAppleFixture.app"
xcrun simctl launch "$MIMIC_UDID" local.vmaslov.MimicAppleFixture
# Observe only. Taps/text remain separate explicit probe invocations based on the returned hierarchy.
"$MIMIC_ROOT/scripts/probe-apple-simulator.sh" --developer "$MIMIC_DEVELOPER" --device "$MIMIC_UDID"
printf 'Fixture retained for review. No automatic shutdown/deletion. Device UUID: %s\n' "$MIMIC_UDID"
