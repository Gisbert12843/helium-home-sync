import { tx, promisify, getMeta, setMeta, getAll } from "../lib/db.js";
import { isSyncableUrl, makeLocalVisit, visitToChange } from "../lib/changes.js";
import { canSync } from "../lib/settings.js";
import { SyncApi } from "../lib/api.js";
import { MINUTE_MS, DAY_MS } from "../lib/time.js";
import { notifyChanged } from "./counts.js";

const UPLOAD_BATCH = 500;
const OVERLAP_MS = 2 * MINUTE_MS;
const INDEX_WINDOW_MS = 7 * DAY_MS;
const SEARCH_MAX = 20_000;

const searchHistory = (startTime, endTime, maxResults) => chrome.history.search({ text: "", startTime, endTime, maxResults });

async function searchRange(start, end) {
    const items = await searchHistory(start, end, SEARCH_MAX);
    if (items.length < SEARCH_MAX || end - start < MINUTE_MS) return items;
    const mid = Math.floor((start + end) / 2);
    const seen = new Set();
    const merged = [];
    for (const it of [...(await searchRange(start, mid)), ...(await searchRange(mid, end))]) {
        if (!seen.has(it.url)) seen.add(it.url), merged.push(it);
    }
    return merged;
}

async function scanRange(device, start, end, state) {
    const items = (await searchRange(start, end)).filter((i) => isSyncableUrl(i.url));
    const candidates = [];
    for (const item of items) {
        const visits = await chrome.history.getVisits({ url: item.url });
        for (const v of visits) {
            if (v.visitTime >= start && v.visitTime < end) candidates.push({ visitId: v.visitId, visit: makeLocalVisit(device, item, v, state) });
        }
    }
    if (!candidates.length) return 0;

    const fresh = await tx(["imported", "visits"], "readonly", async (s) => {
        const out = [];
        for (const { visitId, visit } of candidates) {
            const [imported, known] = await Promise.all([
                promisify(s.imported.get(visitId)),
                promisify(s.visits.getKey(visit.id)),
            ]);
            if (!imported && known === undefined) out.push(visit);
        }
        return out;
    });
    if (!fresh.length) return 0;

    const changes = state === "queued" ? await Promise.all(fresh.map(visitToChange)) : [];
    await tx(["visits", "outbox"], "readwrite", (s) => {
        for (const v of fresh) s.visits.put(v);
        for (const c of changes) s.outbox.put(c);
    });
    return fresh.length;
}

export async function scanRecent(device) {
    const now = Date.now();
    const watermark = await getMeta("watermark");
    if (watermark == null) {
        await setMeta("watermark", now);
        return;
    }
    const floor = await getMeta("installedAt", 0);
    const added = await scanRange(device, Math.max(watermark - OVERLAP_MS, floor), now + 1, "queued");
    await setMeta("watermark", now);
    if (added) notifyChanged();
}

export async function indexExisting(device, { maxWindows = Infinity } = {}) {
    let state = await getMeta("localIndex");
    if (!state || state.done) return;
    for (let i = 0; i < maxWindows; i++) {
        const probe = await searchHistory(0, state.before, 1);
        if (!probe.length) {
            await setMeta("localIndex", { ...state, done: true });
            notifyChanged();
            return;
        }
        const end = Math.min(state.before, Math.ceil(probe[0].lastVisitTime) + 1);
        const start = Math.max(0, end - INDEX_WINDOW_MS);
        await scanRange(device, start, end, "indexed");
        state = { ...state, before: start, oldest: start };
        await setMeta("localIndex", state);
        notifyChanged();
        if (start === 0) {
            await setMeta("localIndex", { ...state, done: true });
            return;
        }
    }
}

export async function queueIndexed() {
    for (; ;) {
        const batch = await getAll("visits", IDBKeyRange.only("indexed"), UPLOAD_BATCH, "state");
        if (!batch.length) return;
        const changes = await Promise.all(batch.map(visitToChange));
        await tx(["visits", "outbox"], "readwrite", (s) => {
            for (const v of batch) s.visits.put({ ...v, state: "queued" });
            for (const c of changes) s.outbox.put(c);
        });
    }
}

export async function flushOutbox(settings) {
    if (!canSync(settings)) return 0;
    const api = new SyncApi(settings);
    const named = (c) => ({ ...c, deviceName: settings.deviceName || c.deviceName });
    let sent = 0;
    const rejoin = await getMeta("pendingRejoin");
    if (rejoin) {
        await api.postChanges([named(rejoin)]);
        await setMeta("pendingRejoin", null);
        sent++;
    }
    for (; ;) {
        const batch = await getAll("outbox", undefined, UPLOAD_BATCH);
        if (!batch.length) break;
        await api.postChanges(batch.map(named));
        await tx(["outbox", "visits"], "readwrite", async (s) => {
            for (const c of batch) {
                s.outbox.delete(c.id);
                if (c.type !== "visit") continue;
                const v = await promisify(s.visits.get(c.id));
                if (v && v.state === "queued") s.visits.put({ ...v, state: "uploaded" });
            }
        });
        sent += batch.length;
    }
    return sent;
}
