#!/bin/bash
# Created by Василий Маслов on 05.10.2026.
set -euo pipefail
source "$(dirname "$0")/signing-identity.sh"
FIXTURE=$(mktemp -d /private/tmp/MimicSigning.XXXXXX)
trap 'rm -rf "$FIXTURE"' EXIT
CERT='0123456789ABCDEF0123456789ABCDEF01234567'
INVENTORY="  1) $CERT \"Developer ID Application: Fixture (TEAM)\""
PREF="$FIXTURE/preference"
expect_choice() { mimic_resolve_signing_identity "$PREF"; [ "$MIMIC_SELECTED_IDENTITY" = "$1" ]; mimic_validate_signing_identity "$INVENTORY"; }
unset MIMIC_SIGNING_IDENTITY
if mimic_resolve_signing_identity "$PREF" 2>/dev/null; then exit 1; fi
printf '%s\n' "$CERT" > "$PREF"
expect_choice "$CERT"
MIMIC_SIGNING_IDENTITY='-'; expect_choice '-'
MIMIC_SIGNING_IDENTITY='Developer ID Application: Fixture (TEAM)'; expect_choice "$MIMIC_SIGNING_IDENTITY"
MIMIC_SIGNING_IDENTITY=''; if mimic_resolve_signing_identity "$PREF" 2>/dev/null; then exit 1; fi
MIMIC_SIGNING_IDENTITY='invalid'; mimic_resolve_signing_identity "$PREF"; if mimic_validate_signing_identity "$INVENTORY" 2>/dev/null; then exit 1; fi
MIMIC_SIGNING_IDENTITY="$CERT"; mimic_resolve_signing_identity "$PREF"; if mimic_validate_signing_identity '' 2>/dev/null; then exit 1; fi
unset MIMIC_SIGNING_IDENTITY
: > "$PREF"; if mimic_resolve_signing_identity "$PREF" 2>/dev/null; then exit 1; fi
rm "$PREF"; mkdir "$PREF"; if mimic_resolve_signing_identity "$PREF" 2>/dev/null; then exit 1; fi
printf 'PASS: signing identity precedence and 5 fail-closed cases\n'
