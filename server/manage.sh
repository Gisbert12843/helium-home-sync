#!/usr/bin/env bash
set -euo pipefail

SERVICE=helium-home-sync
LXC_ENV=/etc/helium-home-sync/env

if [[ -t 1 ]]; then B=$'\e[1m'; D=$'\e[2m'; Y=$'\e[33m'; G=$'\e[32m'; R=$'\e[31m'; N=$'\e[0m'; else B= D= Y= G= R= N=; fi
die() { echo "${R}$*${N}" >&2; exit 1; }

if [[ -f $LXC_ENV ]]; then
  MODE=lxc
  CMD=helium-home-sync
  ENV_FILE=$LXC_ENV
  APP=/opt/helium-home-sync
  DATA=/var/lib/helium-home-sync
  DB=$DATA/helium-home-sync.db
  BACKUPS=$DATA/backups
  TEXT=$APP/text
  [[ $EUID -eq 0 ]] || die "Run as root."
else
  MODE=docker
  CMD=./manage.sh
  ENV_FILE=.env
  BACKUPS=backups
  cd "$(dirname "$(readlink -f "$0")")"
  TEXT=$PWD/text
  # shellcheck disable=SC2034 # used by render ({{...}} in text/)
  PROJECT_DIR=$(cd .. && pwd)
fi

# Print a file from text/. Lines starting with "@lxc " or "@docker " only show in that mode,
# and {{NAME}} is replaced by the value of $NAME.
render() {
  local line name
  while IFS= read -r line || [[ -n $line ]]; do
    case $line in
      "@$MODE "*) line=${line#"@$MODE "} ;;
      @lxc\ * | @docker\ *) continue ;;
    esac
    while [[ $line =~ \{\{([A-Za-z_]+)\}\} ]]; do
      name=${BASH_REMATCH[1]}
      line=${line//"{{$name}}"/${!name-}}
    done
    printf '%s\n' "$line"
  done <"$TEXT/$1"
}

usage() {
  render manage-help.txt
  quick_status
}

compose() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi
}

prepare() {
  [[ $MODE == docker ]] || return 0
  command -v docker >/dev/null || die "Docker is not installed (Arch: sudo pacman -S docker docker-compose)."
  local err
  if ! err=$(docker info 2>&1 >/dev/null); then
    if [[ $err == *"permission denied"* ]]; then
      die "No permission to use Docker. Log out and back in (you are in the docker group), or run: newgrp docker"
    fi
    die "Docker is not running. Start it with: sudo systemctl enable --now docker"
  fi
}

env_value() {
  [[ -f $ENV_FILE ]] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n1
}

set_env_value() {
  if [[ -f $ENV_FILE ]] && grep -q "^$1=" "$ENV_FILE"; then
    sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
  else
    echo "$1=$2" >>"$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE"
}

token() {
  [[ -f $ENV_FILE ]] || die "No $ENV_FILE file. Create one with: $CMD rotate-token"
  env_value SYNC_TOKEN
}

port() {
  local p
  if [[ $MODE == lxc ]]; then
    p=$(env_value PORT)
  else
    p=$(compose port "$SERVICE" 8787 2>/dev/null | sed 's/.*://') || true
    [[ -n $p ]] || p=$(env_value PORT)
  fi
  echo "${p:-8787}"
}

running() {
  if [[ $MODE == lxc ]]; then
    systemctl is-active -q "$SERVICE"
  else
    [[ -n "$(compose ps -q --status running "$SERVICE" 2>/dev/null)" ]]
  fi
}

svc() {
  if [[ $MODE == lxc ]]; then
    systemctl "$1" "$SERVICE"
  else
    case $1 in
      start) compose up -d ;;
      stop) compose stop "$SERVICE" ;;
      restart) compose restart ;;
    esac
  fi
}

admin() {
  local tty=()
  if [[ ${1:-} == -T ]]; then tty=(-T); shift; elif [[ ! -t 0 || ! -t 1 ]]; then tty=(-T); fi
  if [[ $MODE == lxc ]]; then
    (cd "$DATA" && runuser -u "$SERVICE" -- env DB_PATH="$DB" MANAGE_CMD="$CMD" python3 "$APP/admin.py" "$@")
  elif running; then
    compose exec "${tty[@]}" "$SERVICE" python admin.py "$@"
  else
    compose --progress quiet run --rm --no-deps "${tty[@]}" "$SERVICE" python admin.py "$@"
  fi
}

