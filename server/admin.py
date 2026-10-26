#!/usr/bin/env python3
import argparse
import os
import shutil
import sqlite3
import sys
import tempfile
import time

from server import DB_PATH, LIMITS, Store, over_limits, usage

MANAGE = os.environ.get("MANAGE_CMD", "./manage.sh")


def when(ms, fmt="%Y-%m-%d %H:%M"):
    return time.strftime(fmt, time.localtime(ms / 1000)) if ms else "-"


def day(ms):
    return when(ms, "%Y-%m-%d")


def store():
    if not os.path.exists(DB_PATH):
        sys.exit(f"No database at {DB_PATH} (has the server run yet?)")
    return Store(DB_PATH)


def find_device(st, query):
    devices = st.devices()
    q = query.lower()
    exact = [d for d in devices if d["id"] == query]
    matches = exact or [d for d in devices if d["id"].startswith(query) or (d["name"] or "").lower() == q]
    if len(matches) == 1:
        return matches[0]
    if not matches:
        sys.exit(f"No device matches '{query}'. Run '{MANAGE} devices' to list them.")
    print(f"'{query}' matches several devices, use the id instead:", file=sys.stderr)
    print_devices(matches, out=sys.stderr)
    sys.exit(1)


def print_devices(devices, out=sys.stdout):
    if not devices:
        print("No devices have synced yet.", file=out)
        return
    print(f"{'NAME':<20} {'ID':<8} {'VISITS':>7}  {'FIRST':<10}  {'LAST':<10}  LAST SYNC", file=out)
    for d in devices:
        print(f"{(d['name'] or '?')[:20]:<20} {d['id'][:8]:<8} {d['visits']:>7}  {day(d['firstVisit']):<10}  "
              f"{day(d['lastVisit']):<10}  {when(d['lastUpload'])}", file=out)


def confirm(question, assume_yes):
    if assume_yes:
        return True
    if not sys.stdin.isatty():
        sys.exit(f"{question} Re-run with --yes to confirm.")
    return input(f"{question} [y/N] ").strip().lower() in ("y", "yes")


def cmd_stats(args):
    st = store()
    s = st.stats()
    print(f"Database:   {DB_PATH} ({st.size() / 1e6:.1f} MB)")
    print(f"Server id:  {s['serverId']}")
    print(f"Visits:     {s['visits']}")
    print(f"Deletes:    {s['deletes']}   Device removals: {s['purges']}")
    print(f"Devices:    {s['devices']} with visits")
    print(f"Log head:   seq {s['lastSeq']}")
    print(f"Usage:      disk {s['diskPct']}%, memory {s['memoryPct']}%, swap {s['swapPct']}% (limits: {s['limits']})")


def cmd_devices(args):
    print_devices(store().devices())


def cmd_purge_device(args):
    st = store()
    d = find_device(st, args.device)
    print(f"Device: {d['name']} ({d['id'][:8]}), {d['visits']} visits on the server.")
    print("This deletes its visits from the server and from every other device at their next sync.")
    print("The device itself keeps its own local history. To stop it syncing, remove the extension")
    print(f"there or change the token ({MANAGE} rotate-token).")
    if not confirm("Remove this device's history from sync?", args.yes):
        sys.exit("Cancelled.")
    n = st.purge_device(d["id"])
    print(f"Removed {d['name']} and its {n} visits. Other devices drop them at their next sync.\n"
          f"To add it back later, click \"Add back to sync\" in its popup.")


def cmd_prune(args):
    st = store()
    cutoff = time.time() * 1000 - args.days * 86400_000
    n = st.prune(cutoff, dry_run=True)
    print(f"{n} visits on the server are older than {args.days} days (before {when(cutoff)}).")
    print("Devices keep their own copies; only new devices will no longer receive them.")
    if not n or not confirm("Delete them from the server?", args.yes):
        sys.exit(0 if not n else "Cancelled.")
    print(f"Deleted {st.prune(cutoff)} visits. Run '{MANAGE} vacuum' to shrink the file.")


def cmd_backup(args):
    st = store()
    if args.stdout:
        fd, tmp = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        try:
            st.backup(tmp)
            with open(tmp, "rb") as f:
                shutil.copyfileobj(f, sys.stdout.buffer)
        finally:
            os.unlink(tmp)
    else:
        st.backup(args.file)
        print(f"Backup written to {args.file}")


def cmd_restore(args):
    fd, tmp = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    shutil.copyfile(args.file, tmp)
    src = sqlite3.connect(tmp)
    try:
        tables = {r[0] for r in src.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    except sqlite3.DatabaseError as e:
        os.unlink(tmp)
        sys.exit(f"{args.file} is not a valid backup: {e}")
    if "changes" not in tables:
        sys.exit(f"{args.file} is not a Helium Home Sync backup (no changes table).")
    os.makedirs(os.path.dirname(os.path.abspath(DB_PATH)), exist_ok=True)
    dst = sqlite3.connect(DB_PATH)
    src.backup(dst)
    dst.close()
    src.close()
    os.unlink(tmp)
    print(f"Restored {args.file} into {DB_PATH}.")
    Store(DB_PATH)


def cmd_vacuum(args):
    st = store()
    before = st.size()
    st.vacuum()
    print(f"Database compacted: {before / 1e6:.1f} MB -> {st.size() / 1e6:.1f} MB")


def cmd_check(args):
    result = store().integrity()
    print(f"Integrity check: {result}")
    sys.exit(0 if result == "ok" else 1)


def cmd_resources(args):
    pct = usage(DB_PATH)
    print(f"Disk {pct['disk']}%, memory {pct['memory']}%, swap {pct['swap']}%, database {store().size() / 1e6:.1f} MB.")
    over = over_limits(pct)
    for k in over:
        print(f"{k.capitalize()} is {pct[k]}% (limit {LIMITS[k]}%).")
    print(f"Limits: disk {LIMITS['disk']}%, memory {LIMITS['memory']}%, swap {LIMITS['swap']}%.")
    sys.exit(1 if over else 0)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("stats").set_defaults(fn=cmd_stats)
    sub.add_parser("devices").set_defaults(fn=cmd_devices)
    sp = sub.add_parser("purge-device")
    sp.add_argument("device", help="device id, id prefix or name")
    sp.add_argument("--yes", action="store_true")
    sp.set_defaults(fn=cmd_purge_device)
    sp = sub.add_parser("prune")
    sp.add_argument("days", type=int)
    sp.add_argument("--yes", action="store_true")
    sp.set_defaults(fn=cmd_prune)
    sp = sub.add_parser("backup")
    g = sp.add_mutually_exclusive_group(required=True)
    g.add_argument("file", nargs="?")
    g.add_argument("--stdout", action="store_true")
    sp.set_defaults(fn=cmd_backup)
    sp = sub.add_parser("restore")
    sp.add_argument("file")
    sp.set_defaults(fn=cmd_restore)
    sub.add_parser("vacuum").set_defaults(fn=cmd_vacuum)
    sub.add_parser("check").set_defaults(fn=cmd_check)
    sub.add_parser("resources").set_defaults(fn=cmd_resources)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
