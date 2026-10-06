#!/bin/bash
# Created by Василий Маслов on 04.10.2026.
# A local, reversible installer. Credentials are entered only in the native wizard.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$SCRIPT_DIR/Mimic.app"
DESTINATION="$HOME/Applications/Mimic.app"
CHECK_ONLY=false
UNINSTALL=false
ASSUME_YES=false
BACKGROUND=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) [ "$#" -ge 2 ] || exit 64; APP="$2"; shift 2 ;;
    --destination) [ "$#" -ge 2 ] || exit 64; DESTINATION="$2"; shift 2 ;;
    --check-only) CHECK_ONLY=true; shift ;;
    --uninstall-integration) UNINSTALL=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    --background) BACKGROUND=true; shift ;;
    *) echo 'Usage: setup-mimic.command [--app Mimic.app] [--destination path] [--check-only] [--uninstall-integration] [--yes] [--background]'; exit 64 ;;
  esac
done
MESSAGES="$SCRIPT_DIR/setup-mimic.ru.plist"
message() { /usr/libexec/PlistBuddy -c "Print :$1" "$MESSAGES"; }
fail() { message "$1" >&2; exit 1; }
check_idle() {
  local PROCESS STATUS
  for PROCESS in Mimic TaskHost; do
    if /usr/bin/pgrep -x "$PROCESS" >/dev/null 2>&1; then fail running
    else STATUS=$?; [ "$STATUS" -eq 1 ] || fail inventory; fi
  done
}
[ -f "$MESSAGES" ] || { echo 'Missing setup-mimic.ru.plist'; exit 1; }
MAJOR="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)"
[ "$MAJOR" -ge 14 ] || fail os
if "$UNINSTALL"; then APP="$DESTINATION"; fi
[ -d "$APP" ] || fail missing
APP="$(cd "$APP" && pwd -P)"
PLIST="$APP/Contents/Info.plist"
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)"
[ "$BUNDLE" = local.vmaslov.Mimic ] || fail bundle
# Verify the current bundle and its expected executable.
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST" 2>/dev/null || true)"
case "$EXECUTABLE" in Mimic) ;; *) fail helper ;; esac
HOST_ARCH="$(/usr/bin/uname -m)"
if [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then HOST_ARCH=arm64; fi
for RELATIVE in "Contents/MacOS/$EXECUTABLE" Contents/Helpers/TaskHost Contents/Helpers/MimicMCP; do
  [ -x "$APP/$RELATIVE" ] || fail helper
  /usr/bin/codesign --verify --strict "$APP/$RELATIVE" >/dev/null 2>&1 || fail signature
  ARCHS="$(/usr/bin/lipo -archs "$APP/$RELATIVE" 2>/dev/null || true)"
  case " $ARCHS " in *" $HOST_ARCH "*) ;; *)
    if [ "$HOST_ARCH" = arm64 ]; then case " $ARCHS " in *" arm64e "*) ;; *) fail architecture ;; esac
    else fail architecture; fi ;;
  esac
done
/usr/bin/codesign --verify --strict "$APP" >/dev/null 2>&1 || fail signature
if "$CHECK_ONLY"; then message valid; exit 0; fi
if "$UNINSTALL"; then
  "$APP/Contents/MacOS/$EXECUTABLE" --uninstall-integration >/dev/null 2>&1 &
  exit 0
fi
mkdir -p "$(dirname "$DESTINATION")"
DEST_PARENT="$(cd "$(dirname "$DESTINATION")" && pwd -P)"
DESTINATION="$DEST_PARENT/$(basename "$DESTINATION")"
if [ "$APP" != "$DESTINATION" ]; then
  if [ -L "$DESTINATION" ]; then fail destination; fi
  if [ -e "$DESTINATION" ]; then
    # Conservative: no replacement while the queue owner or task host is running.
    check_idle
    OLD_BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)"
    [ "$OLD_BUNDLE" = local.vmaslov.Mimic ] || fail destination
    printf '%s\n' "$DESTINATION"
    if ! "$ASSUME_YES"; then message replace; fi
    if "$ASSUME_YES"; then ANSWER=yes; else IFS= read -r ANSWER; fi
    case "$ANSWER" in y|Y|yes|YES|д|Д|да) ;; *) message cancelled; exit 0 ;; esac
  else
    printf '%s\n' "$DESTINATION"
    if ! "$ASSUME_YES"; then message install; fi
    if "$ASSUME_YES"; then ANSWER=yes; else IFS= read -r ANSWER; fi
    case "$ANSWER" in y|Y|yes|YES|д|Д|да) ;; *) message cancelled; exit 0 ;; esac
  fi
  STAGING="$(/usr/bin/mktemp -d "$DEST_PARENT/.mimic-install.XXXXXX")"
  trap 'rm -rf "$STAGING"' EXIT
  /usr/bin/ditto "$APP" "$STAGING/Mimic.app"
  /usr/bin/codesign --verify --strict "$STAGING/Mimic.app" >/dev/null 2>&1 || fail signature
  # Recheck immediately before mutation; never terminate a running task.
  check_idle
  BACKUP=""
  if [ -e "$DESTINATION" ]; then
    BACKUP="$DEST_PARENT/Mimic.backup.$(/bin/date +%Y%m%d-%H%M%S).$RANDOM.app"
    /bin/mv "$DESTINATION" "$BACKUP"
  fi
  if ! /bin/mv "$STAGING/Mimic.app" "$DESTINATION"; then
    [ -z "$BACKUP" ] || /bin/mv "$BACKUP" "$DESTINATION"
    fail destination
  fi
fi
if "$BACKGROUND"; then
  message background
  /usr/bin/open -a "$DESTINATION" --args --mcp-background
  exit 0
fi
message opening
# Calling the executable forwards to the existing instance, or launches the app's event loop.
"$DESTINATION/Contents/MacOS/$EXECUTABLE" --setup >/dev/null 2>&1 &
