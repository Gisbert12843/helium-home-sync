#!/usr/bin/env bash
# Runs inside the LXC container, from the bundle that proxmox-lxc.sh pushes in.
# The host calls one step at a time so it can report progress:
#   install.sh packages [extra packages]   update Debian, install python3, curl and the extras
#   install.sh auto-updates                install Debian security updates automatically
#   install.sh server                      service user, config (from server.env), code, start
#   install.sh code                        replace the code and restart (update)
#   install.sh backup-timer <HH:MM>        daily database backup
#   install.sh tailscale                   install and start tailscaled
set -euo pipefail

SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
APP=/opt/helium-home-sync
SVC=helium-home-sync
DATA=/var/lib/helium-home-sync
CONF=/etc/helium-home-sync
export DEBIAN_FRONTEND=noninteractive

install_code() {
  install -d -m 755 "$APP" "$APP/text"
  install -m 644 "$SRC/server.py" "$SRC/admin.py" "$SRC/schema.sql" "$APP/"
  install -m 644 "$SRC"/text/* "$APP/text/"
  install -m 755 "$SRC/manage.sh" /usr/local/bin/helium-home-sync
  ln -sf /usr/local/bin/helium-home-sync /usr/bin/helium-home-sync
  install -m 644 "$SRC/proxmox/$SVC.service" /etc/systemd/system/
  systemctl daemon-reload
}

case ${1:-} in
  packages)
    shift
    apt-get -q update
    apt-get -q -y -o Dpkg::Options::=--force-confold upgrade
    apt-get -q -y install python3 curl "$@"
    ;;

  auto-updates)
    install -m 644 "$SRC/proxmox/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
    ;;

  server)
    id "$SVC" >/dev/null 2>&1 || useradd --system --home-dir "$DATA" --shell /usr/sbin/nologin "$SVC"
    install -d -o "$SVC" -g "$SVC" -m 750 "$DATA" "$DATA/backups"
    install -d -m 755 "$CONF"
    install -m 600 "$SRC/server.env" "$CONF/env"
    rm -f "$SRC/server.env"
    install_code
    systemctl enable -q --now "$SVC"
    ;;

  code)
    [[ -f $CONF/env ]] || { echo "This container has no Helium Home Sync install ($CONF/env is missing)." >&2; exit 1; }
    install_code
    systemctl enable -q "$SVC"
    systemctl restart "$SVC"
    ;;

  backup-timer)
    [[ ${2:-} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "Usage: install.sh backup-timer <HH:MM>" >&2; exit 1; }
    install -m 644 "$SRC/proxmox/$SVC-backup.service" /etc/systemd/system/
    sed "s/{{BACKUP_TIME}}/$2/" "$SRC/proxmox/$SVC-backup.timer" >"/etc/systemd/system/$SVC-backup.timer"
    systemctl daemon-reload
    systemctl enable -q --now "$SVC-backup.timer"
    ;;

  tailscale)
    command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
    systemctl enable -q --now tailscaled
    ;;

  *)
    sed -n '2,10s/^# \{0,1\}//p' "$0" >&2
    exit 1
    ;;
esac
