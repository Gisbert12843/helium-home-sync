# Homepage tiles

[Homepage](https://gethomepage.dev) has no plugins. Its built-in widgets read the server's `/api/stats` and the Healthchecks.io API, so the tiles need no code.

- [services.yaml](services.yaml) has two tiles:
  - **Helium Home Sync:** a status dot from `/api/health` and two rows from `/api/stats`:
    - Disk, Memory and Swap of the server's container in percent, and Limits: `OK`, or e.g. `⚠ Disk 85%` when a value reaches its limit. These are the same limits as the alerts (`LIMITS` in `server/server.py`). In Docker, Memory and Swap are the host's.
    - Database size, Visits, Devices and Last sync
  - **Healthchecks** (optional): how many of your [Healthchecks.io](https://healthchecks.io) checks are up and down (see "Alerts" in the main README)
- [custom.css](custom.css) gives the Helium Home Sync tile an accent bar, heavier values and quieter labels. Other tiles do not change.

## Setup

1. On the server, make a status token: `helium-home-sync status-token` (Docker: `./manage.sh status-token`). This token can only read `/api/stats`. Do not give Homepage the sync token, because it can read and change all history.
2. Put the secrets into Homepage's environment, for example its `.env` file:

   ```
   HOMEPAGE_VAR_HHS_STATUS_TOKEN=<status token>
   HOMEPAGE_VAR_HC_KEY=<Healthchecks read-only API key>
   ```

   The `HC_KEY` line is only for the Healthchecks tile. Make the read-only key under Project > Settings > API Access.
3. Copy the group from `services.yaml` into Homepage's own `services.yaml`. It is in Homepage's config folder: `/app/config/` in the Docker image (usually mounted from `./config/`), or `config/` in a source install, e.g. `/opt/homepage/config/`. Replace `<server>` with the server address.
4. Add the content of `custom.css` to `custom.css` in the same folder (optional).
5. Restart Homepage. It reads its environment only when it starts.

The CSS finds the tile by its name. If you rename the tile, change `data-name="Helium Home Sync"` in `custom.css` too.

## When the token changes

`helium-home-sync status-token new` makes a new status token. The old one stops working at once. Put the new one into `HOMEPAGE_VAR_HHS_STATUS_TOKEN` and restart Homepage. `helium-home-sync status-token off` removes the token.

All fields of `/api/stats` are listed in [OPERATIONS.md](../../OPERATIONS.md#status-api).
