import { getMeta, setMeta, count, put } from "../lib/db.js";
import { ensureDevice, getSettings, isConfigured, canSync, normalizeServerUrl, originPattern } from "../lib/settings.js";
import { isSyncableUrl, makePurgeChange, makeRejoinChange } from "../lib/changes.js";
import { isSuppressed, isAllSuppressed, pruneSuppress } from "../lib/suppress.js";
import { SyncApi } from "../lib/api.js";
import { SECOND_MS, MINUTE_MS } from "../lib/time.js";
import { scanRecent, indexExisting, queueIndexed, flushOutbox } from "./upload.js";
import { pullAll } from "./download.js";
import { handleVisitRemoved, deleteUrlEverywhere, applyPurge } from "./deletes.js";
import { scheduleRecount, loadCounts, resumeRecount } from "./counts.js";

const APP_NAME = chrome.runtime.getManifest().name;
const SCAN_DELAY_MS = 30 * SECOND_MS;
const STATUS_META = [
    "lastSyncAt", "lastError", "lastPullAt", "devices", "localIndex", "backfillRequested", "cursor", "countsDirty", "removedBefore",
];

let chain = Promise.resolve();
let busy = null;
function run(name, fn) {
    const job = chain.then(async () => {
        busy = name;
        try {
            return await fn();
        } finally {
            busy = null;
        }
    });
    chain = job.catch(() => { });
    return job;
}

async function ensureInit() {
    if (await getMeta("installedAt")) return;
    const now = Date.now();
    await setMeta("installedAt", now);
    await setMeta("watermark", now);
    await setMeta("localIndex", { done: false, before: now });
}

const backoffDelay = (failures) => Math.min(30 * SECOND_MS * 2 ** (failures - 1), 15 * MINUTE_MS);

async function clearFailures() {
    await setMeta("failures", 0);
    await setMeta("nextRetryAt", 0);
    await setMeta("lastError", null);
}

async function recordSuccess() {
    await clearFailures();
    await setMeta("lastSyncAt", Date.now());
    await updateBadge();
}

async function recordFailure(e) {
    const failures = (await getMeta("failures", 0)) + 1;
    await setMeta("failures", failures);
    await setMeta("nextRetryAt", Date.now() + backoffDelay(failures));
    await setMeta("lastError", { message: e?.message || String(e), at: Date.now() });
    console.warn("sync failed:", e);
    await updateBadge();
}

function sync({ pull = true, force = false, reason = "" } = {}) {
    return run(`sync:${reason}`, async () => {
        await ensureInit();
        const device = await ensureDevice();
        const settings = await getSettings();
        await scanRecent(device);
        if (!canSync(settings)) return { ok: false, skipped: true };
        if (!force && Date.now() < (await getMeta("nextRetryAt", 0))) return { ok: false, backoff: true };
        try {
            const sent = await flushOutbox(settings);
            if (sent) scheduleRecount();
            const pulled = pull ? await pullAll(device, settings) : null;
            await recordSuccess();
            return { ok: true, sent, pulled };
        } catch (e) {
            await recordFailure(e);
            return { ok: false, error: e.message };
        }
    });
}

async function backfill() {
    await run("backfill", async () => {
        await queueIndexed();
        if ((await getMeta("localIndex"))?.done !== false) await setMeta("backfillRequested", false);
    });
    scheduleRecount();
}

async function tick() {
    await run("init", ensureInit);
    const settings = await getSettings();
    const device = await ensureDevice();
    await run("index", () => indexExisting(device, { maxWindows: 4 }));
    if (await getMeta("backfillRequested")) await backfill();
    const interval = settings.pullIntervalMin * MINUTE_MS;
    const pull = interval > 0 && Date.now() - (await getMeta("lastPullAt", 0)) >= interval;
    const outbox = await count("outbox");
    if (pull || outbox > 0 || !(await getMeta("watermark"))) await sync({ pull, reason: "tick" });
    else await run("scan", async () => scanRecent(device));
    await pruneSuppress();
}

async function updateBadge() {
    const settings = await getSettings();
    const lastError = await getMeta("lastError");
    let text = "";
    let color = "#d93025";
    if (isConfigured(settings) && settings.paused) [text, color] = ["II", "#80868b"];
    else if (isConfigured(settings) && lastError) text = "!";
    await chrome.action.setBadgeText({ text });
    await chrome.action.setBadgeBackgroundColor({ color });
    await chrome.action.setTitle({
        title: text === "!" ? `${APP_NAME}: ${lastError.message}` : text ? `${APP_NAME}: paused` : APP_NAME,
    });
}

