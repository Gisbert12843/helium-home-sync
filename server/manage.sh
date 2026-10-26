#!/usr/bin/env bash
set -euo pipefail

SERVICE=helium-home-sync
LXC_ENV=/etc/helium-home-sync/env
BACKUP_TIME_DEFAULT=03:30
BACKUP_KEEP_DEFAULT=14
UPDATE_BACKUPS_KEEP=3
BACKUP_MAX_AGE_HOURS=48

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
    [[ ! -s $ENV_FILE || -z $(tail -c1 "$ENV_FILE") ]] || echo >>"$ENV_FILE"
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
    (cd "$DATA" && runuser -u "$SERVICE" -- env DB_PATH="$DB" MANAGE_CMD="$CMD" LIMIT_DISK="$(env_value LIMIT_DISK)" \
      LIMIT_MEMORY="$(env_value LIMIT_MEMORY)" LIMIT_SWAP="$(env_value LIMIT_SWAP)" python3 "$APP/admin.py" "$@")
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

# Check service, disk, memory and swap. Report to MONITOR_URL (Healthchecks.io style) if it is set.
monitor() {
  local report ok=1 url
  report=$(admin -T resources 2>&1) || ok=0
  if ! running; then report+=$'\nService is not running.'; ok=0
  elif ! healthy; then report+=$'\n'"Server does not answer on port $(port)."; ok=0; fi
  if [[ $(env_value AUTO_BACKUP) == yes && -z $(find "$BACKUPS" -maxdepth 1 -name 'auto-*.db' \
    -mmin -$((BACKUP_MAX_AGE_HOURS * 60)) 2>/dev/null) ]]; then
    report+=$'\n'"No daily backup in the last $BACKUP_MAX_AGE_HOURS hours (see: $CMD backups)."; ok=0
  fi
  echo "$report"
  url=$(env_value MONITOR_URL)
  ((ok)) || url=${url:+$url/fail}
  [[ -z $url ]] || curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "$report" "$url" || echo "${Y}Could not reach $url${N}" >&2
  ((ok))
}

stamp() { date +%Y-%m-%d_%H%M%S; }

new_token() { python3 -c 'import secrets; print(secrets.token_urlsafe(32))' 2>/dev/null || head -c 32 /dev/urandom | base64 | tr -d '/+=\n'; }

backup_keep() {
  local k
  k=$(env_value BACKUP_KEEP)
  [[ $k =~ ^[1-9][0-9]*$ ]] && echo "$k" || echo "$BACKUP_KEEP_DEFAULT"
}

# rotate PREFIX KEEP: delete all but the newest KEEP backups named PREFIX-<timestamp>.db
rotate() {
  # shellcheck disable=SC2012 # only our own <prefix>-<timestamp>.db names
  ls -1t "$BACKUPS/$1"-*.db 2>/dev/null | tail -n +$(($2 + 1)) | xargs -r rm -f --
}

