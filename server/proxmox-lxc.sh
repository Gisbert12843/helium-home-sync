#!/usr/bin/env bash
# Helium Home Sync: install the server into a Proxmox VE LXC container (no Docker).
# Run on the Proxmox host as root. './proxmox-lxc.sh help' lists the commands and settings.
# The files it installs and the steps that run inside the container live in proxmox/.
set -Eeuo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
RES=$HERE/proxmox
APP="Helium Home Sync"
SVC=helium-home-sync
STAGE=/tmp/helium-home-sync
BACKTITLE="$APP · Proxmox VE LXC installer"
BUNDLE=(server.py admin.py schema.sql manage.sh text proxmox)

# ---------------------------------------------------------------- output

if [[ -t 1 ]]; then
  YW=$'\e[33m' YWB=$'\e[93m' BL=$'\e[36m' RD=$'\e[01;31m' GN=$'\e[1;92m' DGN=$'\e[32m'
  BGN=$'\e[4;92m' BOLD=$'\e[1m' DIM=$'\e[2m' CL=$'\e[m' BFR=$'\r\e[K'
else
  YW= YWB= BL= RD= GN= DGN= BGN= BOLD= DIM= CL= BFR=
fi
TAB="  "
CM="${TAB}✔️${TAB}" CROSS="${TAB}✖️${TAB}" INFO="${TAB}💡${TAB}" WARN="${TAB}⚠️${TAB}"
INTERACTIVE=no; [[ -t 0 && -t 1 ]] && INTERACTIVE=yes
SPINNER_PID=

norm_bool() {
  local v=${!1}
  case ${v,,} in
    y|yes|1|true|on) printf -v "$1" yes ;;
    n|no|0|false|off) printf -v "$1" no ;;
    *) die "$1 must be yes or no, not '$v'." ;;
  esac
}

VERBOSE=${VERBOSE:-no}