async function status() {
    const settings = await getSettings();
    const [outbox, values] = await Promise.all([count("outbox"), Promise.all(STATUS_META.map((k) => getMeta(k)))]);
    const meta = Object.fromEntries(STATUS_META.map((k, i) => [k, values[i]]));
    const counts = await loadCounts();
    const { indexed, queued, uploaded, remote } = counts;
    const deviceList = Object.entries(meta.devices || {}).map(([id, d]) => ({
        id,
        name: d.name,
        lastSeen: d.lastSeen,
        visits: counts.perDevice[id] || 0,
        hidden: settings.hiddenDevices.includes(id),
    }));
    let hostPermission = null;
    if (settings.serverUrl) {
        try {
            hostPermission = await chrome.permissions.contains({ origins: [originPattern(settings.serverUrl)] });
        } catch { }
    }
    const { localIndex } = meta;
    return {
        configured: isConfigured(settings),
        paused: settings.paused,
        deviceId: settings.deviceId,
        deviceName: settings.deviceName,
        busy,
        lastSyncAt: meta.lastSyncAt,
        lastPullAt: meta.lastPullAt,
        lastError: meta.lastError,
        cursor: meta.cursor || 0,
        outbox,
        local: { indexed, queued, uploaded, total: indexed + queued + uploaded },
        remote,
        devices: deviceList.filter((d) => d.visits > 0).sort((a, b) => b.lastSeen - a.lastSeen),
        indexing: localIndex && !localIndex.done ? { oldest: localIndex.oldest || null } : null,
        backfill: meta.backfillRequested ? { remaining: indexed, queued: outbox } : null,
        removed: Boolean(meta.removedBefore),
        hostPermission,
        countsAt: counts.at,
        countsFresh: !meta.countsDirty,
    };
}

async function testConnection(serverUrl, token) {
    const url = normalizeServerUrl(serverUrl);
    if (!url) throw new Error("Enter a server URL");
    const api = new SyncApi({ serverUrl: url, token });
    const health = await api.health();
    if (!health?.ok) throw new Error("Unexpected health response");
    if (!token) return { ok: true, version: health.version, tokenChecked: false };
    const stats = await api.stats();
    return { ok: true, version: health.version, tokenChecked: true, stats };
}

async function setupAlarms() {
    if (!(await chrome.alarms.get("tick"))) await chrome.alarms.create("tick", { periodInMinutes: 1 });
}

chrome.runtime.onInstalled.addListener(async ({ reason }) => {
    await ensureDevice();
    await setupAlarms();
    await run("init", ensureInit);
    await updateBadge();
    await sync({ reason: reason || "installed", force: true });
    await run("index", async () => indexExisting(await ensureDevice()));
});

chrome.runtime.onStartup.addListener(async () => {
    await setupAlarms();
    await updateBadge();
    await sync({ reason: "startup", force: true });
});

chrome.alarms.onAlarm.addListener(async (alarm) => {
    if (alarm.name === "tick") await tick();
    else if (alarm.name === "scan") await sync({ pull: false, reason: "visit" });
});

chrome.history.onVisited.addListener(async (item) => {
    if (!isSyncableUrl(item.url) || (await isSuppressed(item.url))) return;
    if (!(await chrome.alarms.get("scan"))) await chrome.alarms.create("scan", { when: Date.now() + SCAN_DELAY_MS });
});

chrome.history.onVisitRemoved.addListener(async (removed) => {
    if (await isAllSuppressed()) return;
    const urls = [];
    for (const url of removed.urls || []) if (!(await isSuppressed(url))) urls.push(url);
    if (!removed.allHistory && !urls.length) return;
    await run("delete", async () => {
        const device = await ensureDevice();
        await handleVisitRemoved(device, await getSettings(), { allHistory: removed.allHistory, urls });
    });
    await sync({ pull: false, reason: "delete" });
});

chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== "local") return;
    if (changes.paused || changes.serverUrl || changes.token) updateBadge();
});

const handlers = {
    status: () => status(),
    syncNow: () => sync({ force: true, reason: "manual" }),
    test: (msg) => testConnection(msg.serverUrl, msg.token),
    backfill: async () => {
        const device = await ensureDevice();
        await run("rejoin", async () => {
            if (!(await getMeta("removedBefore"))) return;
            const rejoin = makeRejoinChange(device, Date.now());
            await setMeta("pendingRejoin", rejoin);
            await setMeta("rejoinedAt", rejoin.at);
            await setMeta("removedBefore", null);
        });
        await setMeta("backfillRequested", true);
        await run("index", () => indexExisting(device));
        await backfill();
        return sync({ pull: false, force: true, reason: "backfill" });
    },
    deleteUrl: async (msg) => {
        const device = await ensureDevice();
        await run("delete", () => deleteUrlEverywhere(device, msg.url));
        sync({ pull: false, reason: "delete" });
        return { ok: true };
    },
    purgeDevice: async (msg) => {
        const device = await ensureDevice();
        if (!msg.deviceId || msg.deviceId === device.deviceId) throw new Error("A device can't remove itself");
        const before = Date.now();
        await run("purge", async () => {
            await put("outbox", makePurgeChange(device, msg.deviceId, before));
            await applyPurge(msg.deviceId, before);
        });
        const { hiddenDevices } = await getSettings();
        await chrome.storage.local.set({ hiddenDevices: hiddenDevices.filter((id) => id !== msg.deviceId) });
        sync({ pull: false, reason: "purge" });
        return { ok: true };
    },
    settingsChanged: async () => {
        await clearFailures();
        await updateBadge();
        return sync({ force: true, reason: "settings" });
    },
};

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    const handler = msg && handlers[msg.cmd];
    if (!handler) return false;
    Promise.resolve(handler(msg)).then(
        (result) => sendResponse({ ok: true, result }),
        (e) => sendResponse({ ok: false, error: e?.message || String(e) }),
    );
    return true;
});

setupAlarms();
resumeRecount();
