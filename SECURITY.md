<!-- Created by Василий Маслов on 06.10.2026. -->
# Security

Report vulnerabilities through GitHub's private vulnerability reporting feature when available. If private reporting is unavailable, do not post confidential details in a public issue; ask the maintainer for a private reporting route. No response-time guarantee is published.

Include the affected version and a minimal synthetic reproduction. Never attach credentials, private profiles, terminal input or complete environment dumps.

Imported profile adapters are trusted executable programs, not sandboxed commands. Review their source before use. CI credentials are stored in macOS Keychain; application packages and public source do not include private team configuration.

Download published application packages from this repository's Releases. Update archives and the feed are independently signed. Bundled components retain their own [licenses and notices](ThirdPartyNotices/README.md).
