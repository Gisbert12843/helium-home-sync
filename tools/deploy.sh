#!/usr/bin/env bash
# Deploys server/ from this checkout to a Proxmox LXC install of Helium Home Sync.
#   tools/deploy.sh [options] <user@host>   or set HHS_DEPLOY_TARGET (and HHS_DEPLOY_CT)
#   -c, --ct <ctid>   <user@host> is the Proxmox host: update container <ctid> with proxmox-lxc.sh
#   -n, --dry-run     run the checks and show what would change, change nothing
#   -y, --yes         do not ask before the install
#   -f, --force       install even when no installed file differs (e.g. to run a changed install.sh again)
# Without --ct, <user@host> is the container itself, e.g. root@helium-home-sync.
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
APP=/opt/helium-home-sync
CONF=/etc/helium-home-sync/env

if [[ -t 1 ]]; then B=$'\e[1m'; Y=$'\e[33m'; G=$'\e[32m'; R=$'\e[31m'; N=$'\e[0m'; else B= Y= G= R= N=; fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    %s%s%s\n' "$Y" "$*" "$N"; }
die() { printf '\n%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
usage() { sed -n '2,8s/^# \{0,1\}//p' "$0" >&2; exit 1; }

TARGET=${HHS_DEPLOY_TARGET:-} CT=${HHS_DEPLOY_CT:-} DRY=0 YES=0 FORCE=0
while (($#)); do
  case $1 in
    -c|--ct) [[ $# -ge 2 ]] || usage; CT=$2; shift ;;
    -n|--dry-run) DRY=1 ;;
    -y|--yes) YES=1 ;;
    -f|--force) FORCE=1 ;;
    -*) usage ;;
    *) TARGET=$1 ;;
  esac
  shift
done
[[ -n $TARGET ]] || usage
[[ -z $CT || $CT =~ ^[1-9][0-9]*$ ]] || die "--ct needs a container id, e.g. --ct 102"
cd "$ROOT"

step "checking the sources"
python3 -m py_compile server/*.py tools/*.py || die "Python syntax error, see above"
NEW=$(python3 tools/check_version.py check) || die "the versions differ, see above"
if command -v shellcheck >/dev/null; then
  shellcheck server/*.sh server/proxmox/*.sh tools/*.sh || die "shellcheck found problems, see above"
else
  warn "shellcheck not found, skipped"
fi
python3 tools/smoke_test.py >/dev/null 2>&1 || die "the smoke test failed: python3 tools/smoke_test.py"
info "version $NEW: syntax, versions and smoke test ok"
[[ -z $(git status --porcelain -- server 2>/dev/null) ]] || warn "server/ has uncommitted changes. They are deployed too."

step "connecting to $TARGET"
CTL=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/hhs-deploy.XXXXXX")
SSH=(ssh -o ControlMaster=auto -o "ControlPath=$CTL/%C" -o ControlPersist=120 -o ConnectTimeout=10)
RTMP=
cleanup() {
  [[ -z $RTMP ]] || "${SSH[@]}" -n "$TARGET" "rm -rf '$RTMP'" || true
  "${SSH[@]}" -O exit "$TARGET" &>/dev/null || true
  rm -rf "$CTL"
}
trap cleanup EXIT
"${SSH[@]}" -n "$TARGET" true || die "ssh to $TARGET failed (VPN or Tailscale up? SSH key installed?)"

on_server() {
  if [[ -n $CT ]]; then "${SSH[@]}" -n "$TARGET" "pct exec $CT -- sh -c $(printf %q "$1")"
  else "${SSH[@]}" -n "$TARGET" "$1"; fi
}

if [[ -n $CT ]]; then
  WHERE="container $CT on $TARGET"
  [[ $("${SSH[@]}" -n "$TARGET" "pct status $CT" 2>&1) == *running* ]] || die "$WHERE is not running, or $TARGET is no Proxmox host"
else
  WHERE="container $TARGET"
fi
if ! on_server "test -f $CONF"; then
  [[ -z $CT ]] && "${SSH[@]}" -n "$TARGET" "command -v pct >/dev/null" && die "$TARGET is a Proxmox host. Add --ct <ctid>."
  die "no Helium Home Sync install in the $WHERE ($CONF is missing)"
fi
OLD=$(on_server "sed -n 's/^VERSION = \"\(.*\)\"/\1/p' $APP/server.py" || true)
PORT=$(on_server "sed -n 's/^PORT=//p' $CONF | tail -n1" || true)
info "$WHERE: installed version ${OLD:-unknown}, port ${PORT:=8787}"

step "comparing with the install"
PAIRS=()
for f in server/server.py server/admin.py server/schema.sql server/text/*; do PAIRS+=("$f $APP/${f#server/}"); done
PAIRS+=("server/manage.sh /usr/local/bin/helium-home-sync")
for f in server/proxmox/helium-home-sync{,-backup,-monitor}.service server/proxmox/helium-home-sync-monitor.timer; do
  PAIRS+=("$f /etc/systemd/system/${f##*/}")
