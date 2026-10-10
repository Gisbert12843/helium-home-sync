import { getSettings, normalizeServerUrl, isInsecure, originPattern } from "../lib/settings.js";
import { EVENT, send, onEvents } from "../lib/messages.js";
import { SECOND_MS, MINUTE_MS, HOUR_MS, DAY_MS } from "../lib/time.js";
import { esc, needsConfirm, linkToOptions } from "./dom.js";

const APP_NAME = chrome.runtime.getManifest().name;
const TEMPLATE_URL = chrome.runtime.getURL("ui/settings-panel.html");

function ago(t) {
    if (!t) return "never";
    const ms = Date.now() - t;
    if (ms < 45 * SECOND_MS) return "just now";
    if (ms < HOUR_MS) return `${Math.round(ms / MINUTE_MS)} min ago`;
    if (ms < DAY_MS) return `${Math.round(ms / HOUR_MS)} h ago`;
    return new Date(t).toLocaleDateString();
}

const fmt = (n) => (n ?? 0).toLocaleString();

export async function mountPanel(root, { compact = true } = {}) {
    root.innerHTML = await (await fetch(TEMPLATE_URL)).text();
    root.querySelector(".hs-name").textContent = APP_NAME;
    const $ = (id) => root.querySelector(`#${id}`);
    if (!compact) $("open-options").classList.add("hidden");

    const setResult = (text, kind = "") => {
        $("form-result").textContent = text;
        $("form-result").className = `form-result ${kind}`;
    };

    const syncHttpWarning = () => $("http-warning").classList.toggle("hidden", !isInsecure($("server-url").value.trim()));

    async function whileRefreshing(task) {
        const timer = setInterval(refresh, 500);
        try {
            return await task;
        } finally {
            clearInterval(timer);
            refresh();
        }
    }

    async function loadForm() {
        const s = await getSettings();
        $("server-url").value = s.serverUrl;
        $("token").value = s.token;
        $("device-name").value = s.deviceName;
        $("pull-interval").value = String(s.pullIntervalMin);
        $("propagate-clear-all").checked = s.propagateClearAll;
        $("accept-delete-all").checked = s.acceptDeleteAll;
        $("paused").checked = s.paused;
        $("settings").open = !s.serverUrl || !s.token || !compact;
        syncHttpWarning();
    }

    let refreshSeq = 0;
    async function refresh() {
        const seq = ++refreshSeq;
        let st;
        let s;
        try {
            [st, s] = await Promise.all([send("status"), getSettings()]);
        } catch (e) {
            if (seq === refreshSeq) $("status-text").textContent = e.message;
            return;
        }
        if (seq !== refreshSeq) return;
        const dot = $("status-dot");
        let text;
        let state;
        if (!st.configured) [state, text] = ["off", "Not configured"];
        else if (st.paused) [state, text] = ["off", "Paused"];
        else if (st.busy) [state, text] = ["busy", "Syncing…"];
        else if (st.lastError) [state, text] = ["err", `Failed ${ago(st.lastError.at)}`];
        else[state, text] = ["ok", st.lastSyncAt ? `Synced ${ago(st.lastSyncAt)}` : "Waiting for first sync"];
        dot.className = `dot ${state}`;
        $("status-text").textContent = text;
        $("status-http").classList.toggle("hidden", !(st.configured && isInsecure(s.serverUrl)));

        const err = $("error-box");
        err.classList.toggle("hidden", !(st.lastError && st.configured));
        if (st.lastError) err.textContent = st.lastError.message;

        $("stat-local").textContent = fmt(st.local.total);
        $("stat-remote").textContent = fmt(st.remote);
        $("stat-outbox").textContent = fmt(st.outbox);
        renderDevices(st.devices);
        $("device-label").textContent = `This device: ${st.deviceName}`;

        let backfillText = null;
        let backfillReady = false;
        if (st.backfill) backfillText = `Uploading existing history… ${fmt(st.outbox)} left`;
        else if (st.indexing) {
            backfillText = `Reading existing history${st.indexing.oldest ? ` (back to ${new Date(st.indexing.oldest).toLocaleDateString()})` : ""}…`;
        } else if (st.local.indexed > 0) {
            backfillText = st.removed
                ? `This device was removed from sync. ${fmt(st.local.indexed)} of its visits are only on this device.`
                : `${fmt(st.local.indexed)} visits from this device are not on the server yet.`;
            $("btn-backfill").textContent = st.removed ? "Add back to sync" : "Upload existing history";
            backfillReady = st.configured;
        }
        $("backfill").classList.toggle("hidden", backfillText === null);
        $("backfill-text").textContent = backfillText ?? "";
        $("btn-backfill").disabled = !backfillReady;
        $("btn-sync").disabled = !st.configured || st.paused || Boolean(st.busy);
    }

    const openDevices = new Set();
    let devicesSignature = "";
    function renderDevices(devices) {
        const signature = JSON.stringify(devices.map((d) => [d.id, d.name, d.visits, d.hidden, ago(d.lastSeen)]));
        if (signature === devicesSignature) return;
        devicesSignature = signature;
        $("devices").innerHTML = devices
            .map((d) => `
        <li><details data-id="${esc(d.id)}"${openDevices.has(d.id) ? " open" : ""}>
          <summary><span class="dev-name">${esc(d.name)}</span>${d.hidden ? '<span class="dev-hidden">hidden</span>' : ""}
            <span class="muted">${fmt(d.visits)} visits · ${ago(d.lastSeen)}</span></summary>
          <div class="dev-actions">
            <button type="button" data-action="hide">${d.hidden ? "Show in history" : "Hide in history"}</button>
            <button type="button" data-action="purge" class="danger">Remove from sync</button>
          </div>
          <p class="dev-help muted">“Hide” only affects the history page on this device.
            “Remove from sync” deletes this device's ${fmt(d.visits)} visits from the server and all other devices;
            the device itself keeps its own history.</p>
        </details></li>`)
            .join("");
    }

    $("devices").addEventListener("toggle", (e) => {
        const id = e.target.dataset?.id;
        if (id) e.target.open ? openDevices.add(id) : openDevices.delete(id);
    }, true);

    $("devices").addEventListener("click", async (e) => {
        const btn = e.target.closest("button[data-action]");
        if (!btn) return;
        const id = btn.closest("details").dataset.id;
        if (btn.dataset.action === "hide") {
            const { hiddenDevices } = await getSettings();
            const next = hiddenDevices.includes(id) ? hiddenDevices.filter((x) => x !== id) : [...hiddenDevices, id];
            await chrome.storage.local.set({ hiddenDevices: next });
            devicesSignature = "";
            return refresh();
        }
        if (needsConfirm(btn, "Click again to remove everywhere")) return;
        btn.disabled = true;
        btn.textContent = "Removing…";
        try {
            await send("purgeDevice", { deviceId: id });
            openDevices.delete(id);
            devicesSignature = "";
        } catch (err) {
            btn.textContent = `Failed: ${err.message}`;
        }
        refresh();
    });

    $("server-url").addEventListener("input", syncHttpWarning);
    $("toggle-token").addEventListener("click", () => {
        const show = $("token").type === "password";
        $("token").type = show ? "text" : "password";
        $("toggle-token").textContent = show ? "Hide" : "Show";
    });

    $("btn-test").addEventListener("click", async () => {
        setResult("Testing…");
        $("btn-test").disabled = true;
        try {
            const r = await send("test", { serverUrl: $("server-url").value, token: $("token").value });
            setResult(
                r.tokenChecked
                    ? `✓ Connected to server ${r.version}: ${fmt(r.stats.visits)} visits from ${fmt(r.stats.devices)} device(s).`
                    : `✓ Server ${r.version} reachable. Enter the token to check it.`,
                "ok",
            );
        } catch (e) {
            setResult(`✗ ${e.message}`, "err");
        } finally {
            $("btn-test").disabled = false;
        }
    });

    $("settings-form").addEventListener("submit", async (ev) => {
        ev.preventDefault();
        let serverUrl;
        try {
            serverUrl = normalizeServerUrl($("server-url").value);
        } catch (e) {
            return setResult(`✗ ${e.message}`, "err");
        }
        const permission = serverUrl
            ? chrome.permissions.request({ origins: [originPattern(serverUrl)] }).catch(() => false)
            : Promise.resolve(true);
        await chrome.storage.local.set({
            serverUrl,
            token: $("token").value.trim(),
            deviceName: $("device-name").value.trim() || (await getSettings()).deviceName,
            pullIntervalMin: Number($("pull-interval").value),
            propagateClearAll: $("propagate-clear-all").checked,
            acceptDeleteAll: $("accept-delete-all").checked,
        });
        $("server-url").value = serverUrl;
        syncHttpWarning();
        const syncing = send("settingsChanged").catch((e) => ({ ok: false, error: e.message }));
        setResult("Saved. Syncing…");
        const result = await whileRefreshing(syncing);
        if (result.error) setResult(`Saved, but the sync failed: ${result.error}`, "err");
        else if (result.ok) setResult("✓ Saved and synced.", "ok");
        else setResult("Saved.", "ok");
        if (!(await permission)) setResult("Saved. Access to the server was not granted; sync relies on the server's CORS headers.", "warn");
    });

    $("paused").addEventListener("change", async () => {
        await chrome.storage.local.set({ paused: $("paused").checked });
        await send("settingsChanged");
        refresh();
    });

    $("btn-sync").addEventListener("click", async () => {
        $("btn-sync").disabled = true;
        await whileRefreshing(send("syncNow"));
    });

    $("btn-history").addEventListener("click", () => chrome.tabs.create({ url: chrome.runtime.getURL("history/history.html") }));
    linkToOptions($("open-options"));

    $("btn-backfill").addEventListener("click", async () => {
        $("btn-backfill").disabled = true;
        await whileRefreshing(send("backfill")).catch((e) => setResult(`✗ ${e.message}`, "err"));
    });

    loadForm().then(refresh);
    setInterval(refresh, 2000);
    onEvents([EVENT.visitsChanged, EVENT.countsChanged], refresh);
}
