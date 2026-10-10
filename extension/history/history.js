import { openDB, iterate, promisify, getMeta } from "../lib/db.js";
import { getSettings } from "../lib/settings.js";
import { EVENT, send, onEvents } from "../lib/messages.js";
import { esc, needsConfirm, linkToOptions } from "../ui/dom.js";

const PAGE = 150;
const HAS_GET_ALL_RECORDS = "getAllRecords" in IDBIndex.prototype;
const $ = (id) => document.getElementById(id);
const list = $("list");
const faviconBase = chrome.runtime.getURL("/_favicon/");

let settings;
let deviceNames = {};
let query = { terms: [], device: "" };
let before = Infinity;
let beforeId = null;
let exhausted = false;
let loading = false;
let generation = 0;
let lastDayEl = null;
let lastDay = null;

const parseSearch = (text) => (text || "").toLowerCase().split(/\s+/).filter(Boolean);
const searchText = (v) => `${v.title}\n${v.url}`.toLowerCase();
const matchesTerms = (hay, terms) => terms.every((t) => hay.includes(t));

function dayStart(t) {
    const d = new Date(t);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
}

async function visitTimeIndex() {
    const db = await openDB();
    return db.transaction("visits", "readonly").objectStore("visits").index("visitTime");
}

function highlight(text, terms) {
    let html = esc(text);
    for (const t of terms) {
        const re = new RegExp(esc(t).replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "gi");
        html = html.replace(re, (m) => `<mark>${m}</mark>`);
    }
    return html;
}

function dayLabel(day) {
    const today = dayStart(Date.now());
    const date = new Date(day).toLocaleDateString(undefined, { weekday: "long", year: "numeric", month: "long", day: "numeric" });
    const offset = day === today ? 0 : day === dayStart(today - 1) ? -1 : null;
    if (offset === null) return date;
    const rel = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" }).format(offset, "day");
    return `${rel[0].toUpperCase()}${rel.slice(1)} – ${date}`;
}

function domainOf(url) {
    try {
        return new URL(url).hostname.replace(/^www\./, "");
    } catch {
        return "";
    }
}

function deviceLabel(v) {
    if (v.deviceId === settings.deviceId) return { text: "This device", remote: false };
    return { text: deviceNames[v.deviceId]?.name || v.deviceName || "Other device", remote: true };
}

function renderVisit(v) {
    const row = document.createElement("div");
    row.className = "visit";
    row.dataset.url = v.url;
    row.dataset.visitTime = String(v.visitTime);
    row.dataset.deviceId = v.deviceId;
    const dev = deviceLabel(v);
    const time = new Date(v.visitTime).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    const fav = `${faviconBase}?pageUrl=${encodeURIComponent(v.url)}&size=32`;
    row.innerHTML = `
    <time datetime="${new Date(v.visitTime).toISOString()}" title="${esc(new Date(v.visitTime).toLocaleString())}">${time}</time>
    <img src="${fav}" alt="" loading="lazy">
    <div class="main"><a href="${esc(v.url)}" title="${esc(v.url)}">${highlight(v.title || v.url, query.terms)}</a>
      <span class="domain">${highlight(domainOf(v.url), query.terms)}</span></div>
    <span class="badge${dev.remote ? " remote" : ""}" title="${esc(dev.text)}">${esc(dev.text)}</span>
    <button class="del" title="Remove every visit to this page from history on all devices">Remove</button>`;
    return row;
}

function appendVisits(visits) {
    const frag = document.createDocumentFragment();
    for (const v of visits) {
        const day = dayStart(v.visitTime);
        if (day !== lastDay) {
            lastDay = day;
            lastDayEl = document.createElement("section");
            lastDayEl.className = "day";
            lastDayEl.innerHTML = `<h2>${esc(dayLabel(day))}</h2>`;
            frag.appendChild(lastDayEl);
        }
        lastDayEl.appendChild(renderVisit(v));
    }
    list.appendChild(frag);
}

const SEARCH_INDEX_MAX = 300_000;
let searchIndexPromise = null;
let pageItems = null;
let pagePos = 0;

function loadSearchIndex() {
    if (!searchIndexPromise) {
        searchIndexPromise = (async () => {
            if (!HAS_GET_ALL_RECORDS) return null;
            const index = await visitTimeIndex();
            const records = await promisify(index.getAllRecords({ count: SEARCH_INDEX_MAX + 1, direction: "prev" }));
            if (records.length > SEARCH_INDEX_MAX) return null;
            return records.map(({ value: v }) => ({ v, hay: searchText(v) }));
        })().catch(() => null);
    }
    return searchIndexPromise;
}

const deviceMatches = (v) =>
    query.device
        ? query.device === "self" ? v.deviceId === settings.deviceId : v.deviceId === query.device
        : !settings.hiddenDevices.includes(v.deviceId);

const matches = (v) => deviceMatches(v) && matchesTerms(searchText(v), query.terms);

const isFiltered = () => Boolean(query.terms.length || query.device || settings.hiddenDevices.length);

const seen = (v, upper, upperId) => v.visitTime === upper && upperId !== null && v.id >= upperId;

async function fetchPageWithCursor(index, range) {
    const out = [];
    await iterate(index, range, "prev", (c) => {
        if (!seen(c.value, before, beforeId) && matches(c.value)) out.push(c.value);
        return out.length < PAGE;
    });
    return { visits: out, reachedEnd: out.length < PAGE };
}

