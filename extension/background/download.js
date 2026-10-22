import { tx, promisify, getMeta, setMeta, iterate } from "../lib/db.js";
import { canSync } from "../lib/settings.js";
import { ALL_URLS, isSyncableUrl, remoteVisitRecord, deviceTombstoneKey, changeTime } from "../lib/changes.js";
import { suppressUrls } from "../lib/suppress.js";
import { SyncApi } from "../lib/api.js";
import { HISTORY_EXPIRY_MS } from "../lib/time.js";
import { applyRemoteDelete, applyPurge, applyOwnRemoval } from "./deletes.js";
import { notifyChanged } from "./counts.js";

const PULL_PAGE = 1000;
const STAT_KEYS = ["visits", "deletes", "skipped", "imported"];
const OMNIBOX_SCORED_VISITS = 10;
const OMNIBOX_SIGNIFICANT_VISITS = 4;
const TYPED_TRANSITIONS = ["typed", "keyword_generated"];

async function loadTombstones() {
    const rows = await tx("tombstones", "readonly", (s) => promisify(s.tombstones.getAll()));
    return new Map(rows.map((r) => [r.url, r.deletedAt]));
}

const countsForAutofill = (visit, since) => visit.visitTime > since && visit.transition !== "reload";

function autofillTarget(visits, since) {
    const remote = visits.filter((v) => v.state === "remote" && countsForAutofill(v, since));
    const floor = remote.some((v) => TYPED_TRANSITIONS.includes(v.transition)) ? OMNIBOX_SIGNIFICANT_VISITS : 0;
    return Math.min(OMNIBOX_SCORED_VISITS, Math.max(remote.length, floor));
}

async function importForAutofill(urls, atLeast) {
    const now = Date.now();
    const since = now - HISTORY_EXPIRY_MS;
    const plan = await tx(["visits", "imported"], "readonly", async (s) => {
        const out = [];
        for (const url of urls) {
            const [visits, imports] = await Promise.all([
                promisify(s.visits.index("url").getAll(url)),
                promisify(s.imported.index("url").getAll(url)),
            ]);
            const missing = Math.max(autofillTarget(visits, since) - imports.filter((i) => i.at > since).length, atLeast);
            if (missing > 0) out.push({ url, missing });
        }
        return out;
    });
    for (const { url, missing } of plan) {
        const known = new Set((await chrome.history.getVisits({ url })).map((v) => v.visitId));
        await suppressUrls([url]);
        for (let i = 0; i < missing; i++) await chrome.history.addUrl({ url });
        const added = (await chrome.history.getVisits({ url })).filter((v) => !known.has(v.visitId));
        await tx("imported", "readwrite", (s) => {
            for (const v of added) s.imported.put({ visitId: v.visitId, url, at: now });
        });
    }
    return plan.length;
}

export async function refreshAutofill() {
    const since = Date.now() - HISTORY_EXPIRY_MS;
    const urls = new Set();
    await tx("visits", "readonly", (s) =>
        iterate(s.visits.index("visitTime"), IDBKeyRange.lowerBound(since, true), "next", (cursor) => {
            if (cursor.value.state === "remote") urls.add(cursor.value.url);
        }),
    );
    return importForAutofill([...urls], 0);
}

async function applyPage(rows, device, settings) {
    const since = Date.now() - HISTORY_EXPIRY_MS;
    const tombstones = await loadTombstones();
    const devices = await getMeta("devices", {});
    const toImport = new Set();
    let pending = [];
    const stats = { visits: 0, deletes: 0, skipped: 0 };
    const hiddenBefore = (key, time) => time <= (tombstones.get(key) ?? -Infinity);

    const flush = async () => {
        if (!pending.length) return;
        const batch = pending;
        pending = [];
        await tx("visits", "readwrite", async (s) => {
            const known = await Promise.all(batch.map((v) => promisify(s.visits.getKey(v.id))));
            batch.forEach((v, i) => {
                if (known[i] === undefined && countsForAutofill(v, since)) toImport.add(v.url);
                s.visits.put(v);
            });
        });
    };

    for (const row of rows) {
        const c = row.payload;
        if (!c || c.deviceId === device.deviceId) continue;
        if (c.type === "purge") {
            await flush();
            if (c.targetDeviceId === device.deviceId) {
                await applyOwnRemoval(device.deviceId, c.before);
                continue;
            }
            await applyPurge(c.targetDeviceId, c.before);
            delete devices[c.targetDeviceId];
            tombstones.set(deviceTombstoneKey(c.targetDeviceId), c.before);
            stats.deletes++;
            continue;
        }
        const deviceKey = deviceTombstoneKey(c.deviceId);
        if (c.type === "rejoin") {
            tombstones.delete(deviceKey);
            await tx("tombstones", "readwrite", (s) => s.tombstones.delete(deviceKey));
        }
        const ts = changeTime(c);
        const known = devices[c.deviceId];
        if (!hiddenBefore(deviceKey, ts)) {
            devices[c.deviceId] = {
                name: c.deviceName || known?.name || "Unknown device",
                lastSeen: Math.max(known?.lastSeen || 0, ts || 0),
            };
        }
        if (c.type === "visit") {
            if (!isSyncableUrl(c.url) || [c.url, ALL_URLS, deviceKey].some((key) => hiddenBefore(key, c.visitTime))) {
                stats.skipped++;
                continue;
            }
            pending.push(remoteVisitRecord(c));
            stats.visits++;
        } else if (c.type === "delete") {
            await flush();
            if (await applyRemoteDelete(c, settings)) {
                stats.deletes++;
                const key = c.url ?? ALL_URLS;
                tombstones.set(key, Math.max(tombstones.get(key) || 0, c.deletedAt));
                if (c.url === null) toImport.clear();
                else toImport.delete(c.url);
            }
        }
    }
    await flush();
    await setMeta("devices", devices);
    stats.imported = await importForAutofill([...toImport], 1);
    return stats;
}

async function serverReplaced() {
    await setMeta("cursor", 0);
    await tx("visits", "readwrite", (s) =>
        iterate(s.visits.index("state"), IDBKeyRange.only("uploaded"), "next", (cursor) => {
            cursor.update({ ...cursor.value, state: "indexed" });
        }),
    );
    notifyChanged();
}

export async function pullAll(device, settings) {
    if (!canSync(settings)) return null;
    const api = new SyncApi(settings);
    let cursor = await getMeta("cursor", 0);
    const total = { ...Object.fromEntries(STAT_KEYS.map((k) => [k, 0])), pages: 0 };
    for (; ;) {
        const page = await api.getChanges(cursor, PULL_PAGE);
        const knownServer = await getMeta("serverId");
        const replaced = (page.serverId && knownServer && page.serverId !== knownServer) ||
            (typeof page.lastSeq === "number" && page.lastSeq < cursor);
        if (page.serverId && page.serverId !== knownServer) await setMeta("serverId", page.serverId);
        if (replaced) {
            await serverReplaced();
            cursor = 0;
            total.serverReplaced = true;
            continue;
        }
        const stats = await applyPage(page.changes, device, settings);
        for (const k of STAT_KEYS) total[k] += stats[k];
        total.pages++;
        cursor = page.cursor;
        await setMeta("cursor", cursor);
        if (stats.visits || stats.deletes) notifyChanged();
        if (!page.hasMore) break;
    }
    await setMeta("lastPullAt", Date.now());
    return total;
}
