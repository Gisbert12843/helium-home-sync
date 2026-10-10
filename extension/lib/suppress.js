import { tx, promisify, getMeta, setMeta } from "./db.js";
import { SECOND_MS } from "./time.js";

const SUPPRESS_TTL_MS = 30 * SECOND_MS;

export async function suppressUrls(urls) {
    if (!urls.length) return;
    const until = Date.now() + SUPPRESS_TTL_MS;
    await tx("suppress", "readwrite", (s) => {
        for (const url of urls) s.suppress.put({ url, until });
    });
}

export async function isSuppressed(url) {
    const row = await tx("suppress", "readonly", (s) => promisify(s.suppress.get(url)));
    return Boolean(row && row.until > Date.now());
}

export const suppressAll = () => setMeta("suppressAllUntil", Date.now() + SUPPRESS_TTL_MS);
export const isAllSuppressed = async () => (await getMeta("suppressAllUntil", 0)) > Date.now();

export async function pruneSuppress() {
    const now = Date.now();
    await tx("suppress", "readwrite", async (s) => {
        const rows = await promisify(s.suppress.getAll());
        for (const r of rows) if (r.until <= now) s.suppress.delete(r.url);
    });
}
