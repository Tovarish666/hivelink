#!/bin/bash
# hivelink — удаление.
#   bash uninstall.sh            снять всё, конфиг и состояние оставить
#   bash uninstall.sh --purge    снести вместе с конфигом и картой слотов

set -uo pipefail

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

say()  { printf '\033[36m==\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[31m!!\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "нужен root"

say "останавливаю юниты"
systemctl disable --now hivelink-reconcile.timer   2>/dev/null || true
systemctl stop            hivelink-reconcile.service 2>/dev/null || true
rm -f /etc/systemd/system/hivelink-*.service /etc/systemd/system/hivelink-*.timer
systemctl daemon-reload

say "снимаю DKMS-фикс rndis_host"
[ -x /opt/hivelink/dkms/build.sh ] && bash /opt/hivelink/dkms/build.sh --remove || true

say "udev и sysctl"
rm -f /etc/udev/rules.d/70-hivelink.rules
rm -f /etc/sysctl.d/90-hivelink.conf
rm -f /etc/systemd/network/10-hivelink-modems.network
udevadm control --reload 2>/dev/null || true

say "снимаю адресацию модемов"
if [ -f /var/lib/hivelink/slots ]; then
    # shellcheck disable=SC1091
    . /etc/hivelink/hivelink.conf 2>/dev/null || true
    while read -r _ slot; do
        [ -n "$slot" ] || continue
        host="${HL_SUBNET_PREFIX:-192.168}.$slot.${HL_HOST_OCTET:-100}"
        table=$(( ${HL_TABLE_BASE:-10000} + slot ))
        ip rule del from "$host" lookup "$table" 2>/dev/null || true
        ip route flush table "$table" 2>/dev/null || true
    done </var/lib/hivelink/slots
fi

say "файлы"
rm -rf /opt/hivelink
rm -f  /usr/local/bin/hivelink
rm -rf /run/hivelink

if [ "$PURGE" = 1 ]; then
    warn "--purge: сношу конфиг и карту слотов"
    warn "после этого номера модемов будут выданы заново"
    rm -rf /etc/hivelink /var/lib/hivelink /var/cache/hivelink
else
    say "конфиг и состояние оставлены: /etc/hivelink, /var/lib/hivelink"
fi

say "возвращаю штатный rndis_host"
rmmod rndis_host 2>/dev/null || true
modprobe rndis_host 2>/dev/null || true

say "готово"
