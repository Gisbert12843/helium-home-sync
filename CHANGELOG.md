# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-10-10

First public release.

- History sync between Helium installs through a self-hosted server: address bar suggestions, a combined history page (Ctrl+H) with per-device badges, search and delete, and a toolbar popup with per-device controls.
- Server as a single stdlib-only Python file, run with Docker (`manage.sh`), as a Proxmox LXC container (`proxmox-lxc.sh`) or directly.
- Sync protocol version check: the extension shows a clear "update the server/extension" error when the two don't match.
- The extension is published as a zip on every GitHub Release.

[1.0.0]: https://github.com/Gisbert12843/helium-home-sync/releases/tag/v1.0.0
