#!/bin/bash
# Created by Василий Маслов on 05.10.2026.
# Explicit choices fail closed; an absent choice preserves the ad hoc development fallback.
mimic_resolve_signing_identity() {
  local preference="$1"
  if [ "${MIMIC_SIGNING_IDENTITY+x}" = x ]; then
    MIMIC_SELECTED_IDENTITY="$MIMIC_SIGNING_IDENTITY"
  elif [ -e "$preference" ]; then
    [ -f "$preference" ] && [ -r "$preference" ] || { echo 'Signing preference is unavailable.' >&2; return 64; }
    MIMIC_SELECTED_IDENTITY=$(cat "$preference")
  else
    MIMIC_SELECTED_IDENTITY='-'
  fi
  [ -n "$MIMIC_SELECTED_IDENTITY" ] || { echo 'Signing identity is empty.' >&2; return 64; }
  case "$MIMIC_SELECTED_IDENTITY" in *$'\n'*|*$'\r'*) echo 'Signing identity must be one line.' >&2; return 64 ;; esac
}

mimic_validate_signing_identity() {
  [ "$MIMIC_SELECTED_IDENTITY" != '-' ] || return 0
  local identities="$1"
  # Match a complete fingerprint or complete quoted certificate name, never a substring.
  python3 - "$MIMIC_SELECTED_IDENTITY" "$identities" <<'PY'
import re, sys
choice, inventory = sys.argv[1:]
identities = re.findall(r'\b([0-9A-Fa-f]{40}) "([^"\n]+)"', inventory)
if not any(choice.upper() == fingerprint.upper() or choice == name for fingerprint, name in identities):
    print('Configured signing identity is invalid or unavailable; no fallback was selected.', file=sys.stderr)
    sys.exit(64)
PY
}
