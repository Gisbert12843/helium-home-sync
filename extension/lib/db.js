const DB_VERSION = 1;
const DB_NAME = "helium-home-sync";
let dbPromise = null;

export function openDB() {
    if (!dbPromise) {
        dbPromise = new Promise((resolve, reject) => {
            const req = indexedDB.open(DB_NAME, DB_VERSION);
            req.onupgradeneeded = () => {
                const db = req.result;
                const visits = db.createObjectStore("visits", { keyPath: "id" });
                visits.createIndex("visitTime", "visitTime");
                visits.createIndex("url", "url");
                visits.createIndex("deviceId", "deviceId");
                visits.createIndex("state", "state");
                db.createObjectStore("outbox", { keyPath: "id" });
                db.createObjectStore("imported", { keyPath: "visitId" }).createIndex("url", "url");
                db.createObjectStore("suppress", { keyPath: "url" });
                db.createObjectStore("tombstones", { keyPath: "url" });
                db.createObjectStore("meta");
            };
            req.onsuccess = () => resolve(req.result);
            req.onerror = () => reject(req.error);
            req.onblocked = () => reject(new Error("IndexedDB upgrade blocked"));
        });
    }
    return dbPromise;
}

export function promisify(request) {
    return new Promise((resolve, reject) => {
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
    });
}

export async function tx(names, mode, fn) {
    const db = await openDB();
    const list = Array.isArray(names) ? names : [names];
    const t = db.transaction(list, mode);
    const stores = Object.fromEntries(list.map((n) => [n, t.objectStore(n)]));
    let result;
    const done = new Promise((resolve, reject) => {
        t.oncomplete = () => resolve();
        t.onerror = () => reject(t.error);
        t.onabort = () => reject(t.error || new Error("transaction aborted"));
    });
    try {
        result = await fn(stores, t);
    } catch (e) {
        try { t.abort(); } catch { }
        await done.catch(() => { });
        throw e;
    }
    await done;
    return result;
}

export const get = (store, key) => tx(store, "readonly", (s) => promisify(s[store].get(key)));
export const put = (store, value, key) =>
    tx(store, "readwrite", (s) => promisify(key === undefined ? s[store].put(value) : s[store].put(value, key)));
const source = (s, store, index) => (index ? s[store].index(index) : s[store]);
export const count = (store, query, index) => tx(store, "readonly", (s) => promisify(source(s, store, index).count(query)));
export const getAll = (store, query, limit, index) =>
    tx(store, "readonly", (s) => promisify(source(s, store, index).getAll(query, limit)));

export const getMeta = async (key, fallback) => (await get("meta", key)) ?? fallback;
export const setMeta = (key, value) => put("meta", value, key);

export function iterate(source, query, direction, fn) {
    return new Promise((resolve, reject) => {
        const req = source.openCursor(query, direction);
        req.onerror = () => reject(req.error);
        req.onsuccess = () => {
            const cursor = req.result;
            if (!cursor) return resolve();
            let goOn;
            try {
                goOn = fn(cursor);
            } catch (e) {
                return reject(e);
            }
            if (goOn === false) return resolve();
            cursor.continue();
        };
    });
}

