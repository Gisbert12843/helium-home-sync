# Sync protocol

The server is an append-only log of **changes**. Clients upload their own changes and download everyone else's in log order. Ordering comes only from the server's `seq`, never from device clocks; timestamps in changes are for display and delete rules.

## HTTP API

All endpoints except `/api/health` need `Authorization: Bearer <SYNC_TOKEN>`. CORS is open, because auth is by token. `GET /api/stats` also accepts the optional status token (`STATUS_TOKEN`). That token cannot read or write changes.

| Request | Response |
|---|---|
| `GET /api/health` | `{ok: true, version, protocol}` |
| `POST /api/changes` with `{changes: Change[]}` (max 500, body max 5 MB) | `{accepted, lastSeq}`. Re-sending a known `id` is ignored, so retries are safe. One invalid change rejects the whole batch (400). |
| `GET /api/changes?since=<seq>&limit=<n>` (default 1000, max 5000) | `{changes: [{seq, deviceId, payload}], cursor, hasMore, lastSeq, serverId}` |
| `GET /api/stats` | Counts, sizes and usage for monitoring. The fields are listed in [OPERATIONS.md](OPERATIONS.md#status-api). |

`serverId` is random per database. A client that sees a different `serverId`, or a `lastSeq` below its cursor, knows the server was wiped, restored or replaced. It then re-reads the log from 0 and marks its own uploaded visits "not on the server" so the user can upload them again.

### Versioning

`protocol` (in `/api/health`) and the `X-Sync-Protocol` header (on every response) carry the protocol version, currently `1`. The extension refuses to sync with a server whose version differs from its own and tells the user which side to update. A missing header counts as `1`.

Bump the version (`PROTOCOL_VERSION` in `server/server.py` and `extension/lib/api.js`) only for changes that the other side can't handle. Additive changes, like a new optional field, don't need a bump.

## Changes

Every change has `type`, a globally unique `id`, the uploading `deviceId` (a UUID made on install) and `deviceName`. `urlKey` is `sha256(url)` in hex. In v2 it becomes an HMAC with the sync key, so the server can still match deletes once payloads are encrypted.

```ts
{ type: "visit",  id: `${deviceId}:${chromeVisitId}:${visitTime}`, deviceId, deviceName,
  url, urlKey, title, visitTime /* ms epoch */, transition }

{ type: "delete", id: `${deviceId}:del:${uuid}`, deviceId, deviceName,
  url | null, urlKey | null /* both null = delete all history */, deletedAt }

{ type: "purge",  id: `${deviceId}:purge:${uuid}`, deviceId, deviceName,
  targetDeviceId, before }      // remove a device's visits up to `before` from sync

{ type: "rejoin", id: `${deviceId}:rejoin:${uuid}`, deviceId, deviceName,
  at }                          // a removed device is added back to sync
```

Chromium visit ids can be reused after deletions, so the visit time is part of the id.

## Server rules

The server only reads the envelope fields above; everything else is stored as-is.

- **Validation:** `id`, `deviceId` and the type's time field are required; times are positive ms epochs. A visit's `url` must be `http(s)://`, and `urlKey` is 16–128 lowercase hex characters. A delete has both `url` and `urlKey`, or neither.
- **delete with a URL:** removes stored visits with that `urlKey` and `visitTime ≤ deletedAt`.
- **delete-all:** removes all stored visits with `visitTime ≤ deletedAt`.
- **purge:** removes stored visits of `targetDeviceId` with `visitTime ≤ before`. The target's other records up to `before` (deletes, rejoins) stay but are re-assigned to `server-admin`, so the device no longer counts as a device. Their payloads are unchanged.
- **rejoin:** lifts every earlier purge of `deviceId`, so its visits are accepted again. Within one upload batch, rejoins are applied before visits. A rejoin from a device that was never removed is ignored and not stored.
- **Late visits:** a visit that arrives after a delete or purge covering it (an offline device catching up) is dropped, unless a rejoin of that device lifted the purge.
- **Kept records:** delete and purge records stay in the log, so new devices learn about them and late visits stay blocked.

## Client rules

- **Uploads:** local visits are found by scanning Helium's history from a persisted watermark, not from in-memory events, so a stopped service worker loses nothing. Everything goes through a persistent outbox.
- **Address bar:** each new remote visit from the last 90 days adds one native visit with `history.addUrl`, up to 10 per URL. Above 10, each pull with new visits for a URL adds one visit. A URL typed on another device gets at least 4 native visits, so Chromium keeps it in the suggestions. Reloads do not count. An extension update adds the missing visits once.
- **Echo prevention:** the visit ids from `history.addUrl` are recorded and never uploaded. A 30-second `suppress` list covers the events that our own `addUrl` and `deleteUrl` calls fire.
- **Incoming deletes:**
  - **delete:** removes the URL from native history only if this device has no own visit after `deletedAt`.
  - **delete-all:** applied only if the user enabled "Accept".
  - **purge:** other devices drop the target's visits, and drop autofill imports that only existed because of it. The target device keeps its history but marks its visits up to `before` as "not on the server" and offers "Add back to sync". That sends a rejoin (before any other upload), then uploads them again. Purges older than its last rejoin are ignored when it re-reads the log.
  - **rejoin:** other devices clear their `device:<id>` tombstone, so the re-uploaded visits are applied.
- **Tombstones:** each client keeps tombstones (`url`, `*`, `device:<id>`), so visits that arrive late stay hidden.
- **Expiry:** a removal is treated as Chromium's 90-day expiry, and not propagated, when everything known about the URL is older than 85 days.
