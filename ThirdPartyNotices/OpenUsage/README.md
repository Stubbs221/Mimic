<!-- Created by Василий Маслов on 05.10.2026. -->
# OpenUsage algorithms and public catalogs

Adapted from OpenUsage 0.7.13, commit `1a53f7567f7289e9339c7b2876cfcf220f43935c`, https://github.com/robinebers/openusage.
Copyright (c) 2026 Robin Ebers, MIT; original license retained in LICENSE.

The port includes pace/meter rules, Codex and Claude usage normalization, model catalog decoding/resolution, bundled public pricing snapshots and the 31-day token trend, including hover dwell/grace behavior and the detail chart selection. Public catalog refresh URLs are unchanged. No OpenUsage process, private cache, credentials or telemetry is used. Spend tiles, cloud sync and account swapping are not included.

Claude Desktop read-only OAuth cache decryption and account-scoped token selection are also adapted from commit `66aada23bfbac5c5988617fdd6a0f8edbe106764` (12.10.2026). Mimic reads only a currently valid access token; it does not rotate Desktop credentials or write its storage.

JSON catalogs retain their original schemas and have no added authorship fields.