spinner() {
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0
  while :; do
    printf '\r %s%s%s' "$YWB" "${frames[i]}" "$CL"
    i=$(((i + 1) % ${#frames[@]}))
    sleep 0.1
  done
}

stop_spinner() {
  [[ -n $SPINNER_PID ]] || return 0
  kill "$SPINNER_PID" 2>/dev/null || true
  wait "$SPINNER_PID" 2>/dev/null || true
  SPINNER_PID=
  printf '\e[?25h'
}

msg_info() {
  stop_spinner
  if [[ $VERBOSE == yes || ! -t 1 ]]; then
    printf '%s%s%s%s\n' "$TAB" "$YW" "$1" "$CL"
  else
    printf '%s%s%s%s\e[?25l' "$TAB" "$YW" "$1" "$CL"
    spinner &
    SPINNER_PID=$!
  fi
}
msg_ok() { stop_spinner; printf '%s%s%s%s%s\n' "$BFR" "$CM" "$GN" "$1" "$CL"; }
msg_warn() { stop_spinner; printf '%s%s%s%s%s\n' "$BFR" "$WARN" "$YW" "$1" "$CL" >&2; }
msg_error() { stop_spinner; printf '%s%s%s%s%s\n' "$BFR" "$CROSS" "$RD" "$1" "$CL" >&2; }
die() { msg_error "$*"; exit 1; }

# Run a command quietly (its output goes to $LOG), or visibly with VERBOSE=yes.
run() {
  if [[ $VERBOSE == yes ]]; then "$@"; return; fi
  "$@" >"$LOG" 2>&1 && : >"$LOG"
}

show_log() {
  [[ -s ${LOG:-} ]] || return 0
  printf '%sLast lines of the output:%s\n' "$DIM" "$CL" >&2
  tail -n 20 "$LOG" | sed 's/^/    /' >&2
  : >"$LOG"
}

on_error() {
  local rc=$1 line=$2 cmd=$3
  ((BASH_SUBSHELL == 0)) || exit "$rc"
  msg_error "[ERROR] in line $line: exit code $rc: while executing: $cmd"
  show_log
  exit "$rc"
}

header_info() {
  if [[ $INTERACTIVE == yes ]]; then clear
  elif [[ -n ${HEADER_SHOWN:-} ]]; then return
  fi
  HEADER_SHOWN=1
  printf '%s%s%s\n\n' "$BL" "$(<"$RES/header.txt")" "$CL"
}

# Print a text file, replacing {{NAME}} with the value of $NAME.
render() {
  local line name
  while IFS= read -r line || [[ -n $line ]]; do
    while [[ $line =~ \{\{([A-Za-z_]+)\}\} ]]; do
      name=${BASH_REMATCH[1]}
      line=${line//"{{$name}}"/${!name-}}
    done
    printf '%s\n' "$line"
  done <"$1"
}

row() { printf '%s%s%s%s%s: %s%s%s\n' "$TAB" "$1" "$TAB" "$BOLD$DGN" "$2" "$BGN" "$3" "$CL"; }

TMP=$(mktemp -d)
LOG=$TMP/run.log
trap 'stop_spinner; rm -rf "$TMP"' EXIT
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------- dialogs

wt() { whiptail --backtitle "$BACKTITLE" "$@" 3>&1 1>&2 2>&3; }

exit_script() {
  clear
  printf '\n%s%sUser exited script%s\n\n' "$CROSS" "$RD" "$CL"
  exit 0
}

# The rules for free-text settings, shared by the dialogs and the checks of environment variables.
IPV4='((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])'
declare -A RULE=(
  [CTID]='^[1-9][0-9]{2,8}$'
  [CT_HOSTNAME]='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
  [DISK]='^[1-9][0-9]*$'
  [CORES]='^[1-9][0-9]?$'
  [MEMORY]='^[1-9][0-9]+$'
  [SWAP]='^[0-9]+$'
  [TAGS]='^[A-Za-z0-9_.;+-]*$'
  [IP]="^(dhcp|$IPV4/([0-9]|[12][0-9]|3[0-2]))$"
  [GW]="^($IPV4)?$"
  [VLAN]='^([1-9][0-9]{0,2}|[1-3][0-9]{3}|40[0-8][0-9]|409[0-4])?$'
  [NAMESERVER]='^[0-9A-Fa-f.: ]*$'
  [SEARCHDOMAIN]='^[A-Za-z0-9. -]*$'
  [PORT]='^([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$'
  [SYNC_TOKEN]='^([A-Za-z0-9_.~+/=-]{16,})?$'
  [BACKUP_TIME]='^([01][0-9]|2[0-3]):[0-5][0-9]$'
  [BACKUP_KEEP]='^[1-9][0-9]{0,3}$'
  [MONITOR_URL]='^(https?://[^[:space:]|&\\]+)?$'
  [LIMIT_DISK]='^([1-9][0-9]?|100)$'
  [LIMIT_MEMORY]='^([1-9][0-9]?|100)$'
  [LIMIT_SWAP]='^([1-9][0-9]?|100)$'
)
declare -A HINT=(
  [CTID]="a number from 100 to 999999999"
  [CT_HOSTNAME]="letters, digits and '-' (at most 63, not starting or ending with '-')"
  [DISK]="a whole number of GB, e.g. 2"
  [CORES]="a number from 1 to 99"
  [MEMORY]="a number of MB, e.g. 512"
  [SWAP]="a number of MB, 0 for none"
  [TAGS]="tags separated by ';', made of letters, digits and _ . + -"
  [IP]="'dhcp' or an address with prefix, e.g. 192.168.2.50/24"
  [GW]="an IPv4 address like 192.168.2.1, or empty"
  [VLAN]="a number from 1 to 4094, or empty"
  [NAMESERVER]="IP addresses separated by spaces, or empty"
  [SEARCHDOMAIN]="a domain like home.arpa, or empty"
  [PORT]="a number from 1 to 65535"
  [SYNC_TOKEN]="at least 16 characters of A-Z a-z 0-9 _ . ~ + / = -"
  [BACKUP_TIME]="a time like 03:30 (HH:MM, 24 hours)"
  [BACKUP_KEEP]="a number from 1 to 9999"
  [MONITOR_URL]="a URL like https://hc-ping.com/<uuid>, or empty"
  [LIMIT_DISK]="a percentage from 1 to 100"
  [LIMIT_MEMORY]="a percentage from 1 to 100"
  [LIMIT_SWAP]="a percentage from 1 to 100"
)

# ask_input VAR TITLE TEXT: input box, repeated until the answer follows RULE[VAR]
ask_input() {
  local _var=$1 _title=$2 _text=$3 _reply _rule=${RULE[$1]:-}
  while :; do
    _reply=$(wt --title "$_title" --inputbox "$_text" 10 76 "${!_var}") || exit_script
    if [[ -z $_rule || $_reply =~ $_rule ]]; then
      printf -v "$_var" '%s' "$_reply"
      return
    fi
    wt --title "$_title" --msgbox "\"$_reply\" is not valid.\n\nUse ${HINT[$_var]}." 10 76 || true
  done
}

# ask_yesno VAR TITLE TEXT: the current value (yes or no) is the default button
ask_yesno() {
  local _var=$1 _rc=0 _opts=()
  [[ ${!_var} == yes ]] || _opts=(--defaultno)
  wt --title "$2" "${_opts[@]}" --yesno "$3" 10 76 || _rc=$?
  case $_rc in
    0) printf -v "$_var" yes ;;
    1) printf -v "$_var" no ;;
    *) exit_script ;;
  esac
}

# ask_choice VAR TITLE TEXT VALUE DESCRIPTION...: radio list of every possible value
ask_choice() {
  local _var=$1 _title=$2 _text=$3 _items=() _n _reply
  shift 3
  while (($# >= 2)); do
    _items+=("$1" "$2" "$([[ $1 == "${!_var}" ]] && echo ON || echo OFF)")
    shift 2
  done
  _n=$((${#_items[@]} / 3))
  ((_n <= 8)) || _n=8
  while :; do
    _reply=$(wt --title "$_title" --radiolist "$_text\n\nArrow keys move, Space selects, Enter confirms." \
      $((_n + 11)) 78 "$_n" "${_items[@]}") || exit_script
    [[ -z $_reply ]] || break
  done
  printf -v "$_var" '%s' "$_reply"
}

# ask_secret VAR TITLE TEXT: password box; Enter keeps the current value
ask_secret() {
  local _reply
  _reply=$(wt --title "$2" --passwordbox "$3" 10 76) || exit_script
  [[ -z $_reply ]] || printf -v "$1" '%s' "$_reply"
}

# ---------------------------------------------------------------- host facts

storages() { pvesm status -content "$1" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}' || true; }
bridges() { ip -br link show type bridge 2>/dev/null | awk '{print $1}' || true; }
templates() {
  { pveam available --section system 2>/dev/null | awk '{print $2}'
    pveam list "${TEMPLATE_STORAGE:-local}" 2>/dev/null | awk 'NR>1 {sub(".*/", "", $1); print $1}'
  } | grep -E '^debian-[0-9]+-standard_.*_amd64\.tar\.(zst|gz|xz)$' | sort -Vru || true
}
template_label() { local v=${1#debian-*-standard_}; echo "Debian ${v%%_*}"; }
preferred() { grep -x -m1 -- "$2" <<<"$1" || head -n1 <<<"$1"; }
count() { [[ -n $1 ]] && wc -l <<<"$1" || echo 0; }

# one_of NAME VALUE ALLOWED...: stop unless VALUE is one of ALLOWED
one_of() {
  local name=$1 value=$2 v
  shift 2
  for v; do [[ $v == "$value" ]] && return 0; done
  die "$name must be one of: $* (not '$value')."
}

storage_items() {
  local -n _out=$2
  local name desc
  _out=()
  while IFS=$'\t' read -r name desc; do _out+=("$name" "$desc"); done < <(
    pvesm status -content "$1" 2>/dev/null |
      awk 'NR>1 && $3=="active" {printf "%s\t%-8s %8.1f GB free of %.1f GB\n", $1, $2, $6/1048576, $4/1048576}' || true)
}

bridge_items() {
  # shellcheck disable=SC2178 # nameref to the caller's array
  local -n _out=$1
  local name addr
  _out=()
  while read -r name; do
    addr=$(ip -4 -br addr show dev "$name" 2>/dev/null | awk '{print $3}' || true)
    _out+=("$name" "${addr:-no IPv4 address on the host}")
  done <<<"$BRIDGES"
}

template_items() {
  # shellcheck disable=SC2178 # nameref to the caller's array
  local -n _out=$1
  local t
  _out=()
  while read -r t; do [[ -z $t ]] || _out+=("$t" "$(template_label "$t")"); done <<<"$TEMPLATES"
}

# pick_container VAR TITLE: choose from all containers, Helium Home Sync ones preselected
pick_container() {
  local _var=$1 _items=() _id _status _name _desc
  while read -r _id _status _name; do
    _desc="$_name ($_status)"
    if [[ $_name == *helium* ]] || grep -qiE 'helium-home-sync|helium home sync' "/etc/pve/lxc/$_id.conf" 2>/dev/null; then
      _desc+=" - $APP"
      [[ -n ${!_var} ]] || printf -v "$_var" '%s' "$_id"
    fi
    _items+=("$_id" "$_desc")
  done < <(pct list 2>/dev/null | awk 'NR>1 {print $1, $2, $NF}')
  ((${#_items[@]})) || die "There are no LXC containers on this host."
  ask_choice "$_var" "$2" "Choose the container" "${_items[@]}"
}

check_host() {
  [[ $EUID -eq 0 ]] || die "Run this as root on the Proxmox host."
  command -v pct >/dev/null || die "pct not found. Run this on the Proxmox host, not inside a VM or container."
  [[ $(dpkg --print-architecture 2>/dev/null) == amd64 ]] || die "This needs an amd64 Proxmox host."
  [[ $INTERACTIVE == no ]] || command -v whiptail >/dev/null || die "whiptail not found: apt install whiptail"
  local f
  for f in "${BUNDLE[@]}"; do [[ -e $HERE/$f ]] || die "$HERE/$f is missing. Copy the whole server/ folder."; done
}

TUN_HELP="The Proxmox host has no usable /dev/net/tun, which Tailscale needs. Load the module on the host:
  modprobe tun && echo tun >/etc/modules-load.d/tun.conf
then run this again."

DOCS=https://github.com/Gisbert12843/helium-home-sync/blob/main/OPERATIONS.md
ALERTS_HELP="Alerts are optional. Every 5 minutes a health check tests the server, its disk, memory
and swap, and the daily backups. It reports to Healthchecks.io (free). When a check fails,
or the reports stop because the host is down, Healthchecks.io emails or messages you.

1. Sign up at https://healthchecks.io and click 'Add Check'.
2. Set the period to 5 minutes and the grace time to 30 minutes.
3. Copy the check's ping URL, e.g. https://hc-ping.com/<uuid>.

Paste it in the next box. Leave the box empty for no alerts."
DASHBOARD_HELP="Make a read-only status token for dashboards such as Homepage or Homarr?

It can only read usage and counts from /api/stats, never your history."

host_tun_ok() {
  [[ -c /dev/net/tun ]] || modprobe tun 2>/dev/null || true
  [[ -c /dev/net/tun && $(stat -c '%t:%T' /dev/net/tun) == a:c8 ]]
}

# ---------------------------------------------------------------- container helpers

ct_exec() {
  local ct=$1
  shift
  pct exec "$ct" -- env LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

ct_install() {
  local ct=$1
  shift
  ct_exec "$ct" bash "$STAGE/proxmox/install.sh" "$@"
}

# Copy the server code, texts and proxmox/ files into the container's $STAGE.
push_bundle() {
  tar -C "$HERE" -czf "$TMP/bundle.tgz" "${BUNDLE[@]}"
  pct push "$1" "$TMP/bundle.tgz" "$STAGE.tgz"
  ct_exec "$1" sh -c "rm -rf $STAGE && mkdir -p $STAGE && tar -xzf $STAGE.tgz -C $STAGE && rm -f $STAGE.tgz"
}

drop_bundle() { ct_exec "$1" rm -rf "$STAGE" || true; }

ct_port() {
  local p
  p=$(ct_exec "$1" sh -c "sed -n 's/^PORT=//p' /etc/helium-home-sync/env 2>/dev/null | tail -n1" || true)
  echo "${p:-8787}"
}

ct_running() { [[ $(pct status "$1" 2>/dev/null) == *running* ]]; }

# ct_env CT KEY: a value from the container's /etc/helium-home-sync/env
ct_env() { ct_exec "$1" sh -c "sed -n 's/^$2=//p' /etc/helium-home-sync/env | tail -n1" || true; }

# ct_show CT TITLE CMD...: run a command in the container and show its output in a box
ct_show() {
  local ct=$1 title=$2 out
  shift 2
  out=$(ct_exec "$ct" "$@" 2>&1) || true
  wt --title "$title" --msgbox "$out" 20 78 || true
}

wait_healthy() {
  local i
  for i in $(seq 1 20); do
    ct_exec "$1" curl -fsS -m 3 "http://127.0.0.1:$2/api/health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

wait_network() {
  local i
  for i in $(seq 1 60); do
    ct_exec "$1" getent hosts deb.debian.org >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

ct_has_tun_config() {
  grep -qE '^(dev[0-9]+: (path=)?/dev/net/tun|lxc\.mount\.entry: /dev/net/tun)' <<<"$(pct config "$1")"
}

pass_tun() {
  local ct=$1 n conf=/etc/pve/lxc/$1.conf
  ct_has_tun_config "$ct" && return 0
  msg_info "Passing /dev/net/tun into container $ct"
  if [[ $(pct help set --verbose 2>/dev/null) == *'--dev[n]'* ]]; then
    for n in $(seq 0 255); do grep -q "^dev$n:" <<<"$(pct config "$ct")" || break; done
    run pct set "$ct" "-dev$n" /dev/net/tun
  else
    grep -q '^\[' "$conf" && die "Container $ct has snapshots, so its config can't be extended safely. Add these lines
above the first [snapshot] section of $conf, then run this again:
  lxc.cgroup2.devices.allow: c 10:200 rwm
  lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"
    printf '%s\n' 'lxc.cgroup2.devices.allow: c 10:200 rwm' \
      'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' >>"$conf"
  fi
  msg_ok "Passed /dev/net/tun into container $ct"
}

ts_state() {
  ct_exec "$1" sh -c 'tailscale status --json 2>/dev/null |
    python3 -c "import json, sys; print(json.load(sys.stdin).get(\"BackendState\", \"\"))"' 2>/dev/null || true
}

# setup_tailscale CTID PORT: install, log in, optionally serve HTTPS. The bundle must be pushed.
setup_tailscale() {
  local ct=$1 port=$2 name i
  if ! ct_exec "$ct" test -c /dev/net/tun; then
    msg_warn "Container $ct has no /dev/net/tun yet. Restart it (pct reboot $ct), then: $HERE/proxmox-lxc.sh tailscale $ct"
    return 1
  fi
  msg_info "Installing Tailscale"
  if ! run ct_install "$ct" tailscale; then
    msg_error "Tailscale install failed."
    show_log
    return 1
  fi
  for i in $(seq 1 15); do [[ -n $(ts_state "$ct") ]] && break; sleep 1; done
  if [[ -z $(ts_state "$ct") ]]; then
    msg_error "tailscaled does not start. Check: pct exec $ct -- journalctl -u tailscaled"
    return 1
  fi
  msg_ok "Installed Tailscale"

  name=$(pct config "$ct" | sed -n 's/^hostname: //p')
  if [[ $(ts_state "$ct") != Running ]]; then
    if [[ -n ${TS_AUTHKEY:-} ]]; then
      msg_info "Joining your tailnet with the auth key"
      printf '%s' "$TS_AUTHKEY" >"$TMP/tskey"
      pct push "$ct" "$TMP/tskey" /root/.tailscale-authkey --perms 0600
      run ct_exec "$ct" tailscale up --auth-key=file:/root/.tailscale-authkey --hostname="$name" || true
      ct_exec "$ct" rm -f /root/.tailscale-authkey
    elif [[ $INTERACTIVE == yes ]]; then
      printf '%s%sLog in to Tailscale: open the link below (Ctrl+C skips; the server keeps running either way)%s\n' \
        "$INFO" "$YW" "$CL"
      trap 'echo; echo "${DIM}(skipped)${CL}"' INT
      ct_exec "$ct" tailscale up --hostname="$name" || true
      trap - INT
    fi
  fi
  if [[ $(ts_state "$ct") != Running ]]; then
    msg_warn "Tailscale is installed but not logged in. Log in later: pct exec $ct -- tailscale up"
    return 0
  fi
  msg_ok "Tailscale connected as $(ct_exec "$ct" tailscale ip -4 2>/dev/null | head -n1)"

  if [[ ${TS_HTTPS:-no} == yes ]]; then
    msg_info "Serving HTTPS through Tailscale"
    if run timeout 180 pct exec "$ct" -- env PATH=/usr/sbin:/usr/bin:/sbin:/bin tailscale serve --bg "$port"; then
      msg_ok "Serving HTTPS through Tailscale"
    else
      msg_warn "tailscale serve failed. Turn on HTTPS for your tailnet (admin console > DNS), then: pct exec $ct -- tailscale serve --bg $port"
    fi
  fi
}

# Tailscale questions shared by the advanced settings and the tailscale command.
ask_tailscale_login() {
  local login=link
  [[ -z $TS_AUTHKEY ]] || login=authkey
  ask_choice login "TAILSCALE LOGIN" "How should the container join your tailnet?" \
    link "Show a login link at the end of the install" \
    authkey "Use an auth key from the Tailscale admin console"
  if [[ $login == authkey ]]; then
    while :; do
      ask_secret TS_AUTHKEY "TAILSCALE AUTH KEY" "Paste the auth key (tskey-...)${TS_AUTHKEY:+\nEnter keeps the current one.}"
      [[ $TS_AUTHKEY == tskey-* ]] && break
      wt --title "TAILSCALE AUTH KEY" --msgbox "Auth keys start with 'tskey-'." 8 60 || true
    done
  else
    TS_AUTHKEY=
  fi
  ask_yesno TS_HTTPS "TAILSCALE HTTPS" \
    "Also serve HTTPS at https://${1:-<name>}.<tailnet>.ts.net via 'tailscale serve'?\n\nThis needs HTTPS turned on for your tailnet (admin console > DNS)."
}

# ---------------------------------------------------------------- create: settings

load_settings() {
  ROOTDIR_STORAGES=$(storages rootdir)
  TEMPLATE_STORAGES=$(storages vztmpl)
  BRIDGES=$(bridges)
  [[ -n $ROOTDIR_STORAGES ]] || die "No active storage for container disks found (pvesm status -content rootdir)."
  [[ -n $TEMPLATE_STORAGES ]] || die "No active storage for templates found (pvesm status -content vztmpl)."

  CTID=${CTID:-$(pvesh get /cluster/nextid)}
  CT_HOSTNAME=${CT_HOSTNAME:-helium-home-sync}
  CT_TYPE=${CT_TYPE:-unprivileged}
  STORAGE=${STORAGE:-}
  TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-}
  TEMPLATE=${TEMPLATE:-}
  DISK=${DISK:-2}
  CORES=${CORES:-1}
  MEMORY=${MEMORY:-}
  SWAP=${SWAP:-256}
  TAGS=${TAGS:-helium}
  ONBOOT=${ONBOOT:-yes}
  PROTECTION=${PROTECTION:-no}
  BRIDGE=${BRIDGE:-$(preferred "$BRIDGES" vmbr0)}
  BRIDGE=${BRIDGE:-vmbr0}
  IP=${IP:-dhcp}
  GW=${GW:-}
  VLAN=${VLAN:-}
  NAMESERVER=${NAMESERVER:-}
  SEARCHDOMAIN=${SEARCHDOMAIN:-}
  PORT=${PORT:-8787}
  SYNC_TOKEN=${SYNC_TOKEN:-}
  PASSWORD=${PASSWORD:-}
  SSH_KEYS=${SSH_KEYS:-}
  AUTO_BACKUP=${AUTO_BACKUP:-yes}
  BACKUP_TIME=${BACKUP_TIME:-03:30}
  BACKUP_KEEP=${BACKUP_KEEP:-14}
  MONITOR_URL=${MONITOR_URL:-}
  DASHBOARD=${DASHBOARD:-no}
  AUTO_UPDATES=${AUTO_UPDATES:-yes}
  QUIET=${QUIET:-no}
  TAILSCALE=${TAILSCALE:-no}
  TS_AUTHKEY=${TS_AUTHKEY:-}
  TS_HTTPS=${TS_HTTPS:-no}
  local v
  for v in ONBOOT PROTECTION AUTO_BACKUP DASHBOARD AUTO_UPDATES QUIET TAILSCALE TS_HTTPS; do norm_bool "$v"; done
}

# choose_storages ALWAYS_ASK: fill STORAGE and TEMPLATE_STORAGE; ask when there is a choice
choose_storages() {
  local items=()
  if [[ -z $TEMPLATE_STORAGE || $1 == yes ]]; then
    TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-$(preferred "$TEMPLATE_STORAGES" local)}
    if [[ $INTERACTIVE == yes && $(count "$TEMPLATE_STORAGES") -gt 1 ]]; then
      storage_items vztmpl items
      ask_choice TEMPLATE_STORAGE "TEMPLATE STORAGE" "Choose where the Debian template is kept" "${items[@]}"
    fi
  fi
  if [[ -z $STORAGE || $1 == yes ]]; then
    STORAGE=${STORAGE:-$(preferred "$ROOTDIR_STORAGES" local-lvm)}
    if [[ $INTERACTIVE == yes && $(count "$ROOTDIR_STORAGES") -gt 1 ]]; then
      storage_items rootdir items
      ask_choice STORAGE "CONTAINER STORAGE" "Choose the storage for the container's root disk" "${items[@]}"
    fi
  fi
}

default_memory() { [[ $TAILSCALE == yes ]] && echo 512 || echo 256; }

advanced_settings() {
  local items=() ip_mode token_mode ssh_mode rc host_keys=/root/.ssh/authorized_keys
  while :; do
    header_info
    printf '%s🧩%s%s%sUsing Advanced Settings%s\n' "$TAB" "$TAB" "$BOLD" "$RD" "$CL"

    # Container
    ask_choice CT_TYPE "CONTAINER TYPE" "Choose the container type" \
      unprivileged "Unprivileged (recommended)" \
      privileged "Privileged"
    while :; do
      ask_input CTID "CONTAINER ID" "Set the container ID"
      pct status "$CTID" >/dev/null 2>&1 || break
      wt --title "CONTAINER ID" --msgbox "Container $CTID already exists. Choose another ID." 8 60 || true
      CTID=$(pvesh get /cluster/nextid)
    done
    ask_input CT_HOSTNAME "HOSTNAME" "Set the hostname"
    TEMPLATE=${TEMPLATE:-$(head -n1 <<<"$TEMPLATES")}
    template_items items
    ((${#items[@]})) || die "No Debian template found in 'pveam available'."
    ask_choice TEMPLATE "OPERATING SYSTEM" "Choose the Debian version" "${items[@]}"
    choose_storages yes
    ask_input TAGS "TAGS" "Set tags, separated by ';' (empty: none)"
    ask_yesno ONBOOT "START ON BOOT" "Start the container with the Proxmox host?"
    ask_yesno PROTECTION "PROTECTION" "Protect the container against accidental deletion?"

    # Network
    bridge_items items
    ((${#items[@]})) || items=("$BRIDGE" "the only bridge known")
    ask_choice BRIDGE "BRIDGE" "Choose the network bridge" "${items[@]}"
    ip_mode=static
    [[ $IP != dhcp ]] || ip_mode=dhcp
    ask_choice ip_mode "IPv4" "How does the container get its IPv4 address?" \
      dhcp "Automatic (DHCP)" \
      static "Static address"
    if [[ $ip_mode == dhcp ]]; then
      IP=dhcp GW=
    else
      [[ $IP != dhcp ]] || IP=
      while :; do
        ask_input IP "IPv4 ADDRESS" "Set the IPv4 address with prefix, e.g. 192.168.2.50/24"
        [[ $IP != dhcp ]] && break
      done
      ask_input GW "GATEWAY" "Set the gateway, e.g. 192.168.2.1 (empty: none)"
    fi
    ask_input VLAN "VLAN" "Set a VLAN tag (empty: none)"
    ask_input NAMESERVER "DNS SERVERS" "Set DNS servers, separated by spaces (empty: same as the host)"
    ask_input SEARCHDOMAIN "DNS SEARCH DOMAIN" "Set the DNS search domain (empty: same as the host)"
    ask_input PORT "PORT" "Set the port the server listens on"

    # Login
    token_mode=random
    [[ -z $SYNC_TOKEN ]] || token_mode=custom
    ask_choice token_mode "SYNC TOKEN" "The sync token is what each browser enters to connect." \
      random "Generate a new random token (recommended)" \
      custom "Enter my own token"
    if [[ $token_mode == custom ]]; then
      while :; do
        ask_input SYNC_TOKEN "SYNC TOKEN" "Enter the token (${HINT[SYNC_TOKEN]})"
        [[ -n $SYNC_TOKEN ]] && break
      done
    else
      SYNC_TOKEN=
    fi
    ask_password
    items=(none "No SSH login (use 'pct enter')")
    [[ ! -s $host_keys ]] || items+=("$host_keys" "The keys that may SSH into this host")
    items+=(file "Another file with public keys")
    case $SSH_KEYS in
      '') ssh_mode=none ;;
      "$host_keys") ssh_mode=$host_keys ;;
      *) ssh_mode='file' ;;
    esac
    ask_choice ssh_mode "SSH KEYS" "Who may SSH into the container as root?" "${items[@]}"
    case $ssh_mode in
      none) SSH_KEYS= ;;
      file)
        [[ $SSH_KEYS != "$host_keys" ]] || SSH_KEYS=
        while :; do
          ask_input SSH_KEYS "SSH KEYS" "Path to a file with SSH public keys"
          [[ -s $SSH_KEYS ]] && break
          wt --title "SSH KEYS" --msgbox "${SSH_KEYS:-That file} is missing or empty." 8 60 || true
        done
        ;;
      *) SSH_KEYS=$ssh_mode ;;
    esac

    # Tailscale
    ask_yesno TAILSCALE "TAILSCALE" \
      "Install Tailscale?\n\nIt lets your devices reach the server at home and away, without opening ports."
    if [[ $TAILSCALE == yes ]]; then
      if host_tun_ok; then
        ask_tailscale_login "$CT_HOSTNAME"
      else
        wt --title "TAILSCALE" --msgbox "$TUN_HELP" 12 76 || true
        TAILSCALE=no
      fi
    fi

    # Maintenance
    ask_yesno AUTO_BACKUP "BACKUPS" "Back up the database every day?"
    if [[ $AUTO_BACKUP == yes ]]; then
      ask_input BACKUP_TIME "BACKUP TIME" "Time of the daily backup (HH:MM)"
      ask_input BACKUP_KEEP "BACKUPS TO KEEP" "How many daily backups to keep. Older ones are deleted."
    fi
    wt --title "ALERTS (OPTIONAL)" --msgbox "$ALERTS_HELP" 16 78 || true
    ask_input MONITOR_URL "ALERTS (OPTIONAL)" "Paste your Healthchecks.io ping URL (empty: no alerts)"
    ask_yesno DASHBOARD "DASHBOARD TOKEN (OPTIONAL)" "$DASHBOARD_HELP"
    ask_yesno AUTO_UPDATES "SECURITY UPDATES" "Install Debian security updates automatically?"
    ask_yesno QUIET "QUIET LOG" "Quiet log: don't log every sync request?"

    # Resources
    [[ -n $MEMORY ]] || MEMORY=$(default_memory)
    [[ $TAILSCALE == no || $MEMORY -ge 512 ]] || MEMORY=512
    ask_input DISK "DISK SIZE" "Set the disk size in GB"
    ask_input CORES "CORE COUNT" "Allocate CPU cores"
    ask_input MEMORY "RAM" "Allocate RAM in MB (Tailscale needs about 100 MB more)"
    ask_input SWAP "SWAP" "Allocate swap in MB (0: none)"
    ask_yesno VERBOSE "VERBOSE MODE" "Show the output of every command while installing?"

    header_info
    printf '%s🧩%s%s%sUsing Advanced Settings%s\n' "$TAB" "$TAB" "$BOLD" "$RD" "$CL"
    show_settings
    rc=0
    wt --title "ADVANCED SETTINGS COMPLETE" --yesno "Ready to create a $APP LXC?\n\nNo: go through the settings again." 10 60 || rc=$?
    case $rc in 0) break ;; 1) ;; *) exit_script ;; esac
  done
  validate
}

ask_password() {
  local pw1 pw2 keep=
  [[ -z $PASSWORD ]] || keep="\nEnter keeps the password from the PASSWORD variable."
  while :; do
    pw1=$(wt --title "ROOT PASSWORD" --passwordbox \
      "Set a root password for the container.\nLeave it blank for none: 'pct enter' works without one.$keep" 11 76) || exit_script
    [[ -n $pw1 ]] || return 0
    pw2=$(wt --title "ROOT PASSWORD" --passwordbox "Enter the password again" 9 76) || exit_script
    if [[ $pw1 == "$pw2" ]]; then
      PASSWORD=$pw1
      return
    fi
    wt --title "ROOT PASSWORD" --msgbox "The passwords don't match. Try again." 8 60 || true
  done
}

show_settings() {
  local ts=no backups=off
  if [[ $TAILSCALE == yes ]]; then
    ts="yes, ${TS_AUTHKEY:+auth key}${TS_AUTHKEY:-login link}"
    [[ $TS_HTTPS == no ]] || ts+=", HTTPS via tailscale serve"
  fi
  [[ $AUTO_BACKUP == no ]] || backups="daily at $BACKUP_TIME, keep the newest $BACKUP_KEEP"
  row 🆔 "Container ID" "$CTID"
  row 🏠 "Hostname" "$CT_HOSTNAME"
  row 📦 "Container type" "$CT_TYPE"
  row 🖥️ "Operating system" "$(template_label "$TEMPLATE") ($TEMPLATE on $TEMPLATE_STORAGE)"
  row 💾 "Disk" "$DISK GB on $STORAGE"
  row 🧠 "CPU cores" "$CORES"
  row 🛠️ "RAM" "$MEMORY MB + $SWAP MB swap"
  row 🌉 "Bridge" "$BRIDGE${VLAN:+, VLAN $VLAN}"
  row 📡 "IPv4" "$IP${GW:+, gateway $GW}"
  row 🌐 "DNS" "${NAMESERVER:-same as the host}${SEARCHDOMAIN:+, search $SEARCHDOMAIN}"
  row 🔌 "Port" "$PORT"
  row 🔐 "Sync token" "${SYNC_TOKEN:+your own}${SYNC_TOKEN:-new random token}"
  row 🔑 "Root login" "password ${PASSWORD:+set}${PASSWORD:-none}, SSH keys ${SSH_KEYS:-none}"
  row 🔗 "Tailscale" "$ts"
  row 🗄️ "Backups" "$backups"
  row 🚨 "Alerts" "$([[ -z $MONITOR_URL ]] && echo off || echo "health check every 5 min, reports to $(cut -d/ -f3 <<<"$MONITOR_URL")")"
  row 📊 "Dashboard token" "$([[ $DASHBOARD == yes ]] && echo "yes (read-only)" || echo no)"
  row 🔄 "Security updates" "$([[ $AUTO_UPDATES == yes ]] && echo automatic || echo manual)"
  row ⚙️ "Options" "start with host $ONBOOT, protected $PROTECTION, quiet log $QUIET, verbose $VERBOSE"
  row 🏷️ "Tags" "${TAGS:-none}"
}

validate() {
  local v
  [[ -n $MEMORY ]] || MEMORY=$(default_memory)
  for v in "${!RULE[@]}"; do
    [[ ${!v} =~ ${RULE[$v]} ]] || die "$v must be ${HINT[$v]} (not '${!v}')."
  done
  [[ $IP != dhcp ]] || GW=
  pct status "$CTID" >/dev/null 2>&1 && die "Container $CTID already exists. Pick another with CTID=..."
  one_of CT_TYPE "$CT_TYPE" unprivileged privileged
  # shellcheck disable=SC2086 # the lists are newline separated names
  {
    one_of STORAGE "$STORAGE" $ROOTDIR_STORAGES
    one_of TEMPLATE_STORAGE "$TEMPLATE_STORAGE" $TEMPLATE_STORAGES
    [[ -z $BRIDGES ]] || one_of BRIDGE "$BRIDGE" $BRIDGES
  }
  [[ -n $TEMPLATES ]] || die "No Debian template found in 'pveam available'. Check the host's internet access."
  grep -qxF -- "$TEMPLATE" <<<"$TEMPLATES" || die "TEMPLATE must be one of:
$TEMPLATES"
  [[ -z $SSH_KEYS || -s $SSH_KEYS ]] || die "SSH_KEYS: $SSH_KEYS is missing or empty."
  [[ $TAILSCALE == no ]] || host_tun_ok || die "$TUN_HELP"
}

# ---------------------------------------------------------------- create: build

create_container() {
  local ct=$CTID net pkgs=() opts
  [[ -n $SYNC_TOKEN ]] || SYNC_TOKEN=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))' 2>/dev/null ||
    head -c 32 /dev/urandom | base64 | tr -d '/+=\n')
  net="name=eth0,bridge=$BRIDGE,ip=$IP${GW:+,gw=$GW}${VLAN:+,tag=$VLAN}"

  if [[ $(pveam list "$TEMPLATE_STORAGE" 2>/dev/null) != *"/$TEMPLATE"* ]]; then
    msg_info "Downloading LXC template $TEMPLATE"
    run pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
    msg_ok "Downloaded LXC template $TEMPLATE"
  fi

  msg_info "Creating LXC container $ct"
  opts=(--hostname "$CT_HOSTNAME" --ostype debian --features nesting=1
    --unprivileged "$([[ $CT_TYPE == unprivileged ]] && echo 1 || echo 0)"
    --cores "$CORES" --memory "$MEMORY" --swap "$SWAP" --rootfs "$STORAGE:$DISK"
    --net0 "$net" --onboot "$([[ $ONBOOT == yes ]] && echo 1 || echo 0)" --timezone host
    --description "$APP server. Manage with: pct exec $ct -- helium-home-sync")
  [[ -z $TAGS ]] || opts+=(--tags "$TAGS")
  [[ -z $NAMESERVER ]] || opts+=(--nameserver "$NAMESERVER")
  [[ -z $SEARCHDOMAIN ]] || opts+=(--searchdomain "$SEARCHDOMAIN")
  [[ -z $SSH_KEYS ]] || opts+=(--ssh-public-keys "$SSH_KEYS")
  [[ -z $PASSWORD ]] || opts+=(--password "$PASSWORD")
  run pct create "$ct" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" "${opts[@]}"
  msg_ok "Created LXC container $ct"
  [[ $TAILSCALE == no ]] || pass_tun "$ct"

  msg_info "Starting LXC container $ct"
  run pct start "$ct"
  msg_ok "Started LXC container $ct"

  msg_info "Waiting for the network"
  wait_network "$ct" || die "Container $ct has no network after 60 s. Check the bridge and IP, then: pct destroy $ct"
  msg_ok "Network in LXC is reachable"

  msg_info "Copying the server files into the container"
  push_bundle "$ct"
  msg_ok "Copied the server files into the container"

  [[ $AUTO_UPDATES == no ]] || pkgs+=(unattended-upgrades)
  msg_info "Updating the container OS and installing dependencies"
  run ct_install "$ct" packages "${pkgs[@]}"
  msg_ok "Updated the container OS and installed dependencies"
  if [[ $AUTO_UPDATES == yes ]]; then
    msg_info "Turning on automatic security updates"
    run ct_install "$ct" auto-updates
    msg_ok "Turned on automatic security updates"
  fi

  msg_info "Installing $APP"
  {
    printf 'SYNC_TOKEN=%s\nPORT=%s\n' "$SYNC_TOKEN" "$PORT"
    [[ $QUIET == no ]] || echo QUIET=1
  } >"$TMP/server.env"
  pct push "$ct" "$TMP/server.env" "$STAGE/server.env" --perms 0600
  run ct_install "$ct" server
  wait_healthy "$ct" "$PORT" || die "The server is not answering. Check: pct exec $ct -- journalctl -u $SVC"
  msg_ok "Installed $APP, answering on port $PORT"

  if [[ $AUTO_BACKUP == yes ]]; then
    msg_info "Scheduling a daily backup at $BACKUP_TIME"
    run ct_exec "$ct" helium-home-sync backups on "$BACKUP_TIME" "$BACKUP_KEEP"
    msg_ok "Scheduled a daily backup at $BACKUP_TIME, keeping the newest $BACKUP_KEEP"
  else
    run ct_exec "$ct" helium-home-sync backups off
  fi
  if [[ -n $MONITOR_URL ]]; then
    msg_info "Turning on alerts"
    run ct_exec "$ct" helium-home-sync monitor on "$MONITOR_URL"
    msg_ok "Turned on alerts: the health check reports to $(cut -d/ -f3 <<<"$MONITOR_URL") every 5 minutes"
  fi
  if [[ $DASHBOARD == yes ]]; then
    msg_info "Making a status token for dashboards"
    run ct_exec "$ct" sh -c 'echo yes | helium-home-sync status-token'
    msg_ok "Made a status token for dashboards (show it: pct exec $ct -- helium-home-sync status-token)"
  fi
  [[ $TAILSCALE == no ]] || setup_tailscale "$ct" "$PORT" || true
  if [[ $PROTECTION == yes ]]; then
    run pct set "$ct" --protection 1
    msg_ok "Protected the container against deletion"
  fi
  drop_bundle "$ct"

  msg_ok "Completed successfully!"
  echo
  printf '%s🚀%s%s%s setup has been successfully initialized!%s\n\n' "$TAB" "$TAB" "$GN" "$APP" "$CL"
  ct_exec "$ct" helium-home-sync connect
  echo
  printf '%s%sManage it from the Proxmox host:%s pct exec %s -- helium-home-sync [command]\n' "$INFO" "$YW" "$CL" "$ct"
  printf '%s%sOr inside the container:%s         pct enter %s, then: helium-home-sync\n' "$INFO" "$YW" "$CL" "$ct"
  printf '%s%sUpdate the code later:%s           %s/proxmox-lxc.sh update %s\n' "$INFO" "$YW" "$CL" "$HERE" "$ct"
  printf '%s%sBackups, alerts, dashboards:%s      %s/proxmox-lxc.sh settings %s\n' "$INFO" "$YW" "$CL" "$HERE" "$ct"
  printf '%s%sHow they work:%s                    %s\n' "$INFO" "$YW" "$CL" "$DOCS"
  [[ $TAILSCALE == yes ]] ||
    printf '%s%sAdd Tailscale later:%s             %s/proxmox-lxc.sh tailscale %s\n' "$INFO" "$YW" "$CL" "$HERE" "$ct"
}

# ---------------------------------------------------------------- commands

cmd_create() {
  local mode=$1 choice
  check_host
  [[ $mode != advanced || $INTERACTIVE == yes ]] ||
    die "The advanced settings ask questions. Run it in a terminal, or set the settings as environment variables."
  header_info
  load_settings
  msg_info "Updating the LXC template list"
  if run pveam update; then msg_ok "Updated the LXC template list"
  else msg_warn "The template list update failed; using the cached list."; fi
  TEMPLATES=$(templates)

  if [[ $mode == menu ]]; then
    mode=default
    if [[ $INTERACTIVE == yes ]]; then
      choice=$(wt --title "SETTINGS" --menu "This creates a new $APP LXC container.\n\nChoose an option:" 16 70 4 \
        1 "Default settings" \
        2 "Default settings with Tailscale" \
        3 "Advanced settings" \
        4 "Exit") || exit_script
      case $choice in
        2) TAILSCALE=yes ;;
        3) mode=advanced ;;
        4) exit_script ;;
      esac
    fi
  fi

  if [[ $mode == advanced ]]; then
    advanced_settings
  else
    [[ $TAILSCALE == no ]] || host_tun_ok || die "$TUN_HELP"
    TEMPLATE=${TEMPLATE:-$(head -n1 <<<"$TEMPLATES")}
    choose_storages no
    validate
    header_info
    printf '%s⚙️%s%s%sUsing Default Settings%s\n' "$TAB" "$TAB" "$BOLD" "$BL" "$CL"
    show_settings
  fi
  printf '%s🚀%s%sCreating a %s LXC using the above settings%s\n' "$TAB" "$TAB" "$BOLD" "$APP" "$CL"
  create_container
}

# target_container VAR CMD ARG: the container to work on, from the argument or picked from a list
target_container() {
  local -n _ct=$1
  _ct=$3
  if [[ -z $_ct ]]; then
    [[ $INTERACTIVE == yes ]] || die "Usage: ./proxmox-lxc.sh $2 <ctid>"
    pick_container "$1" "${2^^}"
  fi
  [[ $_ct =~ ^[0-9]+$ ]] || die "Usage: ./proxmox-lxc.sh $2 <ctid>"
  pct status "$_ct" >/dev/null 2>&1 || die "Container $_ct does not exist."
}

cmd_update() {
  local ct
  check_host
  target_container ct update "${1:-}"
  header_info
  ct_running "$ct" || die "Container $ct is not running (pct start $ct)."
  ct_exec "$ct" test -f /etc/helium-home-sync/env || die "Container $ct has no $APP install."

  msg_info "Copying the server files into container $ct"
  push_bundle "$ct"
  msg_ok "Copied the server files into container $ct"
  msg_info "Backing up the database"
  if run ct_exec "$ct" bash "$STAGE/manage.sh" update-backup; then msg_ok "Backed up the database (the newest 3 update backups are kept)"
  else msg_warn "The backup failed; updating anyway."; fi
  msg_info "Updating $APP"
  run ct_install "$ct" code
  wait_healthy "$ct" "$(ct_port "$ct")" || die "The server is not answering. Check: pct exec $ct -- helium-home-sync logs"
  msg_ok "Updated $APP, and it is running"
  drop_bundle "$ct"
  ask_backups "$ct"
  printf '%s%sBackups, alerts, dashboards:%s ./proxmox-lxc.sh settings %s\n' "$INFO" "$YW" "$CL" "$ct"
}

# ask_backups CT: the daily backup is the user's choice; ask once if the container never made it
ask_backups() {
  local choice=yes
  [[ -z $(ct_env "$1" AUTO_BACKUP) ]] || return 0
  if [[ $INTERACTIVE == no ]]; then
    msg_warn "Container $1 has no daily backup. Turn it on: ./proxmox-lxc.sh settings $1"
    return
  fi
  ask_yesno choice "DAILY BACKUPS" "Container $1 has no daily backup yet.\n\nBack up the database every day at 03:30 and keep the newest 14?\nYou can change this any time: ./proxmox-lxc.sh settings $1"
  if [[ $choice == yes ]]; then
    run ct_exec "$1" helium-home-sync backups on
    msg_ok "Turned on the daily backup at 03:30, keeping the newest 14"
  else
    run ct_exec "$1" helium-home-sync backups off
    msg_ok "Daily backups stay off (turn on later: ./proxmox-lxc.sh settings $1)"
  fi
}

cmd_tailscale() {
  local ct mem rc=0
  check_host
  target_container ct tailscale "${1:-}"
  TS_AUTHKEY=${TS_AUTHKEY:-}
  TS_HTTPS=${TS_HTTPS:-no}
  norm_bool TS_HTTPS
  host_tun_ok || die "$TUN_HELP"
  [[ $INTERACTIVE == no ]] || ask_tailscale_login "$(pct config "$ct" | sed -n 's/^hostname: //p')"
  header_info
  pass_tun "$ct"
  if ! ct_running "$ct"; then
    msg_info "Starting container $ct"
    run pct start "$ct"
    msg_ok "Started container $ct"
  elif ! ct_exec "$ct" test -c /dev/net/tun; then
    if [[ $INTERACTIVE == yes ]]; then
      wt --title "RESTART" --yesno "Container $ct must restart to get /dev/net/tun.\nDevices keep working offline meanwhile.\n\nRestart it now?" 11 64 || rc=$?
      ((rc == 0)) || die "Cancelled. Restart it later (pct reboot $ct) and run this again."
    fi
    msg_info "Restarting container $ct"
    run pct reboot "$ct"
    msg_ok "Restarted container $ct"
  fi
  msg_info "Waiting for the network"
  wait_network "$ct" || die "Container $ct has no network."
  msg_ok "Network in LXC is reachable"
  mem=$(pct config "$ct" | sed -n 's/^memory: //p')
  ((${mem:-0} >= 512)) ||
    printf '%s%sTailscale needs about 100 MB. Give the container more memory: pct set %s -memory 512%s\n' "$INFO" "$YW" "$ct" "$CL"

  msg_info "Copying the server files into container $ct"
  push_bundle "$ct"
  msg_ok "Copied the server files into container $ct"
  setup_tailscale "$ct" "$(ct_port "$ct")" || { drop_bundle "$ct"; exit 1; }
  drop_bundle "$ct"
  if ct_exec "$ct" sh -c 'command -v helium-home-sync' >/dev/null; then
    echo
    ct_exec "$ct" helium-home-sync connect
  fi
}

cmd_rename() {
  local ct
  check_host
  target_container ct rename "${1:-}"
  CT_HOSTNAME=${2:-}
  if [[ -z $CT_HOSTNAME ]]; then
    [[ $INTERACTIVE == yes ]] || die "Usage: ./proxmox-lxc.sh rename <ctid> <name>"
    CT_HOSTNAME=$(pct config "$ct" | sed -n 's/^hostname: //p')
    ask_input CT_HOSTNAME "HOSTNAME" "Set the new hostname of container $ct"
  fi
  [[ $CT_HOSTNAME =~ ${RULE[CT_HOSTNAME]} ]] || die "The name must be ${HINT[CT_HOSTNAME]} (not '$CT_HOSTNAME')."
  header_info

  msg_info "Renaming container $ct to $CT_HOSTNAME"
  run pct set "$ct" --hostname "$CT_HOSTNAME"
  ! ct_running "$ct" || ct_exec "$ct" hostname "$CT_HOSTNAME" || true
  msg_ok "Renamed container $ct to $CT_HOSTNAME"
  if ct_running "$ct" && [[ $(ts_state "$ct") == Running ]]; then
    msg_info "Renaming the Tailscale device"
    if run ct_exec "$ct" tailscale set --hostname="$CT_HOSTNAME"; then
      msg_ok "Renamed the Tailscale device to $CT_HOSTNAME"
      printf '%s%sIf you renamed the device in the Tailscale admin console before, its name there stays.%s\n' "$INFO" "$YW" "$CL"
    else
      msg_warn "Couldn't rename the Tailscale device. Do it by hand: pct exec $ct -- tailscale set --hostname=$CT_HOSTNAME"
    fi
  fi
  if ct_running "$ct" && ct_exec "$ct" test -f /etc/helium-home-sync/env; then
    echo
    ct_exec "$ct" helium-home-sync connect
  fi
}

cmd_port() {
  local ct
  check_host
  target_container ct port "${1:-}"
  ct_running "$ct" || die "Container $ct is not running (pct start $ct)."
  ct_exec "$ct" test -f /etc/helium-home-sync/env || die "Container $ct has no $APP install."
  [[ $(ct_exec "$ct" helium-home-sync help 2>/dev/null) == *set-port* ]] ||
    die "Container $ct has an older version without set-port. Update it first: $HERE/proxmox-lxc.sh update $ct"
  PORT=${2:-}
  if [[ -z $PORT ]]; then
    [[ $INTERACTIVE == yes ]] || die "Usage: ./proxmox-lxc.sh port <ctid> <port>"
    PORT=$(ct_port "$ct")
    ask_input PORT "PORT" "Set the port the server in container $ct listens on.\nDevices need the new Server URL afterwards."
  fi
  [[ $PORT =~ ${RULE[PORT]} ]] || die "The port must be ${HINT[PORT]} (not '$PORT')."
  header_info
  ct_exec "$ct" helium-home-sync set-port "$PORT"
}

# settings CT: turn the optional features of a container on or off in a menu
cmd_settings() {
  local ct choice backups alerts token limits url
  check_host
  target_container ct settings "${1:-}"
  ct_running "$ct" || die "Container $ct is not running (pct start $ct)."
  ct_exec "$ct" test -f /etc/helium-home-sync/env || die "Container $ct has no $APP install."
  [[ $(ct_exec "$ct" helium-home-sync help 2>/dev/null) == *"backups on"* ]] ||
    die "Container $ct has an older version without these settings. Update it first: $HERE/proxmox-lxc.sh update $ct"
  if [[ $INTERACTIVE == no ]]; then
    ct_exec "$ct" helium-home-sync status
    printf '\nChange them with: pct exec %s -- helium-home-sync backups|monitor|status-token|limits ...\n' "$ct"
    return
  fi
  while :; do
    backups=off
    [[ $(ct_env "$ct" AUTO_BACKUP) != yes ]] ||
      backups="on, daily at $(ct_env "$ct" BACKUP_TIME), keep the newest $(ct_env "$ct" BACKUP_KEEP)"
    url=$(ct_env "$ct" MONITOR_URL)
    alerts=off
    [[ -z $url ]] || alerts="on, reports to $(cut -d/ -f3 <<<"$url")"
    token=off
    [[ -z $(ct_env "$ct" STATUS_TOKEN) ]] || token=on
    limits=$(ct_exec "$ct" helium-home-sync limits 2>/dev/null | sed -n 's/^Limits: \(.*\)\.$/\1/p' || true)
    choice=$(wt --title "SETTINGS OF CONTAINER $ct" --menu \
      "Optional features. Each one can be turned on or off at any time.\nHow they work: $DOCS" 17 78 5 \
      backups "Daily backups:  $backups" \
      alerts "Alerts:         $alerts" \
      token "Status token:   $token (read-only, for dashboards)" \
      limits "Limits:         ${limits:-unknown}" \
      "done" "Done") || break
    case $choice in
      backups) settings_backups "$ct" ;;
      alerts) settings_alerts "$ct" "$url" ;;
      token) settings_token "$ct" "$token" ;;
      limits) settings_limits "$ct" "$limits" ;;
      *) break ;;
    esac
  done
  clear
}

