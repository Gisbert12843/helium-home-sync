import { getMeta, setMeta, count } from "../lib/db.js";
import { getSettings } from "../lib/settings.js";
import { EVENT, broadcast } from "../lib/messages.js";

const STATES = ["indexed", "queued", "uploaded", "remote"];

let recountTimer = null;
let recounting = null;

async function recount() {
    const settings = await getSettings();
    const ids = [...new Set([settings.deviceId, ...Object.keys(await getMeta("devices", {}))])];
    const values = await Promise.all([
        ...STATES.map((st) => count("visits", IDBKeyRange.only(st), "state")),
        ...ids.map((id) => count("visits", IDBKeyRange.only(id), "deviceId")),
    ]);
    const counts = Object.fromEntries(STATES.map((st, i) => [st, values[i]]));
    counts.perDevice = Object.fromEntries(ids.map((id, i) => [id, values[STATES.length + i]]));
    counts.at = Date.now();
    await setMeta("counts", counts);
    await setMeta("countsDirty", false);
    broadcast(EVENT.countsChanged);
    return counts;
}

export function scheduleRecount(delay = 400) {
    setMeta("countsDirty", true);
    clearTimeout(recountTimer);
    recountTimer = setTimeout(() => {
        recounting = recount().finally(() => (recounting = null));
    }, delay);
}

export async function loadCounts() {
    return (await getMeta("counts")) || recounting || recount();
}

export async function resumeRecount() {
    if (await getMeta("countsDirty")) scheduleRecount(0);
}

export function notifyChanged() {
    broadcast(EVENT.visitsChanged);
    scheduleRecount();
}
