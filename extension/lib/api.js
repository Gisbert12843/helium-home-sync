import { SECOND_MS } from "./time.js";

// Must match PROTOCOL_VERSION in server/server.py. A server that sends no header speaks 1.
export const PROTOCOL_VERSION = 1;

export class SyncApi {
    constructor({ serverUrl, token }) {
        this.base = serverUrl.replace(/\/+$/, "");
        this.token = token;
    }

    async request(method, path, body, { auth = true, timeoutMs = 30 * SECOND_MS } = {}) {
        const ctrl = new AbortController();
        const timer = setTimeout(() => ctrl.abort(), timeoutMs);
        let res;
        try {
            res = await fetch(this.base + path, {
                method,
                headers: {
                    ...(auth ? { Authorization: `Bearer ${this.token}` } : {}),
                    ...(body ? { "Content-Type": "application/json" } : {}),
                },
                body: body ? JSON.stringify(body) : undefined,
                signal: ctrl.signal,
                cache: "no-store",
            });
        } catch (e) {
            throw new Error(e.name === "AbortError" ? "Server did not respond (timeout)" : `Cannot reach server (${e.message})`);
        } finally {
            clearTimeout(timer);
        }
        const protocol = Number(res.headers.get("X-Sync-Protocol") ?? 1);
        if (protocol !== PROTOCOL_VERSION) {
            throw new Error(`Server uses sync protocol ${protocol}, this extension uses ${PROTOCOL_VERSION}. `
                + `Update the ${protocol > PROTOCOL_VERSION ? "extension" : "server"}.`);
        }
        let data = null;
        try {
            data = await res.json();
        } catch { }
        if (res.status === 401) throw new Error("Server rejected the token");
        if (!res.ok) throw new Error(`Server error ${res.status}${data?.error ? `: ${data.error}` : ""}`);
        if (data === null) throw new Error("Server sent an invalid response (is this a sync server?)");
        return data;
    }

    health() {
        return this.request("GET", "/api/health", null, { auth: false, timeoutMs: 10 * SECOND_MS });
    }

    stats() {
        return this.request("GET", "/api/stats", null, { timeoutMs: 10 * SECOND_MS });
    }

    postChanges(changes) {
        return this.request("POST", "/api/changes", { changes });
    }

    getChanges(since, limit) {
        return this.request("GET", `/api/changes?since=${since}&limit=${limit}`);
    }
}