settings_backups() {
  local on=no
  [[ $(ct_env "$1" AUTO_BACKUP) != yes ]] || on=yes
  ask_yesno on "DAILY BACKUPS" "Back up the database every day?\n\nOnly the newest backups are kept; older ones are deleted. 'No' keeps the existing backups."
  if [[ $on == no ]]; then
    ct_show "$1" "DAILY BACKUPS" helium-home-sync backups off
    return
  fi
  BACKUP_TIME=$(ct_env "$1" BACKUP_TIME)
  BACKUP_KEEP=$(ct_env "$1" BACKUP_KEEP)
  BACKUP_TIME=${BACKUP_TIME:-03:30} BACKUP_KEEP=${BACKUP_KEEP:-14}
  ask_input BACKUP_TIME "BACKUP TIME" "Time of the daily backup (HH:MM)"
  ask_input BACKUP_KEEP "BACKUPS TO KEEP" "How many daily backups to keep. Older ones are deleted."
  ct_show "$1" "DAILY BACKUPS" helium-home-sync backups on "$BACKUP_TIME" "$BACKUP_KEEP"
}

settings_alerts() {
  MONITOR_URL=$2
  wt --title "ALERTS" --msgbox "$ALERTS_HELP" 16 78 || true
  ask_input MONITOR_URL "ALERTS" "Paste your Healthchecks.io ping URL (empty: alerts off)"
  if [[ -n $MONITOR_URL ]]; then
    ct_show "$1" "ALERTS" helium-home-sync monitor on "$MONITOR_URL"
  elif [[ -n $2 ]]; then
    ct_show "$1" "ALERTS" helium-home-sync monitor off
  fi
}

