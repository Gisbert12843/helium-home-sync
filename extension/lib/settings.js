const DEFAULTS = {
    serverUrl: "",
    token: "",
    deviceId: "",
    deviceName: "",
    pullIntervalMin: 0,
    paused: false,
    propagateClearAll: false,
    acceptDeleteAll: false,
    hiddenDevices: [],
};

function defaultDeviceName() {
    const p = (navigator.userAgentData?.platform || navigator.platform || "").toLowerCase();
    const os = p.includes("linux") ? "Linux" : p.includes("mac") ? "macOS" : p.includes("win") ? "Windows" : "desktop";
    return `Helium on ${os}`;
}

export async function getSettings() {
    const stored = await chrome.storage.local.get(Object.keys(DEFAULTS));
    return { ...DEFAULTS, ...stored };
}

export async function ensureDevice() {
    const s = await getSettings();
    const patch = {};
    if (!s.deviceId) patch.deviceId = crypto.randomUUID();
    if (!s.deviceName) patch.deviceName = defaultDeviceName();
    if (Object.keys(patch).length) await chrome.storage.local.set(patch);
    return { ...s, ...patch };
}

export function normalizeServerUrl(raw) {
    const value = (raw || "").trim();
    if (!value) return "";
    let url;
    try {
        url = new URL(value);
    } catch {
        throw new Error("Server URL is not a valid URL");
    }
    if (url.protocol !== "http:" && url.protocol !== "https:") throw new Error("Server URL must start with http:// or https://");
    return url.origin + url.pathname.replace(/\/+$/, "");
}

export function isConfigured(s) {
    return Boolean(s.serverUrl && s.token);
}

export const canSync = (s) => isConfigured(s) && !s.paused;

export const isInsecure = (serverUrl) => /^http:\/\//i.test(serverUrl || "");

export function originPattern(serverUrl) {
    const u = new URL(serverUrl);
    return `${u.protocol}//${u.hostname}/*`;
}
