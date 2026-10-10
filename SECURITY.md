# Security policy

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Report them privately instead:

**[Report a vulnerability](https://github.com/Gisbert12843/helium-home-sync/security/advisories/new)** (GitHub private vulnerability reporting)

Include what you found, how to reproduce it, and what an attacker could do with it. You'll get an answer as soon as possible. This is a spare-time project, so please allow a few days. Once a fix is released, you'll be credited in the advisory unless you'd rather not be.

## What counts

Helium Home Sync handles people's complete browsing history, so these matter most:

- Getting data from the server without the token, or bypassing token checks
- Server crashes, or ways to corrupt or delete data, through crafted requests
- The extension leaking history or the token to anything other than the configured server
- Problems in the install and management scripts (`manage.sh`, `proxmox-lxc.sh`, `server/proxmox/`), such as unsafe file permissions or command injection

## Known limitations (by design, for now)

- **The server can read URLs and page titles.** End-to-end encryption is planned (see [PROTOCOL.md](PROTOCOL.md)). Until then, run the server on a machine you trust.
- **Plain `http://` is allowed.** That's meant for localhost, LANs and Tailscale. Over the internet, put HTTPS in front (see the README); the extension shows a warning for `http://` URLs.
- **One shared token** for all devices. Anyone with the token has full read and write access to the synced history.

## Supported versions

Only the latest release gets security fixes.
