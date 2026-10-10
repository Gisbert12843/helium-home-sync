#!/usr/bin/env python3
# Checks that server.py and manifest.json carry the same version (and the same as a tag, if given).
# Usage: check_version.py [vX.Y.Z]
import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

with open(os.path.join(ROOT, "server", "server.py")) as f:
    server = re.search(r'^VERSION = "([^"]+)"$', f.read(), re.M).group(1)
with open(os.path.join(ROOT, "extension", "manifest.json")) as f:
    manifest = json.load(f)["version"]

if server != manifest:
    sys.exit(f"Version mismatch: server/server.py has {server}, extension/manifest.json has {manifest}")
if len(sys.argv) > 1 and sys.argv[1].removeprefix("v") != server:
    sys.exit(f"Tag {sys.argv[1]} does not match version {server}")
print(server)
