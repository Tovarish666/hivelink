#!/bin/bash
# hivelink — снос старого хозяйства перед установкой нового.
#
# Убирает:
#   * e3372-proxmox  (скрипты, конфиги, юниты, udev, состояние)
#   * ручные эксперименты с rndis_host из /root
#   * ad-hoc DKMS-пакет rndis-host-fix и его modprobe.d
#
# По умолчанию НИЧЕГО НЕ УДАЛЯЕТ — только показывает список.
# Реальный снос:  bash purge-legacy.sh --apply
#
# ВНИМАНИЕ: после --apply модемы останутся без управления.
# Ставь hivelink сразу следом, не оставляй хост в этом состоянии.

set -uo pipefail

APPLY=0
KEEP_BACKUP=1
for a in "$@"; do
    case "$a" in
        --apply)      APPLY=1 ;;
        --no-backup)  KEEP_BACKUP=0 ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) printf 'неизвестный аргумент: %s\n' "$a" >&2; exit 2 ;;
    esac
done

say()  { printf '\033[36m==\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[31m!!\033[0m %s\n' "$*" >&2; exit 1; }
hit()  { printf '   \033[90m%s\033[0m %s\n' "$1" "$2"; }

[ "$(id -u)" = 0 ] || die "нужен root"

TS=$(date +%Y%m%d-%H%M%S)
BACKUP="/root/legacy-modem-stack-$TS.tar.gz"

# ---------------------------------------------------------------- инвентарь --

SERVICES=""
for u in e3372-reconcile.timer e3372-reconcile.service e3372.service e3372-watchdog.service; do
    systemctl list-unit-files "$u" >/dev/null 2>&1 &&
        systemctl cat "$u" >/dev/null 2>&1 && SERVICES="$SERVICES $u"
done

PATHS=""
add() { [ -e "$1" ] && PATHS="$PATHS $1"; return 0; }

# --- e3372-proxmox
add /usr/local/sbin/e3372-reconcile
add /usr/local/lib/e3372
add /etc/e3372
add /var/lib/e3372
for f in /usr/local/bin/e3372-*;                 do add "$f"; done
for f in /etc/systemd/system/e3372-*;            do add "$f"; done
for f in /etc/udev/rules.d/*e3372*;              do add "$f"; done
for f in /etc/systemd/network/*e3372*;           do add "$f"; done
for f in /etc/sysctl.d/*e3372*;                  do add "$f"; done
for f in /etc/usb_modeswitch.d/12d1:1f0*;        do add "$f"; done

# --- наши эксперименты
add /root/rndis-build
add /root/rndis-debug.sh
add /root/rndis-prep.sh
add /root/rndis-patch.sh
add /root/rndis-probe-modes.sh
add /root/fix-modeswitch.sh
add /root/rndis-dkms-install.sh
add /etc/modprobe.d/rndis-host-fix.conf

DKMS_OLD=""
if command -v dkms >/dev/null 2>&1; then
    DKMS_OLD=$(dkms status 2>/dev/null | grep -i '^rndis-host-fix' || true)
fi

NETWORKD=""
if [ -d /etc/systemd/network ]; then
    NETWORKD=$(grep -rlE 'rndis_host|cdc_ether|e3372' /etc/systemd/network 2>/dev/null || true)
fi

# ------------------------------------------------------------------- отчёт ---

say "что будет удалено"

if [ -n "$SERVICES" ]; then
    echo "  systemd юниты (stop + disable + удаление файла):"
    for u in $SERVICES; do hit "unit" "$u"; done
else
    echo "  systemd юнитов не найдено"
fi

if [ -n "$PATHS" ]; then
    echo "  файлы и каталоги:"
    for p in $PATHS; do hit "path" "$p"; done
else
    echo "  файлов не найдено"
fi

if [ -n "$DKMS_OLD" ]; then
    echo "  DKMS:"
    echo "$DKMS_OLD" | while read -r l; do hit "dkms" "$l"; done
fi

if [ -n "$NETWORKD" ]; then
    echo "  .network файлы, ссылающиеся на модемные драйверы:"
    echo "$NETWORKD" | while read -r l; do hit "net " "$l"; done
    warn "их проверь глазами — вдруг там есть что-то не про модемы"
fi

echo
if [ "$APPLY" != 1 ]; then
    say "это был показ. Реальный снос:  bash $0 --apply"
    exit 0
fi

# ------------------------------------------------------------------- снос ----

warn "сношу. Модемы останутся без управления до установки hivelink."

if [ "$KEEP_BACKUP" = 1 ] && [ -n "$PATHS$SERVICES" ]; then
    say "бэкап в $BACKUP"
    # shellcheck disable=SC2086
    tar czf "$BACKUP" --ignore-failed-read --absolute-names $PATHS 2>/dev/null
    for u in $SERVICES; do
        systemctl cat "$u" >>"/root/legacy-units-$TS.txt" 2>/dev/null
    done
    [ -f "$BACKUP" ] && ls -lh "$BACKUP" | sed 's/^/   /'
fi

if [ -n "$SERVICES" ]; then
    say "останавливаю юниты"
    for u in $SERVICES; do
        systemctl stop    "$u" 2>/dev/null && hit "stop" "$u"
        systemctl disable "$u" 2>/dev/null && hit "dis " "$u"
    done
fi

if [ -n "$DKMS_OLD" ]; then
    say "снимаю DKMS-пакет rndis-host-fix"
    ver=$(echo "$DKMS_OLD" | head -1 | sed -E 's#^rndis-host-fix[/,] *([^,:]+).*#\1#')
    dkms remove -m rndis-host-fix -v "$ver" --all 2>&1 | sed 's/^/   /'
    rm -rf "/usr/src/rndis-host-fix-$ver"
fi

if [ -n "$PATHS" ]; then
    say "удаляю файлы"
    for p in $PATHS; do rm -rf -- "$p" && hit "rm  " "$p"; done
fi

say "перечитываю systemd/udev/модули"
systemctl daemon-reload
udevadm control --reload 2>/dev/null || true
depmod -a 2>/dev/null || true

say "возвращаю штатный rndis_host"
rmmod rndis_host 2>/dev/null || true
sleep 1
modprobe rndis_host 2>/dev/null || true
mod=$(modinfo rndis_host 2>/dev/null | awk '/^filename/{print $2}')
hit "mod " "${mod:-не загрузился}"
case "$mod" in
    */updates/*) warn "модуль всё ещё из /updates — остался чужой DKMS, проверь: dkms status" ;;
esac

echo
say "готово. Бэкап: ${BACKUP:-нет}"
warn "ставь hivelink сейчас:  bash install.sh"