restart_server() { if [[ $MODE == lxc ]]; then svc restart; else compose up -d; fi; }

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
  local reply=
  printf "%s Type '%s' to confirm: " "$1" "$2" >&2
  read -r reply || true
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
    if [[ $(env_value AUTO_BACKUP) == yes ]]; then
      echo "Backups:   daily at $(env_value BACKUP_TIME), keeping the newest $(backup_keep)"
    else
      echo "Backups:   ${Y}off${N} (turn on: $CMD backups on)"
    fi
    if [[ -n $(env_value MONITOR_URL) ]]; then
      echo "Alerts:    health check every 5 min, reports to $(env_value MONITOR_URL | cut -d/ -f3)"
    else
      echo "Alerts:    off (turn on: $CMD monitor on <ping URL>)"
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
  auto-backup) prepare; backup_to "$BACKUPS/auto-$(stamp).db"; rotate auto "$(backup_keep)" ;;
  update-backup) prepare; backup_to "$BACKUPS/update-$(stamp).db"; rotate update "$UPDATE_BACKUPS_KEEP" ;;
  backups)
    case ${1:-} in
      '')
        if [[ $(env_value AUTO_BACKUP) == yes ]]; then
          echo "Daily backups: ${G}on${N} at $(env_value BACKUP_TIME), keeping the newest $(backup_keep)."
        else
          echo "Daily backups: ${Y}off${N}. Turn them on with: $CMD backups on [HH:MM] [number to keep]"
        fi
        echo "Folder: $(readlink -f "$BACKUPS") ($(find "$BACKUPS" -maxdepth 1 -name '*.db' 2>/dev/null | wc -l) files)"
        # shellcheck disable=SC2012 # only our own <kind>-<timestamp>.db names
        ls -1t "$BACKUPS" 2>/dev/null | head -n 5 | sed 's/^/  /'
        echo "Cleanup: daily backups (auto-*) keep the newest $(backup_keep), backups before an update (update-*)"
        echo "the newest $UPDATE_BACKUPS_KEEP. Backups you make with '$CMD backup' and before a restore are never deleted."
        ;;
      on)
        time=${2:-$(env_value BACKUP_TIME)}
        time=${time:-$BACKUP_TIME_DEFAULT}
        keep=${3:-$(backup_keep)}
        [[ $time =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ && $keep =~ ^[1-9][0-9]{0,3}$ ]] ||
          die "Usage: $CMD backups on [HH:MM] [number to keep]   e.g. $CMD backups on 03:30 14"
        prepare
        set_env_value AUTO_BACKUP yes
        set_env_value BACKUP_TIME "$time"
        set_env_value BACKUP_KEEP "$keep"
        if [[ $MODE == lxc ]]; then
          printf '[Unit]\nDescription=Daily %s database backup\n\n[Timer]\nOnCalendar=*-*-* %s:00\nRandomizedDelaySec=10min\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' \
            "$SERVICE" "$time" >"/etc/systemd/system/$SERVICE-backup.timer"
          systemctl daemon-reload
          systemctl enable -q --now "$SERVICE-backup.timer"
        else
          echo "Docker has no timer of its own. Add this line to your crontab (crontab -e):"
          echo "  ${time#*:} ${time%:*} * * * cd $PWD && ./manage.sh auto-backup >/dev/null"
        fi
        echo "Daily backups on at $time, keeping the newest $keep. Turn them off with: $CMD backups off"
        backup_to "$BACKUPS/auto-$(stamp).db"
        rotate auto "$keep"
        ;;
      off)
        [[ $MODE != lxc ]] || systemctl disable -q --now "$SERVICE-backup.timer" 2>/dev/null || true
        set_env_value AUTO_BACKUP no
        echo "Daily backups off. The existing backups stay in $(readlink -f "$BACKUPS")."
        [[ $MODE == lxc ]] || echo "Remove the auto-backup line from your crontab too (crontab -e)."
        ;;
      *) die "Usage: $CMD backups [on [HH:MM] [number to keep] | off]" ;;
    esac
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
    new=$(new_token)
    set_env_value SYNC_TOKEN "$new"
    restart_server
    echo "New token: ${B}$new${N}"
    echo "On each device: click the extension icon > Settings > Token > Save."
    ;;
  status-token)
    prepare
    old=$(env_value STATUS_TOKEN)
    if [[ ${1:-} == off ]]; then
      [[ -n $old ]] || { echo "There is no status token."; exit 0; }
      echo "Tools that use the status token (e.g. a dashboard) stop working. The server restarts."
      ask "Remove the status token?" "yes"
      set_env_value STATUS_TOKEN ""
      restart_server
      echo "Status token removed. Make a new one any time with: $CMD status-token"
    elif [[ -n $old && ${1:-} != new ]]; then
      echo "$old"
    else
      [[ -n $old ]] && echo "The current status token stops working. Tools that use it (e.g. a dashboard) need the new one."
      echo "The status token can only read GET /api/stats (counts, sizes, times). The server restarts."
      ask "Make a new status token?" "yes"
      new=$(new_token)
      set_env_value STATUS_TOKEN "$new"
      restart_server
      echo "Status token: ${B}$new${N}"
      echo "Use it as 'Authorization: Bearer <token>' for /api/stats. Replace it: $CMD status-token new. Remove it: $CMD status-token off"
    fi
    ;;

  vacuum) prepare; admin vacuum ;;
  check) prepare; admin check ;;
  monitor)
    case ${1:-} in
      '') prepare; monitor ;;
      on)
        [[ ${2:-} =~ ^https?://[^[:space:]|\&\\]+$ ]] || die "Usage: $CMD monitor on <ping URL>   e.g. https://hc-ping.com/<uuid>"
        old=$(env_value MONITOR_URL)
        set_env_value MONITOR_URL "$2"
        if [[ $MODE == lxc ]]; then
          systemctl enable -q --now "$SERVICE-monitor.timer"
          echo "Alerts: ${old:-off} -> $2. The health check runs every 5 minutes."
        else
          echo "Alerts: ${old:-off} -> $2. Add this line to your crontab (crontab -e):"
          echo "  */5 * * * * cd $PWD && ./manage.sh monitor >/dev/null"
        fi
        echo "Turn it off with: $CMD monitor off"
        echo "First report:"
        prepare
        monitor || true
        ;;
      off)
        old=$(env_value MONITOR_URL)
        [[ $MODE != lxc ]] || systemctl disable -q --now "$SERVICE-monitor.timer" 2>/dev/null || true
        set_env_value MONITOR_URL ""
        echo "Alerts off (the URL was: ${old:-none}). Pause or delete the check on Healthchecks.io too, or it reports a failure."
        [[ $MODE == lxc ]] || echo "Remove the monitor line from your crontab too (crontab -e)."
        ;;
      *) die "Usage: $CMD monitor [on <ping URL> | off]" ;;
    esac
    ;;
  limits)
    prepare
    if (($# == 0)); then admin -T resources || true; exit 0; fi
    while (($#)); do
      [[ $1 =~ ^(disk|memory|swap)$ && ${2:-} =~ ^([1-9][0-9]?|100|default)$ ]] ||
        die "Usage: $CMD limits [disk|memory|swap <1-100|default>] ...   e.g. $CMD limits disk 85"
      key=LIMIT_${1^^}
      old=$(env_value "$key")
      new=$2
      [[ $new != default ]] || new=
      set_env_value "$key" "$new"
      echo "$1 limit: ${old:-default}${old:+%} -> ${new:-default}${new:+%}"
      shift 2
    done
    restart_server
    admin -T resources || true
    ;;
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
