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

# Битые зависимости блокируют вообще любую установку. Именно на этом
# в прошлый раз молча не встал usb_modeswitch, а вместе с ним отвалилась
# целая стадия. Поэтому чиним ДО всего остального.
if ! apt-get check >/dev/null 2>&1; then
    warn "в apt битые зависимости — чиню"
    apt-get --fix-broken install -y 2>&1 | tail -5 \
        || die "apt --fix-broken install не справился, разберись руками"
fi

# udhcpc (из busybox) нужен для РАЗВЕДКИ подсети модема: спросить,
# где он уже живёт, и принять это вместо навязывания своего номера.
PKGS="usb-modeswitch usb-modeswitch-data curl iproute2 iputils-ping
      util-linux usbutils dkms build-essential python3 wget busybox"

NEED=""
for p in $PKGS; do
    dpkg -s "$p" >/dev/null 2>&1 || NEED="$NEED $p"
done

if [ -n "$NEED" ]; then
    say "ставлю:$NEED"
    apt-get update -qq 2>/dev/null || warn "apt update не отработал, пробую из кэша"
    # shellcheck disable=SC2086
    apt-get install -y $NEED 2>&1 | tail -5 || die "apt не поставил:$NEED"
fi

# Заголовки ядра — имя пакета разное на PVE 9.x, PVE 8.x и чистом Debian
KREL="$(uname -r)"
if [ ! -d "/lib/modules/$KREL/build" ]; then
    say "заголовки ядра для $KREL"
    for p in "proxmox-headers-$KREL" "pve-headers-$KREL" "linux-headers-$KREL"; do
        apt-get install -y "$p" >/dev/null 2>&1 && { say "  поставлен $p"; break; }
    done
fi
[ -d "/lib/modules/$KREL/build" ] \
    || warn "заголовков нет — фикс скорости не соберётся, остальное будет работать"

# Проверяем результат, а не факт запуска apt
FAIL=""
for b in curl ip ping flock lsusb usb_modeswitch python3; do
    command -v "$b" >/dev/null 2>&1 || FAIL="$FAIL $b"
done
[ -n "$FAIL" ] && die "не появились обязательные утилиты:$FAIL"
say "все зависимости на месте"

# ---------------------------------------------------------------- файлы ----

say "каталоги"
mkdir -p "$DEST/lib" "$DEST/sbin" "$DEST/bin" "$DEST/dkms" "$ETC" "$VAR" "$RUN"

say "файлы"
install -m 644 "$SRC"/lib/*.sh              "$DEST/lib/"
chmod 755 "$DEST/lib/dhcp-probe.sh"          # вызывается udhcpc как хук
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

# Буфер usbfs: по умолчанию 16 МБ на всё ядро. Десятки модемов с крупными
# RX-URB его исчерпывают, и submit падает — выглядит как случайные обрывы.
say "буфер usbfs"
echo "options usbcore usbfs_memory_mb=1024" >/etc/modprobe.d/hivelink-usbcore.conf
if [ -w /sys/module/usbcore/parameters/usbfs_memory_mb ]; then
    echo 1024 >/sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null \
        && say "  применено на живую: $(cat /sys/module/usbcore/parameters/usbfs_memory_mb) МБ"
else
    warn "  применится после перезагрузки (usbcore вкомпилирован в ядро)"
fi

# Снимок рабочего резолвера, пока он ещё цел — источник правды для стража DNS
say "снимок резолвера"
mkdir -p "$VAR"
if grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; then
    awk '/^nameserver/{print $2}' /etc/resolv.conf | grep -v '^192\.168\.' >"$VAR/resolv.upstream" || true
    if [ -s "$VAR/resolv.upstream" ]; then
        say "  сохранено: $(tr '\n' ' ' <"$VAR/resolv.upstream")"
    else
        rm -f "$VAR/resolv.upstream"
        warn "  все nameserver из 192.168.* — задай HL_DNS_UPSTREAM в конфиге вручную"
    fi
else
    warn "  в /etc/resolv.conf нет nameserver — задай HL_DNS_UPSTREAM вручную"
fi

say "udev"
install -m 644 "$SRC/etc/udev/70-hivelink.rules" /etc/udev/rules.d/70-hivelink.rules

# Перехват штатного авто-переключения.
#
# /lib/udev/rules.d/40-usb_modeswitch.rules запускает usb_modeswitch на КАЖДОМ
# устройстве вендора независимо и без координации. На двадцати модемах это
# шторм, а его диспетчер при неудаче перебирает USB-конфигурации и уводит
# устройство в конфигурацию с MBIM — там нужного endpoint нет вовсе,
# и переключение становится невозможным. Наблюдалось вживую: конфигурация 1
# держалась 0.7 секунды и сменялась на 2.
#
# Одноимённый файл в /etc полностью отменяет тот, что в /lib. Копируем
# штатный, добавляя ранний выход для наших вендоров: hivelink переключает
# сам — под блокировкой, со счётчиками попыток и с предустановкой
# конфигурации 1. Для всех прочих устройств поведение остаётся штатным.
STOCK_MS=/lib/udev/rules.d/40-usb_modeswitch.rules
OUR_MS=/etc/udev/rules.d/40-usb_modeswitch.rules
VENDORS="$(sed -n 's/^ *HL_VENDORS=["'"'"']\{0,1\}\([^"'"'"']*\).*/\1/p' "$ETC/hivelink.conf" 2>/dev/null | tail -1)"
VENDORS="${VENDORS:-12d1}"

if [ -f "$STOCK_MS" ]; then
    {
        printf '# hivelink: перехват штатного авто-переключения.\n'
        printf '# Копия %s с ранним выходом\n' "$STOCK_MS"
        printf '# для вендоров %s — ими управляет hivelink сам.\n' "$VENDORS"
        printf '# Файл пересоздаётся при установке и удаляется uninstall.sh.\n#\n'
        awk -v vendors="$VENDORS" '
            BEGIN { n = split(vendors, v, " ") }
            !ins && /^ACTION!=/ {
                print
                for (i = 1; i <= n; i++)
                    printf "\n# hivelink переключает этого вендора сам\nATTRS{idVendor}==\"%s\", GOTO=\"modeswitch_rules_end\"\n", v[i]
                ins = 1
                next
            }
            { print }
        ' "$STOCK_MS"
    } >"$OUR_MS"
    chmod 644 "$OUR_MS"
    say "  штатное авто-переключение перехвачено для: $VENDORS"
else
    warn "  $STOCK_MS не найден — перехватывать нечего"
fi

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
