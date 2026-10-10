CREATE TABLE IF NOT EXISTS changes (
  seq           INTEGER PRIMARY KEY AUTOINCREMENT,
  id            TEXT NOT NULL UNIQUE,
  type          TEXT NOT NULL,
  device_id     TEXT NOT NULL,
  url_key       TEXT,
  ts            REAL NOT NULL,
  payload       TEXT NOT NULL,
  received_at   INTEGER NOT NULL,
  target_device TEXT
);
CREATE INDEX IF NOT EXISTS changes_url_key ON changes(url_key, type, ts);
CREATE INDEX IF NOT EXISTS changes_type_ts ON changes(type, ts);
CREATE INDEX IF NOT EXISTS changes_device ON changes(device_id, type, ts);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