settings_token() {
  local choice verb
  if [[ $2 == off ]]; then
    wt --title "STATUS TOKEN" --yesno "$DASHBOARD_HELP\n\nThe server restarts for a moment." 12 78 || return 0
    ct_show "$1" "STATUS TOKEN" sh -c 'echo yes | helium-home-sync status-token'
    return
  fi
  choice=$(wt --title "STATUS TOKEN" --menu "The status token is on." 13 78 3 \
    show "Show the token" \
    new "Replace it (the old one stops working at once)" \
    off "Remove it (dashboards that use it stop working)") || return 0
  if [[ $choice != show ]]; then
    verb=replace
    [[ $choice == new ]] || verb=remove
    wt --title "STATUS TOKEN" --defaultno --yesno "Really $verb the status token?\n\nDashboards that use the old token stop working until you give them a new one.\nThe server restarts for a moment." 12 78 || return 0
  fi
  ct_show "$1" "STATUS TOKEN" sh -c "echo yes | helium-home-sync status-token ${choice/show/}"
}

settings_limits() {
  [[ $2 =~ disk\ ([0-9]+)%.*memory\ ([0-9]+)%.*swap\ ([0-9]+)% ]] || die "Couldn't read the limits of container $1."
  LIMIT_DISK=${BASH_REMATCH[1]} LIMIT_MEMORY=${BASH_REMATCH[2]} LIMIT_SWAP=${BASH_REMATCH[3]}
  ask_input LIMIT_DISK "LIMITS" "Report a problem when the disk is this full (%)"
  ask_input LIMIT_MEMORY "LIMITS" "Report a problem when this much memory is used (%)"
  ask_input LIMIT_SWAP "LIMITS" "Report a problem when this much swap is used (%)"
  ct_show "$1" "LIMITS" helium-home-sync limits disk "$LIMIT_DISK" memory "$LIMIT_MEMORY" swap "$LIMIT_SWAP"
}