async function fetchPage() {
    if (isFiltered()) {
        if (!pageItems) pageItems = await loadSearchIndex();
        if (pageItems) {
            const out = [];
            let i = pagePos;
            for (; i < pageItems.length && out.length < PAGE; i++) {
                const { v, hay } = pageItems[i];
                if (deviceMatches(v) && matchesTerms(hay, query.terms)) out.push(v);
            }
            pagePos = i;
            return { visits: out, reachedEnd: i >= pageItems.length };
        }
    }
    const rangeBelow = (upper) => (upper === Infinity ? null : IDBKeyRange.upperBound(upper));
    if (!HAS_GET_ALL_RECORDS) return fetchPageWithCursor(await visitTimeIndex(), rangeBelow(before));

    const count = isFiltered() ? 5000 : PAGE + 20;
    const out = [];
    let upper = before;
    let upperId = beforeId;
    for (; ;) {
        const records = await promisify((await visitTimeIndex()).getAllRecords({ query: rangeBelow(upper), count, direction: "prev" }));
        let progressed = false;
        for (const { value: v } of records) {
            if (seen(v, upper, upperId)) continue;
            progressed = true;
            if (matches(v)) {
                out.push(v);
                if (out.length >= PAGE) return { visits: out, reachedEnd: false };
            }
        }
        if (records.length < count || !progressed) return { visits: out, reachedEnd: true };
        const last = records[records.length - 1].value;
        upper = last.visitTime;
        upperId = last.id;
    }
}

async function loadMore() {
    if (loading || exhausted) return;
    loading = true;
    const gen = generation;
    try {
        const { visits, reachedEnd } = await fetchPage();
        if (gen !== generation) return;
        appendVisits(visits);
        if (visits.length) {
            const last = visits[visits.length - 1];
            before = last.visitTime;
            beforeId = last.id;
        }
        exhausted = reachedEnd;
        const empty = !list.children.length;
        $("empty").classList.toggle("hidden", !empty);
        if (empty) {
            $("empty").textContent = query.terms.length || query.device ? "No matching visits." : "No history yet.";
        }
    } finally {
        if (gen === generation) loading = false;
    }
    if (!exhausted && $("sentinel").getBoundingClientRect().top < innerHeight + 400) loadMore();
}

function reset() {
    generation++;
    pageItems = null;
    pagePos = 0;
    loading = false;
    before = Infinity;
    beforeId = null;
    exhausted = false;
    lastDay = null;
    lastDayEl = null;
    list.innerHTML = "";
    return loadMore();
}

async function loadDevices() {
    const s = await send("status").catch(() => null);
    if (!s) return;
    deviceNames = { ...deviceNames, ...Object.fromEntries(s.devices.map((d) => [d.id, d])) };
    const sel = $("device-filter");
    const current = sel.value;
    sel.innerHTML = `<option value="">All devices</option><option value="self">This device (${esc(s.deviceName)})</option>` +
        s.devices.map((d) => `<option value="${esc(d.id)}">${esc(d.name)}${d.hidden ? " (hidden)" : ""}</option>`).join("");
    sel.value = [...sel.options].some((o) => o.value === current) ? current : "";
    const n = s.devices.length;
    $("sync-state").textContent = !s.configured
        ? "Sync not set up"
        : s.lastError
            ? "Sync failed"
            : `Synced with ${n} other device${n === 1 ? "" : "s"}`;
}

let searchTimer;
$("search").addEventListener("keydown", () => loadSearchIndex());
$("search").addEventListener("input", () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => {
        query.terms = parseSearch($("search").value);
        reset();
    }, 200);
});

$("device-filter").addEventListener("change", () => {
    loadSearchIndex();
    query.device = $("device-filter").value;
    reset();
});

list.addEventListener("click", async (e) => {
    const btn = e.target.closest(".del");
    if (!btn) return;
    if (needsConfirm(btn, "Remove everywhere?")) return;
    const url = btn.closest(".visit").dataset.url;
    btn.disabled = true;
    try {
        await send("deleteUrl", { url });
    } catch {
        btn.disabled = false;
        btn.textContent = "Failed";
        return;
    }
    searchIndexPromise = null;
    for (const r of list.querySelectorAll(".visit")) {
        if (r.dataset.url === url) r.remove();
    }
    for (const d of list.querySelectorAll(".day")) if (!d.querySelector(".visit")) d.remove();
});

linkToOptions($("open-settings"));
$("clear-data").addEventListener("click", (e) => {
    e.preventDefault();
    chrome.tabs.create({ url: "chrome://settings/clearBrowserData" });
});

new IntersectionObserver((entries) => {
    if (entries.some((en) => en.isIntersecting)) loadMore();
}, { rootMargin: "400px" }).observe($("sentinel"));

let refreshTimer;
onEvents([EVENT.visitsChanged], () => {
    searchIndexPromise = null;
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(() => {
        loadDevices();
        if (scrollY < 200) reset();
    }, 400);
});

chrome.storage.onChanged.addListener(async (changes, area) => {
    if (area !== "local" || !changes.hiddenDevices) return;
    settings = await getSettings();
    loadDevices();
    reset();
});

document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && scrollY < 200) reset();
});

settings = await getSettings();
deviceNames = await getMeta("devices", {});
await reset();
loadDevices();
