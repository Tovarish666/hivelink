#!/usr/bin/env bash
# =============================================================================
#  Откат e3372-driver. Модемы останутся как есть, но без маршрутов и без
#  автоматического восстановления.
#    PURGE_PKGS=1  — снести и установленные пакеты
#    KEEP_CONF=1   — оставить /etc/e3372/e3372.conf
# =============================================================================
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "нужен root" >&2; exit 1; }

echo "[e3372] останавливаю драйвер…"
systemctl disable --now e3372-reconcile.timer   >/dev/null 2>&1 || true
systemctl disable --now e3372-reconcile.service >/dev/null 2>&1 || true
# на случай отката с прошлой версии
systemctl disable --now e3372-watchdog.timer    >/dev/null 2>&1 || true
systemctl disable --now e3372-watchdog.service  >/dev/null 2>&1 || true

echo "[e3372] снимаю правила маршрутизации…"
while read -r addr; do
    n=$(printf '%s' "$addr" | cut -d. -f3)
    if [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le 252 ] 2>/dev/null; then tbl=$n; else tbl=$(( 10000 + n )); fi
    i=0; while [ "$i" -lt 5 ]; do ip rule del from "$addr/32" 2>/dev/null || break; i=$(( i + 1 )); done
    ip route flush table "$tbl" 2>/dev/null || true
done < <(ip rule show 2>/dev/null | sed -n 's/.*from \(192\.168\.[0-9]*\.100\)\/32.*/\1/p' | sort -u)

echo "[e3372] удаляю файлы…"
rm -f /etc/systemd/system/e3372-reconcile.service \
      /etc/systemd/system/e3372-reconcile.timer \
      /etc/systemd/network/25-e3372.network \
      /etc/udev/rules.d/70-e3372.rules \
      /etc/udev/rules.d/71-e3372-ports.rules \
      /etc/sysctl.d/99-e3372.conf \
      /usr/local/sbin/e3372-reconcile \
      /usr/local/bin/e3372-status \
      /usr/local/bin/e3372-ctl \
      /usr/local/bin/e3372-doctor
bash /usr/local/lib/e3372/dkms/build.sh --remove 2>/dev/null || true
rm -rf /usr/local/lib/e3372 /run/e3372 /var/lib/e3372 /var/cache/e3372
[ "${KEEP_CONF:-0}" = 1 ] || rm -rf /etc/e3372

echo "[e3372] возвращаю штатное авто-переключение usb_modeswitch…"
if [ -f /etc/udev/rules.d/40-usb_modeswitch.rules ] &&
   grep -q '^# e3372-driver:' /etc/udev/rules.d/40-usb_modeswitch.rules 2>/dev/null; then
    rm -f /etc/udev/rules.d/40-usb_modeswitch.rules
fi

echo "[e3372] возвращаю usb_modeswitch-конфиги…"
for p in 1f01 1f02 1f10 1f11 1f12 1f13 1f14 1440 14fe 1505 155a 1c0b; do
    cfg="/etc/usb_modeswitch.d/12d1:$p"
    if [ -f "$cfg.e3372.bak" ]; then mv -f "$cfg.e3372.bak" "$cfg"
    elif [ -f "$cfg" ] && grep -q '^HuaweiNewMode=1' "$cfg" 2>/dev/null; then rm -f "$cfg"; fi
done

systemctl daemon-reload 2>/dev/null || true
udevadm control --reload 2>/dev/null || true
systemctl restart systemd-networkd 2>/dev/null || true
sysctl -q -w net.ipv4.conf.all.rp_filter=1 2>/dev/null || true

if [ "${PURGE_PKGS:-0}" = 1 ]; then
    echo "[e3372] удаляю пакеты…"
    apt-get remove -y usb-modeswitch usb-modeswitch-data >/dev/null 2>&1 || true
fi
echo "[e3372] готово."
