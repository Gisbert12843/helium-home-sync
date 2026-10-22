#!/usr/bin/env python3
# Keeps the version in server/server.py and extension/manifest.json the same. See USAGE.
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.path.join(ROOT, "server", "server.py")
MANIFEST = os.path.join(ROOT, "extension", "manifest.json")
SERVER_RE = re.compile(r'^VERSION = "([^"]+)"$', re.M)
MANIFEST_RE = re.compile(r'^(\s*"version":\s*")[^"]+(")', re.M)
USAGE = """The project has one version, stored in server/server.py and extension/manifest.json.

Usage: python3 tools/check_version.py <command>

  set X.Y.Z        Write version X.Y.Z into both files (before a release)
  check            Check that both files have the same version, and print it (CI)
  check vX.Y.Z     Also check that the version matches a release tag (release workflow)
  help             Show this text"""


def set_version(version):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        sys.exit(f"{version!r} is not a version like 1.2.3")
    # Find both versions before writing anything, so a failure leaves no file half-changed
    edits = []
    for path, pattern, repl in ((SERVER, SERVER_RE, f'VERSION = "{version}"'),
                                (MANIFEST, MANIFEST_RE, rf"\g<1>{version}\g<2>")):
        with open(path) as f:
            text, found = pattern.subn(repl, f.read(), count=1)
        if not found:
            sys.exit(f"No version found in {path}")
        edits.append((path, text))
    for path, text in edits:
        with open(path, "w") as f:
            f.write(text)


cmd, args = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ("help", [])
if cmd in ("help", "-h", "--help"):
    print(USAGE)
    sys.exit()
if cmd == "set" and len(args) == 1:
    set_version(args[0].removeprefix("v"))
    args = []
elif cmd != "check" or len(args) > 1:
    sys.exit(USAGE)

with open(SERVER) as f:
    server = SERVER_RE.search(f.read()).group(1)
with open(MANIFEST) as f:
    manifest = json.load(f)["version"]

if server != manifest:
    sys.exit(f"Version mismatch: server/server.py has {server}, extension/manifest.json has {manifest}")
if args and args[0].removeprefix("v") != server:
    sys.exit(f"Tag {args[0]} does not match version {server}")
print(server)
