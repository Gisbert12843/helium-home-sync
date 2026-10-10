export const ALL_URLS = "*";

export function isSyncableUrl(url) {
    return typeof url === "string" && /^https?:\/\//i.test(url);
}

export async function urlKey(url) {
    const bytes = new TextEncoder().encode(url);
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function visitRecord({ id, deviceId, deviceName, url, title, visitTime, transition }, state) {
    return {
        id,
        deviceId,
        deviceName: deviceName || "",
        url,
        title: title || "",
        visitTime,
        transition: transition || "link",
        state,
    };
}

export function makeLocalVisit(device, item, visitItem, state) {
    return visitRecord({
        id: `${device.deviceId}:${visitItem.visitId}:${visitItem.visitTime}`,
        deviceId: device.deviceId,
        deviceName: device.deviceName,
        url: item.url,
        title: item.title,
        visitTime: visitItem.visitTime,
        transition: visitItem.transition,
    }, state);
}

export const remoteVisitRecord = (change) => visitRecord(change, "remote");

export async function visitToChange({ state, ...visit }) {
    return { type: "visit", ...visit, urlKey: await urlKey(visit.url) };
}

function envelope(device, type, idTag = type) {
    return {
        type,
        id: `${device.deviceId}:${idTag}:${crypto.randomUUID()}`,
        deviceId: device.deviceId,
        deviceName: device.deviceName,
    };
}

export async function makeDeleteChange(device, url, deletedAt) {
    return { ...envelope(device, "delete", "del"), url, urlKey: url === null ? null : await urlKey(url), deletedAt };
}

export function makePurgeChange(device, targetDeviceId, before) {
    return { ...envelope(device, "purge"), targetDeviceId, before };
}

export function makeRejoinChange(device, at) {
    return { ...envelope(device, "rejoin"), at };
}

const TIME_FIELD = { visit: "visitTime", delete: "deletedAt", purge: "before", rejoin: "at" };

export const changeTime = (change) => change[TIME_FIELD[change.type]];

export const deviceTombstoneKey = (deviceId) => `device:${deviceId}`;