addresses() {
  local p ip ips tsip
  p=$(port)
  [[ $MODE == lxc ]] || echo "  This machine:     http://127.0.0.1:$p"
  ips=$(hostname -I 2>/dev/null || ip -4 -o addr show scope global | awk '{sub("/.*","",$4); print $4}')
  for ip in $ips; do
    [[ $ip == *:* ]] && continue
    [[ $MODE == docker && $ip =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && continue
    echo "  Network:          http://$ip:$p"
  done
  if command -v tailscale >/dev/null && tsip=$(tailscale ip -4 2>/dev/null) && [[ -n $tsip ]]; then
    echo "  Tailscale:        http://$tsip:$p"
    tsip=$(tailscale serve status 2>/dev/null | grep -o -m1 'https://[^ ]*' || true)
    [[ -z $tsip ]] || echo "  Tailscale HTTPS:  ${tsip%/}"
  fi
}

quick_status() {
  echo
  if [[ $MODE == docker ]] && ! docker info >/dev/null 2>&1; then
    echo "${D}Status: unknown (Docker not reachable; see '$CMD status')${N}"
  elif running; then
    echo "Status: ${G}running${N} on port $(port). Details: $CMD status"
  else
    echo "Status: ${Y}stopped${N}. Start it with: $CMD start"
  fi
}

healthy() {
  local _
  for _ in $(seq 1 "${1:-6}"); do
    curl -fsS -m 3 "http://127.0.0.1:$(port)/api/health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# Point 'tailscale serve' (HTTPS) at the new port if it forwarded to the old one.
move_tailscale_serve() {
  command -v tailscale >/dev/null || return 0
  [[ $(tailscale serve status 2>/dev/null) =~ 127\.0\.0\.1:$1([^0-9]|$) ]] || return 0
  if tailscale serve --https=443 off >/dev/null 2>&1 && timeout 60 tailscale serve --bg "$2" >/dev/null 2>&1; then
    echo "Tailscale HTTPS now forwards to port $2."
  else
    echo "${Y}Couldn't move Tailscale HTTPS. Do it by hand: tailscale serve --https=443 off && tailscale serve --bg $2${N}"
  fi
}

stamp() { date +%Y-%m-%d_%H%M%S; }

backup_to() {
  local file=$1
  mkdir -p "$(dirname "$file")"
  admin -T backup --stdout >"$file.part" || { rm -f "$file.part"; die "Backup failed."; }
  [[ "$(head -c 15 "$file.part")" == "SQLite format 3" ]] || { rm -f "$file.part"; die "Backup failed (not a database)."; }
  mv "$file.part" "$file"
  echo "Backup saved: $(readlink -f "$file") ($(du -h "$file" | cut -f1))"
}

restore_from() {
  local file=$1 tmp
  if [[ $MODE == lxc ]]; then
    tmp=$DATA/.restore-$$.db
    install -o "$SERVICE" -g "$SERVICE" -m 600 "$file" "$tmp"
    admin restore "$tmp" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
  else
    compose --progress quiet run --rm --no-deps -T -v "$file:/restore.db:ro" "$SERVICE" python admin.py restore /restore.db
  fi
}

ask() {
  local reply
  read -r -p "$1 Type '$2' to confirm: " reply
  [[ $reply == "$2" ]] || die "Cancelled."
}

cmd=${1:-help}
shift || true
case $cmd in
  help|-h|--help) usage ;;

  status)
    prepare
    if running; then
      if [[ $MODE == lxc ]]; then
        echo "Service:   ${G}running${N} since $(systemctl show -p ActiveEnterTimestamp --value "$SERVICE")"
      else
        echo "Container: ${G}$(compose ps --format '{{.Status}}' "$SERVICE")${N}"
      fi
      if healthy; then echo "Health:    ${G}ok${N}"; else echo "Health:    ${R}not answering${N} (see $CMD logs)"; fi
    else
      echo "Server:    ${Y}stopped${N} ($CMD start)"
    fi
    if [[ $MODE == lxc ]] && systemctl is-active -q "$SERVICE-backup.timer"; then
      echo "Backups:   daily, next $(systemctl show -p NextElapseUSecRealtime --value "$SERVICE-backup.timer")"
    fi
    echo; admin stats || true
    echo; echo "Devices use one of these as Server URL:"; addresses
    ;;

  start) prepare; svc start; echo "Started. Check with: $CMD status" ;;
  stop) prepare; svc stop; echo "Stopped. Devices keep working offline and upload later." ;;
  restart) prepare; svc restart; echo "Restarted." ;;
  logs)
    prepare
    if [[ $MODE == lxc ]]; then journalctl -u "$SERVICE" -f -n 100; else compose logs -f --tail 100 "$SERVICE"; fi
    ;;
  update)
    [[ $MODE == docker ]] || die "Update the code from the Proxmox host: ./proxmox-lxc.sh update <ctid>"
    prepare; compose up -d --build; echo "Rebuilt and restarted." ;;

  devices) prepare; admin devices ;;
  stats) prepare; admin stats ;;
  remove-device|purge-device)
    [[ $# -ge 1 ]] || die "Usage: $CMD remove-device <name|id>   (list them with $CMD devices)"
    prepare; admin purge-device "$@" ;;
  prune)
    [[ ${1:-} =~ ^[0-9]+$ ]] || die "Usage: $CMD prune <days>   e.g. $CMD prune 365"
    prepare; admin prune "$@" ;;

  backup) prepare; backup_to "${1:-$BACKUPS/helium-home-sync-$(stamp).db}" ;;
  auto-backup)
    prepare
    keep=$(env_value BACKUP_KEEP)
    [[ $keep =~ ^[1-9][0-9]*$ ]] || keep=14
    backup_to "$BACKUPS/auto-$(stamp).db"
    # shellcheck disable=SC2012 # only our own auto-<timestamp>.db names
    ls -1t "$BACKUPS"/auto-*.db 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f --
    ;;
  restore)
    [[ $# -ge 1 && -f $1 ]] || die "Usage: $CMD restore <backup file>   (backups are in $BACKUPS)"
    prepare
    file=$(readlink -f "$1")
    echo "This replaces ALL data on the server with $file."
    ask "Continue?" "restore"
    backup_to "$BACKUPS/before-restore-$(stamp).db"
    svc stop
    if ! restore_from "$file"; then
      svc start
      die "Restore failed. The server was restarted with its previous data."
    fi
    svc start
    echo "Restored. Devices notice the change at their next sync and re-download."
    ;;

  connect)
    prepare
    # shellcheck disable=SC2034 # used by render ({{...}} in text/)
    ADDRESSES=$(addresses | sed 's/^/   /')
    # shellcheck disable=SC2034 # used by render ({{...}} in text/)
    TOKEN=$(token)
    render connect.txt
    ;;
  token) token ;;
  set-port)
    [[ ${1:-} =~ ^[1-9][0-9]{0,4}$ ]] && (($1 <= 65535)) || die "Usage: $CMD set-port <1-65535>"
    prepare
    old=$(port)
    [[ $old != "$1" ]] || die "The server already uses port $1."
    set_env_value PORT "$1"
    if [[ $MODE == lxc ]]; then svc restart; else compose up -d; fi
    healthy 15 || die "The server is not answering on port $1 (see $CMD logs). Go back with: $CMD set-port $old"
    move_tailscale_serve "$old" "$1"
    echo "Port changed from $old to $1. On each device: click the extension icon > Settings > Server URL > Save."
    echo "New addresses:"
    addresses
    ;;
  rotate-token)
    prepare
    echo "The current token stops working; every device needs the new one."
    ask "Make a new token?" "yes"
    new=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))' 2>/dev/null || head -c 32 /dev/urandom | base64 | tr -d '/+=\n')
    set_env_value SYNC_TOKEN "$new"
    if [[ $MODE == lxc ]]; then svc restart; else compose up -d; fi
    echo "New token: ${B}$new${N}"
    echo "On each device: click the extension icon > Settings > Token > Save."
    ;;

  vacuum) prepare; admin vacuum ;;
  check) prepare; admin check ;;
  wipe)
    prepare
    echo "${R}This deletes ALL history on the server.${N} Devices keep their own data; they notice the"
    echo "empty server at their next sync and offer to upload their history again."
    ask "Wipe the server?" "wipe"
    backup_to "$BACKUPS/before-wipe-$(stamp).db"
    if [[ $MODE == lxc ]]; then
      svc stop
      rm -f "$DB" "$DB-wal" "$DB-shm"
      svc start
    else
      compose down -v
      compose up -d
    fi
    echo "Server is empty."
    ;;

  *) echo "Unknown command: $cmd" >&2; echo >&2; usage >&2; exit 1 ;;
esac
