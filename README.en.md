<!-- Created by Василий Маслов on 06.10.2026. -->
# Mimic

<img src="Artwork/Plugin/MimicPluginIcon.png" alt="Mimic" width="96" height="96">

[Русский](README.md) · English

**Apple development at hand — in the macOS menu bar and inside Codex.**

Mimic brings local tasks, terminals, Simulator builds, selected tests and CI monitoring together. Run your team's familiar workflows through a profile and follow their results in one place.

[Download Mimic](https://github.com/Stubbs221/Mimic/releases/latest) · [Installation](docs/MimicSetup.md) · [Report an issue](https://github.com/Stubbs221/Mimic/issues)

## Features

- Project preparation, utilities and file generation with previews.
- A shared sequential local queue with progress, cancellation, history and terminals.
- Builds and selected tests on a specific iOS/tvOS Simulator.
- Jenkins/GitLab monitoring and actions configured by your team profile.
- A task panel inside Codex with a separate project context for each chat.
- Supported AI tool limits and usage history.
- Automatic updates: downloads new versions and installs after local work finishes.

## Screenshots

The menu bar panel:

![Mimic menu bar panel](docs/images/mimic-panel.png)

The Codex panel:

![Mimic panel for Codex](docs/images/codex-panel.png)

Update settings:

![Mimic update settings](docs/images/updates.png)

These images show the actual interface with demonstration data. The Codex panel was captured in an isolated preview.

## Getting started

1. Download `MimicSetup-1.3.1.zip` from Releases and extract it.
2. Run `setup-mimic.command` or move `Mimic.app` into Applications.
3. Select a Git project, import a trusted team profile, and choose Xcode and the Apple target.
4. Connect Codex and CI in settings if needed.

**A compatible `.mimicprofile` is required to open the workspace.** Obtain it from your team: private commands, adapters and service addresses are supplied separately. Mimic does not include a ready-to-use profile for your project. Source fixtures are not production team configurations. CI connections are optional; credentials are stored in macOS Keychain.

## Compatibility and updates

The release targets **Apple Silicon**, with **macOS 14** as the minimum system version. Intel and runtime on macOS 14 have not been tested. The interface is currently Russian. Development requires Xcode and the tools used by your profile; Codex integration requires a local version supporting plugins and MCP Apps.

After the first installation of a version with the updater, Mimic checks for updates hourly. Settings include manual checking and an automatic update switch. Installation waits for local work to finish; profiles, settings and history are preserved. Older versions without the updater need one manual installation.

## Help

The detailed user guides are currently in Russian.

[Installation](docs/MimicSetup.md) · [Profiles](docs/Profiles.md) · [Codex](docs/CodexPlugin.md) · [Troubleshooting](docs/Troubleshooting.md) · [Changes](CHANGELOG.md)

[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

The source is licensed under [MIT](LICENSE). Bundled components retain the licenses listed in [ThirdPartyNotices](ThirdPartyNotices/README.md).
