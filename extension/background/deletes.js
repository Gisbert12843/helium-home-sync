import { tx, promisify, iterate, getMeta, setMeta } from "../lib/db.js";
import { ALL_URLS, isSyncableUrl, makeDeleteChange, deviceTombstoneKey } from "../lib/changes.js";
import { suppressUrls, suppressAll } from "../lib/suppress.js";
import { DAY_MS, HISTORY_EXPIRY_MS } from "../lib/time.js";
import { notifyChanged } from "./counts.js";

const EXPIRY_GUARD_MS = HISTORY_EXPIRY_MS - 5 * DAY_MS;

async function purgeVisits(s, url, until) {
    const source = url === null ? s.visits.index("visitTime") : s.visits.index("url");
    const range = url === null ? IDBKeyRange.upperBound(until) : IDBKeyRange.only(url);
    await iterate(source, range, "next", (cursor) => {
        if (cursor.value.visitTime <= until) cursor.delete();
    });
}

async function putTombstone(s, url, deletedAt) {
    const prev = await promisify(s.tombstones.get(url));
    if (!prev || prev.deletedAt < deletedAt) s.tombstones.put({ url, deletedAt });
}

const forgetImports = (s, url) => iterate(s.imported.index("url"), IDBKeyRange.only(url), "next", (c) => void c.delete());

async function deleteNative(url) {
    await suppressUrls([url]);
    await chrome.history.deleteUrl({ url });
}

async function newestKnown(url) {
    return tx(["visits", "imported"], "readonly", async (s) => {
        const [visits, imported] = await Promise.all([
            promisify(s.visits.index("url").getAll(url)),
            promisify(s.imported.index("url").getAll(url)),
        ]);
        const times = [...visits.map((v) => v.visitTime), ...imported.map((i) => i.at)];
        return times.length ? Math.max(...times) : null;
    });
}

async function looksLikeExpiry(url, now) {
    const newest = await newestKnown(url);
    return newest != null && newest < now - EXPIRY_GUARD_MS;
}

async function recordUserDelete(device, url, now = Date.now()) {
    const change = await makeDeleteChange(device, url, now);
    await tx(["visits", "imported", "tombstones", "outbox"], "readwrite", async (s) => {
        await putTombstone(s, url, now);
        await purgeVisits(s, url, now);
        await forgetImports(s, url);
        s.outbox.put(change);
    });
}

export async function handleVisitRemoved(device, settings, { allHistory, urls }) {
    const now = Date.now();
    if (allHistory) {
        const change = settings.propagateClearAll ? await makeDeleteChange(device, null, now) : null;
        await tx(["visits", "imported", "tombstones", "outbox"], "readwrite", async (s) => {
            s.visits.clear();
            s.imported.clear();
            await putTombstone(s, ALL_URLS, now);
            const pending = await promisify(s.outbox.getAll());
            for (const c of pending) if (c.type === "visit") s.outbox.delete(c.id);
            if (change) s.outbox.put(change);
        });
        notifyChanged();
        return;
    }
    let propagated = 0;
    for (const url of urls) {
        if (!isSyncableUrl(url) || (await looksLikeExpiry(url, now))) continue;
        await recordUserDelete(device, url, now);
        propagated++;
    }
    if (propagated) notifyChanged();
}

export async function deleteUrlEverywhere(device, url) {
    await deleteNative(url);
    await recordUserDelete(device, url);
    notifyChanged();
}

export async function applyRemoteDelete(change, settings) {
    const { url, deletedAt } = change;
    if (url === null) {
        if (!settings.acceptDeleteAll) return false;
        await tx(["visits", "tombstones"], "readwrite", async (s) => {
            await putTombstone(s, ALL_URLS, deletedAt);
            await purgeVisits(s, null, deletedAt);
        });
        await suppressAll();
        await chrome.history.deleteRange({ startTime: 0, endTime: deletedAt });
        return true;
    }
    await tx(["visits", "tombstones"], "readwrite", async (s) => {
        await putTombstone(s, url, deletedAt);
        await purgeVisits(s, url, deletedAt);
    });
    const native = await chrome.history.getVisits({ url });
    const newer = native.filter((v) => v.visitTime > deletedAt);
    const ownNewer = await tx("imported", "readonly", async (s) => {
        for (const v of newer) if (!(await promisify(s.imported.get(v.visitId)))) return true;
        return false;
    });
    if (native.length && !ownNewer) {
        await deleteNative(url);
        await tx("imported", "readwrite", (s) => forgetImports(s, url));
    }
    return true;
}

export async function applyOwnRemoval(deviceId, before) {
    if (before <= (await getMeta("rejoinedAt", 0))) return;
    await tx(["visits", "outbox"], "readwrite", (s) =>
        iterate(s.visits.index("deviceId"), IDBKeyRange.only(deviceId), "next", (cursor) => {
            const v = cursor.value;
            if (v.visitTime > before || (v.state !== "uploaded" && v.state !== "queued")) return;
            if (v.state === "queued") s.outbox.delete(v.id);
            cursor.update({ ...v, state: "indexed" });
        }),
    );
    await setMeta("removedBefore", Math.max(await getMeta("removedBefore", 0), before));
    notifyChanged();
}

export async function applyPurge(targetDeviceId, before) {
    const urls = new Set();
    await tx(["visits", "tombstones"], "readwrite", async (s) => {
        await putTombstone(s, deviceTombstoneKey(targetDeviceId), before);
        await iterate(s.visits.index("deviceId"), IDBKeyRange.only(targetDeviceId), "next", (cursor) => {
            if (cursor.value.visitTime <= before) {
                urls.add(cursor.value.url);
                cursor.delete();
            }
        });
    });
    for (const url of urls) {
        const remaining = await tx("visits", "readonly", (s) => promisify(s.visits.index("url").count(url)));
        if (remaining) continue;
        const native = await chrome.history.getVisits({ url });
        const imported = await tx("imported", "readonly", (s) => promisify(s.imported.index("url").getAll(url)));
        const importedIds = new Set(imported.map((i) => i.visitId));
        if (native.length && native.every((v) => importedIds.has(v.visitId))) await deleteNative(url);
        if (imported.length) {
            await tx("imported", "readwrite", (s) => {
                for (const i of imported) s.imported.delete(i.visitId);
            });
        }
    }
    const devices = await getMeta("devices", {});
    if (devices[targetDeviceId]) {
        delete devices[targetDeviceId];
        await setMeta("devices", devices);
    }
    notifyChanged();
}
