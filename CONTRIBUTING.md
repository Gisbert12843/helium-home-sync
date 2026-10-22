# Contributing

Thanks for helping out! Bug reports, fixes and ideas are all welcome. This is a spare-time project, so replies can take a few days.

## Before you start

- **Bugs:** open an issue with the bug report form. The error text from the popup and the server logs (`./manage.sh logs`) help most.
- **Small fixes** (typos, obvious bugs): just open a pull request.
- **Bigger changes or new features:** open an issue first so we can agree on the approach before you put time into it. Check the [scope](README.md#scope) too.
- **Security problems:** don't open a public issue, see [SECURITY.md](SECURITY.md).

## Development setup

Nothing to install or build. The server is plain Python 3.10+ (standard library only) and the extension is plain JavaScript.

**Server**, with a throwaway database:

```bash
SYNC_TOKEN=dev-token-0123456789 DB_PATH=/tmp/hhs-dev.db python3 server/server.py
```

**Extension:** open `helium://extensions`, turn on **Developer mode**, click **Load unpacked** and choose `extension/`. Point it at `http://localhost:8787` with the token above. After every change, click **Reload ↻** on the extension's card; Helium keeps running the old background script otherwise.

**Two devices on one machine:** create a second Helium profile and load the extension there too. Each profile is its own device, which is enough to test uploads, downloads and deletes.

## Rules of thumb

- **No runtime dependencies and no build step.** Server: Python standard library only. Extension: plain ES modules that Helium loads directly.
- **Wire format changes** (requests, responses, change payloads) must update [PROTOCOL.md](PROTOCOL.md). If old servers or extensions can't handle the change, also bump `PROTOCOL_VERSION` in both `server/server.py` and `extension/lib/api.js`.
- **Version numbers** live in `server/server.py` (`VERSION`) and `extension/manifest.json`. Set both with one command: `python3 tools/check_version.py set x.y.z`. CI checks that they match.
- **Changelog:** add a line under `## Unreleased` in [CHANGELOG.md](CHANGELOG.md) for anything a user would notice.
- **Shell scripts** must pass `shellcheck`.
- Match the style of the code around your change.

CI runs on every pull request: syntax checks for Python, JavaScript and shell, the version check, and a server smoke test. Please test UI and sync changes by hand in Helium as well; CI can't do that.

## Releases (maintainers)

1. Move the `Unreleased` entries in `CHANGELOG.md` under a new `## [x.y.z] - YYYY-MM-DD` heading.
2. Set the version: `python3 tools/check_version.py set x.y.z`.
3. Merge to `main`, then `git tag vx.y.z && git push origin vx.y.z`.

The release workflow first runs the CI checks. Then it builds the extension zip and creates the GitHub Release with the changelog section as notes.

### Test releases (beta)

A tag with a suffix makes a test release from a feature branch. `main` does not change.

1. Set the version of the coming release, e.g. `python3 tools/check_version.py set 1.1.0`, and keep the changes under `## Unreleased`.
2. Push the branch, then `git tag v1.1.0-beta.1 && git push origin v1.1.0-beta.1`.

The workflow marks it as a pre-release (never "Latest") and takes the notes from `## Unreleased`. The extension card shows `1.1.0-beta.1`. Never move a tag: for a fix, tag `v1.1.0-beta.2`.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
