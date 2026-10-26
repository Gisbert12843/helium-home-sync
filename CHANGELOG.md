# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## Unreleased

- Fixed: synced pages dropped out of the address-bar suggestions 3 days after the sync. Each synced visit now adds a visit to Helium's history, and pages typed on another device stay in the suggestions. The update adds the missing visits for the last 90 days once.
- Added: daily backups with automatic cleanup (`helium-home-sync backups on|off`). They keep the newest 14. Backups made before an update keep the newest 3. `update` asks once if a container never chose. See OPERATIONS.md.
- Added: an optional health check with alerts (`helium-home-sync monitor on <ping URL>`). Every 5 minutes it checks the service, disk, memory, swap and the age of the newest backup, and reports to Healthchecks.io.
- Added: limits for disk, memory and swap (`helium-home-sync limits`, or `LIMIT_DISK`, `LIMIT_MEMORY`, `LIMIT_SWAP` in the env file).
- Added: `./proxmox-lxc.sh settings <ctid>` turns backups, alerts, the dashboard token and the limits on or off in a menu. The advanced install asks for alerts and the dashboard token.
- Added: an optional status token (`helium-home-sync status-token [new|off]`) that can only read `/api/stats`. Dashboards no longer need the sync token. `/api/stats` now also returns the version, the last upload, the database size, the disk, memory and swap usage, and `limits`. OPERATIONS.md documents every field.
- Added: a [Homepage](https://gethomepage.dev) dashboard tile in `integrations/homepage/`.
- Added: `tools/deploy.sh` deploys the server from a git checkout to a Proxmox LXC install. It runs the checks first, shows what changes, asks, and verifies the new version.

## [1.0.0] - 2026-10-10

First public release.

- History sync between Helium installs through a self-hosted server: address bar suggestions, a combined history page (Ctrl+H) with per-device badges, search and delete, and a toolbar popup with per-device controls.
- Server as a single stdlib-only Python file, run with Docker (`manage.sh`), as a Proxmox LXC container (`proxmox-lxc.sh`) or directly.
- Sync protocol version check: the extension shows a clear "update the server/extension" error when the two don't match.
- The extension is published as a zip on every GitHub Release.

[1.0.0]: https://github.com/Gisbert12843/helium-home-sync/releases/tag/v1.0.0
