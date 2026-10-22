# Helium Home Sync

Syncs browsing history between your [Helium](https://helium.computer) installs through a small server you run yourself.

*Not affiliated with the Helium browser project.*

- **Address bar:** pages you visited on another device are suggested as you type.
- **History page (Ctrl+H):** one timeline of all devices. Every visit keeps its real time, with a badge showing which device it came from. It has search, a device filter and delete.
- **Toolbar popup:** status, settings, and per-device controls.

```
 Helium (laptop) ──upload──▶  server  ◀──upload── Helium (desktop)
                 ◀─download─ (SQLite) ─download─▶
```

The server is a dumb, append-only change log and never interprets your history; all the logic is in the extension. Nothing besides the extension runs on your devices.

## Quick start

### 1. Server (Docker)

```bash
cd server
cp .env.example .env
python3 -c 'import secrets; print(secrets.token_urlsafe(32))'   # paste this as SYNC_TOKEN in .env
./manage.sh start
./manage.sh connect        # prints the server URL and token to enter on each device
```

Run `./manage.sh` without arguments at any time to see every management command (see [Server management](#server-management)).

### 2. Extension (each device)

1. Open `helium://extensions` and turn on **Developer mode**.
2. Download `helium-home-sync-extension-*.zip` from the [latest release](https://github.com/Gisbert12843/helium-home-sync/releases/latest) and unzip it (or use the `extension/` folder of a clone). Click **Load unpacked** and choose the unzipped folder.
3. Pin the extension (puzzle icon), click it, and enter:
   - **Server URL:** what `./manage.sh connect` printed, for example `http://192.168.2.105:8787` or your Tailscale address.
   - **Token:** from `server/.env`.
   - **Device name:** for example "Laptop".
4. Click **Test connection**, then **Save**, and allow access to the server when Helium asks.
5. Optional: click **Upload existing history** to share history from before you installed the extension.

## Using it

| Where | What |
|---|---|
| Popup → **Sync now** | Upload and download immediately. Otherwise visits upload about 30 s after you open a page, and downloads happen on browser start (or on an interval you pick under Settings). |
| Popup → device list → click a device | **Hide in history**: only this device's history page stops showing it.<br>**Remove from sync**: deletes that device's visits from the server and all other devices. The device itself keeps its own history and shows **Add back to sync**, which uploads it again. |
| Popup → **Pause** | Stops all network activity. New visits wait and upload after you resume. |
| Ctrl+H → **Remove** (click twice) | Deletes every visit to that page on all devices. Deleting in Helium's own UI ("Clear browsing data", etc.) propagates the same way. |
| Settings → **Send / Accept “Clear all history”** | Off by default. Clearing *all* history only reaches other devices when the sender has "Send" and the receiver has "Accept" enabled. |

The yellow ⚠ next to the server URL means the connection is plain `http://`. That's fine on localhost, your LAN or Tailscale (which encrypts already). Over the internet, use HTTPS (see below).

The popup's toolbar icon shows a red `!` when the last sync failed (the popup shows why) and `II` while paused.

## Server management

Everything goes through `server/manage.sh`. Run it without arguments for this list:

| Command | What it does |
|---|---|
| `status` | Running? Health, totals, and the URLs devices should use |
| `start` · `stop` · `restart` · `logs` | Container control |
| `update` | Rebuild and restart after `server.py` or `admin.py` changed |
| `set-port <port>` | Move the server to another port (also moves Tailscale HTTPS). Devices need the new Server URL. |
| `devices` | Every device with visit counts, time range and last upload |
| `stats` | Totals (visits, deletes, device removals) and database size |
| `remove-device <name or id>` | Same as "Remove from sync" in the popup, from the server side |
| `prune <days>` | Delete server copies of visits older than N days. Devices keep theirs; new devices just get less. |
| `backups [on [HH:MM] [count] \| off]` | Daily backups with automatic cleanup (see [OPERATIONS.md](OPERATIONS.md#backups)) |
| `backup [file]` | Consistent copy to `server/backups/`, never deleted automatically |
| `restore <file>` | Replace all server data with a backup (makes a safety backup first) |
| `monitor [on <ping URL> \| off]` | Health check: run it now, or every 5 minutes with alerts via Healthchecks.io |
| `limits [disk\|memory\|swap <percent>]` | Usage and the limits at which the health check reports a problem |
| `connect` · `token` · `rotate-token` | Set up a device, show the token, replace the token |
| `status-token [new \| off]` | Read-only token for `GET /api/stats`, so dashboards do not need the sync token |
| `vacuum` · `check` | Shrink the file after big deletions, run an integrity check |
| `wipe` | Delete everything (backs up first). Devices notice and offer to upload their history again. |

Data lives in the Docker volume `helium-home-sync_helium-home-sync-data`. The token and the port (`PORT`, default 8787) live in `server/.env`.

**Without Docker:** `SYNC_TOKEN=... python3 server/server.py` (stdlib only, Python 3.10+; env `PORT`, `HOST`, `DB_PATH`). The admin commands are then `DB_PATH=... python3 server/admin.py <command>`.

**Proxmox:** `server/proxmox-lxc.sh` installs the server into a new LXC container without Docker. Run it on the Proxmox host; it offers default or advanced settings in dialogs, and `./proxmox-lxc.sh help` lists every setting with its possible values. Later, `./proxmox-lxc.sh settings` turns backups, alerts, the dashboard token and the limits on or off in a menu, and `./proxmox-lxc.sh rename` and `./proxmox-lxc.sh port` change the container's name or the server's port. Inside the container, `manage.sh` is installed as `helium-home-sync` and takes the same commands.

**Backups, alerts and dashboards:** [OPERATIONS.md](OPERATIONS.md) explains the daily backups and their cleanup, the health check with alerts via [Healthchecks.io](https://healthchecks.io) (step by step), the limits, and the status API for dashboards. [integrations/homepage/](integrations/homepage/) has a ready-made tile for [Homepage](https://gethomepage.dev). All of these are optional.

### HTTPS with Caddy (for internet-facing servers)

Bind the container to localhost (`"127.0.0.1:${PORT:-8787}:8787"` under `ports:` in `docker-compose.yml`) and put Caddy in front:

```
history.example.com {
    reverse_proxy 127.0.0.1:8787
}
```

Caddy fetches the certificate itself. Then use `https://history.example.com` as the Server URL.

## Updating

- **Extension:** after replacing or editing the files, click **Reload ↻** on the extension's card in `helium://extensions`. Without that, Helium keeps running the old background script even across restarts.
- **Server (Docker):** `./manage.sh update-backup && ./manage.sh update`.
- **Server (Proxmox):** copy the `server/` folder to the Proxmox host again, then run `./proxmox-lxc.sh update <ctid>` there. It backs up the database first and keeps the newest 3 of these update backups. If the container never chose about daily backups, it asks once.
- **Server (Proxmox, from a git checkout):** `tools/deploy.sh --ct <ctid> root@<proxmox-host>`, or `tools/deploy.sh root@<container>` if you can SSH into the container. It runs the checks and the smoke test, shows the version and the files that change, and asks first. It compares the installed files, not the version number. `-n` only shows, `-f` installs even when no file differs. Set `HHS_DEPLOY_TARGET` (and `HHS_DEPLOY_CT`) to skip the arguments.

## Good to know

- **Native history (Helium's own history list):** synced pages appear there with the time they were *synced*, not when they were visited, because the extension API can't set visit times. That's why the extension replaces Ctrl+H. To get Helium's own page back, disable the extension.
- **Address bar:** synced pages follow the same rules as local pages. A page stays in the suggestions when it was typed on any device or has 4 or more visits. Other pages drop out 3 days after their last visit. The extension API can only add "link" visits without a title. So only pages typed on this device complete inline as you type, and words from a synced page's title do not find it.
- **90-day expiry:** Helium forgets history after 90 days. That expiry is *not* sent to other devices, and the extension's history page keeps older visits.
- **Partial deletes:** "Clear browsing data → last hour" only syncs for pages that were removed completely. Pages with older visits left over aren't propagated.
- **Incognito** is never synced.
- **Search:** with very large histories (100k+ visits), the first keystroke of a search loads an index (about 1–2 s); after that, search is instant. Above 300,000 visits there is no index and search scans the database, which is slower.
- **Encryption:** the server sees URLs and titles. End-to-end encryption is planned (see `PROTOCOL.md`); keep the server on a machine you trust.

## Scope

Helium Home Sync syncs **browsing history**. **Password sync is deliberately out of scope**: use a password manager for that.

Other things a browser could sync (bookmarks, open tabs, settings, …) aren't planned right now, because I don't need them myself. They may come if enough people ask, so open a feature request or 👍 an existing one.

## Project layout

```
extension/      MV3 extension, plain JS, no build step
  background/   sync engine (upload, download, deletes, counts)    lib/   storage, API client, shared helpers
  popup/ options/ ui/   toolbar popup and settings                  history/   Ctrl+H page
server/         server.py (HTTP API), schema.sql, admin.py (admin commands), manage.sh, Docker files
  text/         help and setup texts printed by manage.sh
  proxmox-lxc.sh   Proxmox installer; proxmox/ holds its help text, systemd units and the in-container install steps
tools/          icon generator, server smoke test, version check (used by CI), deploy.sh
integrations/   homepage/: a Homepage dashboard tile
PROTOCOL.md     wire format and sync rules
OPERATIONS.md   backups, health check and alerts, limits, status API for dashboards
```

## Contributing

Bug reports, fixes and ideas are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the development setup. Please report security problems privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
