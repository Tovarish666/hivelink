#!/bin/bash
# hivelink — установка.
# Запускать из каталога проекта:  bash install.sh
#
#   --no-dkms     пропустить сборку исправленного rndis_host
#   --no-start    не включать таймер и не гонять первый цикл

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST=/opt/hivelink
ETC=/etc/hivelink
VAR=/var/lib/hivelink
RUN=/run/hivelink
BIN=/usr/local/bin/hivelink

WITH_DKMS=1
DO_START=1
for a in "$@"; do
    case "$a" in
        --no-dkms)  WITH_DKMS=0 ;;
        --no-start) DO_START=0 ;;
        -h|--help)  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'неизвестный аргумент: %s\n' "$a" >&2; exit 2 ;;
    esac
done

say()  { printf '\033[36m==\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[31m!!\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "нужен root"
[ -f "$SRC/sbin/hivelink-reconcile" ] || die "запусти из каталога проекта"

# ------------------------------------------------------------ зависимости --

say "зависимости"
MISSING=""
for b in curl ip ping flock lsusb; do
    command -v "$b" >/dev/null 2>&1 || MISSING="$MISSING $b"
done
command -v usb_modeswitch >/dev/null 2>&1 || MISSING="$MISSING usb_modeswitch"

if [ -n "$MISSING" ]; then
    warn "не хватает:$MISSING — ставлю"
    apt-get update -qq || true
    apt-get install -y usb-modeswitch usb-modeswitch-data curl iproute2 \
                       iputils-ping util-linux usbutils 2>&1 | tail -3 \
        || die "apt не отработал. Если это битые зависимости — сначала: apt --fix-broken install"
fi
command -v usb_modeswitch >/dev/null 2>&1 \
    || die "usb_modeswitch так и не появился. Без него модемы не выйдут из Zero-CD."

# ---------------------------------------------------------------- файлы ----

say "каталоги"
mkdir -p "$DEST/lib" "$DEST/sbin" "$DEST/bin" "$DEST/dkms" "$ETC" "$VAR" "$RUN"

say "файлы"
install -m 644 "$SRC"/lib/*.sh              "$DEST/lib/"
install -m 755 "$SRC/sbin/hivelink-reconcile" "$DEST/sbin/hivelink-reconcile"
install -m 755 "$SRC/bin/hivelink"            "$DEST/bin/hivelink"
install -m 755 "$SRC/dkms/build.sh"           "$DEST/dkms/build.sh"
install -m 755 "$SRC/dkms/patch.py"           "$DEST/dkms/patch.py"
install -m 644 "$SRC/VERSION"                 "$DEST/VERSION"
ln -sf "$DEST/bin/hivelink" "$BIN"

if [ -f "$ETC/hivelink.conf" ]; then
    install -m 644 "$SRC/etc/hivelink.conf" "$ETC/hivelink.conf.new"
    warn "конфиг уже был — новый образец рядом: $ETC/hivelink.conf.new"
else
    install -m 644 "$SRC/etc/hivelink.conf" "$ETC/hivelink.conf"
fi

say "параметры ядра"
install -m 644 "$SRC/etc/sysctl.d/90-hivelink.conf" /etc/sysctl.d/90-hivelink.conf
sysctl -q --system 2>/dev/null || true

say "udev"
install -m 644 "$SRC/etc/udev/70-hivelink.rules" /etc/udev/rules.d/70-hivelink.rules
udevadm control --reload 2>/dev/null || true

say "systemd"
install -m 644 "$SRC"/systemd/*.service "$SRC"/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload

# ----------------------------------------------------------------- DKMS ----

if [ "$WITH_DKMS" = 1 ]; then
    say "исправленный rndis_host (DKMS)"
    if bash "$DEST/dkms/build.sh"; then
        say "фикс установлен"
    else
        warn "сборка фикса не прошла. hivelink будет работать, но приём на"
        warn "RNDIS-модемах останется ~1 Мбит. Разбор: hivelink doctor"
    fi
else
    warn "DKMS пропущен по флагу — RNDIS-модемы будут медленными"
fi

# ---------------------------------------------------------------- запуск ---

if [ "$DO_START" = 1 ]; then
    say "перезагружаю rndis_host, чтобы подхватить фикс"
    systemctl stop hivelink-reconcile.timer 2>/dev/null || true
    rmmod rndis_host 2>/dev/null || true
    sleep 1
    modprobe rndis_host 2>/dev/null || true

    say "первый цикл"
    "$DEST/sbin/hivelink-reconcile" || warn "цикл завершился с замечаниями — смотри hivelink status"

    say "включаю таймер"
    systemctl enable --now hivelink-reconcile.timer
fi

echo
say "установлено"
cat <<'EOF'

   hivelink status     таблица модемов
   hivelink doctor     полная диагностика (начинай отсюда, если что-то не так)
   hivelink speed 101  замер полосы на слоте
   hivelink slots      карта «USB-порт -> номер модема»

Конфиг: /etc/hivelink/hivelink.conf
EOF
