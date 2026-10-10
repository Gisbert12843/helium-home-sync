export const EVENT = {
    visitsChanged: "visitsChanged",
    countsChanged: "countsChanged",
};

export const broadcast = (event) => chrome.runtime.sendMessage({ event }).catch(() => { });

export async function send(cmd, extra = {}) {
    const r = await chrome.runtime.sendMessage({ cmd, ...extra });
    if (!r) throw new Error("No answer from the background worker");
    if (!r.ok) throw new Error(r.error);
    return r.result;
}

export function onEvents(events, fn) {
    chrome.runtime.onMessage.addListener((msg) => {
        if (events.includes(msg?.event)) fn(msg);
    });
}
