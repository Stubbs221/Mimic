#!/bin/bash
# Created by Василий Маслов on 04.10.2026.
# Developer acceptance gate; not a command exposed by Mimic's production plugin.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product MimicAppleProbe
MIMIC_PROBE="$(swift build --show-bin-path)/MimicAppleProbe"
# Unsigned builds remain usable with temporary approval. Explicit signed builds retain their identity.
if [ -n "${MIMIC_SIGNING_IDENTITY:-}" ]; then
  [ "$MIMIC_SIGNING_IDENTITY" != '-' ] || { echo 'Probe permanent trust requires a certificate identity, not ad-hoc signing' >&2; exit 2; }
  codesign --force --sign "$MIMIC_SIGNING_IDENTITY" --identifier local.vmaslov.MimicAppleProbe --options runtime --timestamp "$MIMIC_PROBE"
  codesign --verify --strict "$MIMIC_PROBE"
fi
exec "$MIMIC_PROBE" "$@"
