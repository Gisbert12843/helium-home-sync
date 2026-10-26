# Operations: backups, alerts and the status API

This page explains how to keep a Helium Home Sync server healthy for a long time with little work. Every feature here is optional. You can turn each one on or off at any time, and an update never turns one on without asking.

## Overview

| Feature | New installs | Turn on | Turn off |
|---|---|---|---|
| [Daily backups](#backups) with automatic cleanup | on, 03:30, keep 14 | `backups on [HH:MM] [count]` | `backups off` |
| [Health check with alerts](#health-check-and-alerts) | off | `monitor on <ping URL>` | `monitor off` |
| [Status token](#status-api) for dashboards | off | `status-token` | `status-token off` |
| [Limits](#limits) for disk, memory and swap | 80 %, 90 %, 50 % | `limits disk 85` | `limits disk default` |

Where to run the commands:

- **Proxmox LXC:** `helium-home-sync <command>` in the container, or `pct exec <ctid> -- helium-home-sync <command>` on the host.
- **Proxmox host, with a menu:** `./proxmox-lxc.sh settings <ctid>` shows all four features and turns them on or off.
- **Docker:** `./manage.sh <command>` in the `server/` folder.

The settings are stored in the server's env file: `/etc/helium-home-sync/env` in the LXC container, `server/.env` with Docker. Updates keep them.

## Backups

A backup is a consistent copy of the database. The server keeps running while it is made.

**Where:** `/var/lib/helium-home-sync/backups/` in the LXC container, `server/backups/` with Docker.

**Which backups exist, and which are deleted automatically:**

| File name | Made by | Kept |
|---|---|---|
| `auto-<date>.db` | the daily backup | the newest `BACKUP_KEEP` (default 14) |
| `update-<date>.db` | `./proxmox-lxc.sh update` and `tools/deploy.sh`, before they install new code | the newest 3 |
| `helium-home-sync-<date>.db` | you, with `backup` | always |
| `before-restore-<date>.db`, `before-wipe-<date>.db` | `restore` and `wipe`, as a safety copy | always |

Only the first two kinds are deleted automatically. Delete the others by hand when you no longer need them.

**Disk space:** each backup is about as large as the database. For example, 17 backups of a 30 MB database need about 510 MB. The [health check](#health-check-and-alerts) alerts you when the disk is 80 % full.

**Commands:**

```bash
helium-home-sync backups                  # on or off, time, cleanup rule, newest files
helium-home-sync backups on 03:30 14      # every day at 03:30, keep the newest 14
helium-home-sync backups off              # stop (the existing backups stay)
helium-home-sync backup                   # one backup now, never deleted automatically
helium-home-sync restore <file>           # replace all data with a backup (makes a safety copy first)
```

In the LXC container, a systemd timer (`helium-home-sync-backup.timer`) runs the daily backup. Docker has no timer of its own, so `./manage.sh backups on` prints a line for your crontab.

**Keep a copy elsewhere.** The backups are on the same disk as the database. Also back up the whole container with Proxmox (Datacenter > Backup), or copy the backup folder to another machine from time to time.

## Health check and alerts

The health check tests the server and reports the result to a URL. Healthchecks.io (or a self-hosted [Healthchecks](https://github.com/healthchecks/healthchecks)) receives the reports and alerts you by email, app or chat when something is wrong.

**What the check tests:**

| Test | Fails when |
|---|---|
| Service | the server process does not run |
| API | `/api/health` does not answer |
| Disk, memory, swap | a value reaches its [limit](#limits) |
| Backups | daily backups are on, and the newest one is older than 48 hours |

**How it reports:** when every test passes, it sends a POST to the URL. When a test fails, it sends a POST to `<URL>/fail`. The report text goes in the body, so Healthchecks.io shows why. When the reports stop, for example because the host is down, Healthchecks.io alerts you too.

### Set up alerts with Healthchecks.io

1. Sign up at [healthchecks.io](https://healthchecks.io). The free plan is enough.
2. Click **Add Check**. Give it a name, for example `helium-home-sync`.
3. Click **Change Schedule**. Keep **Simple**. Set the period to **5 minutes** and the grace time to **30 minutes**. Short restarts and updates then do not alert you.
4. Open **Integrations** and add the channels you want, for example email and a phone app. Make sure each channel is on for the check.
5. Copy the check's **ping URL**, for example `https://hc-ping.com/5f3c…`. Treat it like a password: anyone with it can send fake "OK" reports.
6. Turn on the health check:

   ```bash
   helium-home-sync monitor on https://hc-ping.com/<uuid>
   ```

   On the Proxmox host, `./proxmox-lxc.sh settings <ctid>` > **Alerts** does the same. The command sends a first report. After a few seconds the check on Healthchecks.io turns green.

7. Test an alert. This stops the server for about a minute. Devices keep working offline and upload later.

   ```bash
   systemctl stop helium-home-sync && helium-home-sync monitor     # Healthchecks.io reports "down"
   systemctl start helium-home-sync && helium-home-sync monitor    # back to "up"
   ```

**Docker:** `./manage.sh monitor on <URL>` stores the URL and prints a crontab line that runs the check every 5 minutes.

**Commands:**

```bash
helium-home-sync monitor                  # run the check now and print the report
helium-home-sync monitor on <ping URL>    # run it every 5 minutes and report to the URL
helium-home-sync monitor off              # stop it (also pause the check on Healthchecks.io)
```

## Limits

The health check and the [status API](#status-api) report a problem when the disk, the memory or the swap reaches its limit.

| Setting in the env file | Default | Measures |
|---|---|---|
| `LIMIT_DISK` | 80 | the used part of the disk that holds the database |
| `LIMIT_MEMORY` | 90 | the used memory |
| `LIMIT_SWAP` | 50 | the used swap |

```bash
helium-home-sync limits                   # usage now, and the limits
helium-home-sync limits disk 85 swap 60   # change one or more (the server restarts for a moment)
helium-home-sync limits disk default      # back to the default
```

In an LXC container, memory and swap are the container's own. With Docker, they are the host's.

## Status API

The server has two read-only endpoints for monitoring. The sync endpoints are in [PROTOCOL.md](PROTOCOL.md).

### `GET /api/health`

No token. Use it for uptime monitors.

```json
{"ok": true, "version": "1.1.0", "protocol": 1}
```

### `GET /api/stats`

Needs `Authorization: Bearer <token>`. The token is the **status token** or the sync token.

Give dashboards the status token, never the sync token. The status token can only read `/api/stats`. The sync token can read and change all history.

```bash
helium-home-sync status-token             # show it, or make one (asks first)
helium-home-sync status-token new         # replace it (the old one stops working at once)
helium-home-sync status-token off         # remove it
```

Example:

```bash
curl -H "Authorization: Bearer <status token>" http://<server>:8787/api/stats
```

```json
{"version": "1.1.0", "visits": 28621, "deletes": 4, "purges": 1, "devices": 3, "lastSeq": 28731,
 "lastUpload": 1792671925671, "dbBytes": 33809728, "diskPct": 27, "memoryPct": 24, "swapPct": 20,
 "limits": "OK", "serverId": "d1c3e757309d4b0f84831022a7e7ad18"}
```

| Field | Type | Meaning |
|---|---|---|
| `version` | string | server version |
| `visits` | number | visits stored on the server |
| `deletes` | number | stored delete changes |
| `purges` | number | removed devices |
| `devices` | number | devices with at least one visit on the server |
| `lastSeq` | number | number of the newest change in the log |
| `lastUpload` | number or null | when the server received the newest change from a device (ms since 1970) |
| `dbBytes` | number | size of the database and its WAL file |
| `diskPct` | number | used part of the disk that holds the database, in percent |
| `memoryPct` | number or null | used memory in percent (null if the system does not report it) |
| `swapPct` | number or null | used swap in percent, 0 without swap |
| `limits` | string | `OK`, or each value at or above its [limit](#limits), e.g. `⚠ Disk 85%, Swap 60%` |
| `serverId` | string | random id of this database. It changes when the database is wiped or replaced. |

New versions can add fields. A field is not renamed or removed without a note in [CHANGELOG.md](CHANGELOG.md).

## Dashboards

Any dashboard that can read JSON with an `Authorization` header can show the stats.

- **Homepage:** [integrations/homepage/](integrations/homepage/) has a ready-made tile with usage, limits and sync numbers.
- **Other dashboards** (Homarr, Dashy, Glance, …): use their generic JSON or API widget. Set the URL to `http://<server>:8787/api/stats`, add the header `Authorization: Bearer <status token>`, and pick fields from the table above. Show `limits` to see at a glance if something needs attention.
- **Uptime monitors:** check `/api/health`. It needs no token.