done
REMOTE_SUMS=$(on_server "sha256sum ${PAIRS[*]##* } 2>/dev/null" || true)
CHANGED=()
for p in "${PAIRS[@]}"; do
  sum=$(sha256sum "${p%% *}" | cut -d' ' -f1)
  grep -qxF "$sum  ${p##* }" <<<"$REMOTE_SUMS" || CHANGED+=("${p%% *}")
done
info "version ${OLD:-unknown} -> $NEW"
if [[ -n $OLD && $OLD != "$NEW" && $(printf '%s\n' "$OLD" "$NEW" | sort -V | tail -n1) == "$OLD" ]]; then
  warn "This is a DOWNGRADE. An older server may not read a database that a newer one changed."
fi
if ((${#CHANGED[@]})); then
  info "files that change:"
  printf '      %s\n' "${CHANGED[@]#server/}"
elif ((FORCE)); then
  info "no installed file differs, --force installs anyway"
else
  printf '\n%sNothing to do, the %s is up to date.%s\n' "$G" "$WHERE" "$N"
  info "This compares the installed files, not the version. --force installs anyway."
  exit 0
fi
if ((DRY)); then info "dry run, nothing changed"; exit 0; fi

if ((!YES)); then
  echo
  info "The server restarts for a few seconds. The install makes a database backup first (the newest 3 are kept)."
  info "Way back: deploy the old version again, or: helium-home-sync restore <backup file>"
  printf '    Install %s on the %s? [y/N] ' "$NEW" "$WHERE" >&2
  read -r answer || answer=
  [[ $answer == [yY]* ]] || die "cancelled, nothing changed"
fi

step "copying server/ to $TARGET"
RTMP=$("${SSH[@]}" -n "$TARGET" "mktemp -d /tmp/helium-home-sync-deploy.XXXXXX")
tar -C server --exclude=__pycache__ --exclude=data --exclude=backups --exclude=.env -czf - . \
  | "${SSH[@]}" "$TARGET" "tar -C '$RTMP' -xzf -"
info "done"

step "installing $NEW"
if [[ -n $CT ]]; then
  "${SSH[@]}" -n "$TARGET" "bash '$RTMP/proxmox-lxc.sh' update $CT" || die "the update failed, see above"
else
  "${SSH[@]}" -n "$TARGET" "bash '$RTMP/manage.sh' update-backup" || die "the backup failed, nothing changed"
  "${SSH[@]}" -n "$TARGET" "bash '$RTMP/proxmox/install.sh' code" || die "the install failed, see above"
fi

step "checking the server"
health=
for _ in $(seq 1 15); do
  health=$(on_server "curl -fsS -m 3 http://127.0.0.1:$PORT/api/health" 2>/dev/null || true)
  [[ $health == *"\"version\":\"$NEW\""* ]] && break
  sleep 1
done
[[ $health == *"\"version\":\"$NEW\""* ]] || die "the server does not report $NEW (answer: ${health:-none}). Check: helium-home-sync logs"
printf '\n%sThe %s runs %s.%s\n' "$G" "$WHERE" "$NEW" "$N"

if [[ -z $(on_server "sed -n 's/^AUTO_BACKUP=//p' $CONF | tail -n1") ]]; then
  step "daily backups"
  if ((YES)); then
    warn "The $WHERE has no daily backup. Turn it on: ${CT:+pct exec $CT -- }helium-home-sync backups on"
  else
    printf '    The %s has no daily backup yet. Back up every day at 03:30, keep the newest 14? [Y/n] ' "$WHERE" >&2
    if ! read -r answer; then echo; warn "No answer. Turn them on later: ${CT:+pct exec $CT -- }helium-home-sync backups on"
    elif [[ $answer == [nN]* ]]; then on_server "helium-home-sync backups off"
    else on_server "helium-home-sync backups on"; fi
  fi
fi