cmd_help() {
  local NEXTID ROOTDIR_STORAGES TEMPLATE_STORAGES BRIDGES TEMPLATES hint="? (run this as root on the Proxmox host to list them)"
  NEXTID=$(pvesh get /cluster/nextid 2>/dev/null || true)
  ROOTDIR_STORAGES=$(storages rootdir | paste -sd' ')
  TEMPLATE_STORAGES=$(storages vztmpl | paste -sd' ')
  BRIDGES=$(bridges | paste -sd' ')
  TEMPLATES=$(templates | sed 's/^/                                /')
  NEXTID=${NEXTID:-?}
  ROOTDIR_STORAGES=${ROOTDIR_STORAGES:-$hint}
  TEMPLATE_STORAGES=${TEMPLATE_STORAGES:-$hint}
  BRIDGES=${BRIDGES:-$hint}
  TEMPLATES=${TEMPLATES:-"                                $hint"}
  render "$RES/usage.txt"
}

norm_bool VERBOSE
case ${1:-} in
  help | -h | --help) cmd_help ;;
  update) cmd_update "${2:-}" ;;
  tailscale) cmd_tailscale "${2:-}" ;;
  rename) cmd_rename "${2:-}" "${3:-}" ;;
  port) cmd_port "${2:-}" "${3:-}" ;;
  settings) cmd_settings "${2:-}" ;;
  '' | default | advanced) cmd_create "${1:-menu}" ;;
  *) die "Unknown command '$1'. Use one of: default, advanced, update, settings, tailscale, rename, port, help" ;;
esac
