#!/bin/bash
# hivelink/dkms — сборка и установка исправленного rndis_host через DKMS.
#
# Зачем DKMS: модуль надо пересобирать на каждое обновление ядра, иначе
# после первого же apt upgrade вернётся штатный драйвер и приём снова
# упадёт до ~1 Мбит. DKMS делает это сам.
#
#   bash build.sh [размер_буфера]     по умолчанию берётся из hivelink.conf
#   bash build.sh --remove            снять пакет
#
# Исходник rndis_host.c берётся под текущее ядро. Если апстрим когда-нибудь
# перепишет generic_rndis_bind(), сборка честно упадёт с понятной ошибкой —
# тогда патч переносится вручную, см. patch.py.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG=hivelink-rndis
KREL="$(uname -r)"
KBASE="$(printf '%s' "$KREL" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?')"
KMAJ="${KBASE%%.*}"
VER="1.0-k${KBASE}"
SRCDIR="/usr/src/$PKG-$VER"
WORK="/var/cache/hivelink/kernel-src"
MODPROBE_CONF=/etc/modprobe.d/hivelink-rndis.conf

say()  { printf '\033[36m==\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[31m!!\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "нужен root"

# ---------------------------------------------------------------- remove ---

if [ "${1:-}" = "--remove" ]; then
    say "снимаю DKMS-пакеты hivelink-rndis"
    if command -v dkms >/dev/null 2>&1; then
        dkms status 2>/dev/null | grep "^$PKG" | while IFS= read -r line; do
            v=$(printf '%s' "$line" | sed -E "s#^$PKG[/,] *([^,:]+).*#\1#")
            dkms remove -m "$PKG" -v "$v" --all 2>&1 | sed 's/^/   /'
            rm -rf "/usr/src/$PKG-$v"
        done
    fi
    rm -f "$MODPROBE_CONF"
    depmod -a
    rmmod rndis_host 2>/dev/null || true
    modprobe rndis_host 2>/dev/null || true
    say "готово, вернулся штатный драйвер"
    exit 0
fi

# --------------------------------------------------------------- размер ----

SIZE="${1:-}"
if [ -z "$SIZE" ]; then
    # shellcheck disable=SC1091
    [ -r /etc/hivelink/hivelink.conf ] && . /etc/hivelink/hivelink.conf
    SIZE="${HL_RX_URB_SIZE:-16384}"
fi
say "размер RX-буфера: $SIZE"

# --------------------------------------------------------- зависимости ----

command -v dkms >/dev/null 2>&1 || {
    say "ставлю dkms"
    apt-get install -y dkms >/dev/null 2>&1 || die "не удалось поставить dkms"
}

if [ ! -d "/lib/modules/$KREL/build" ]; then
    say "ставлю заголовки ядра"
    apt-get install -y "proxmox-headers-$KREL" >/dev/null 2>&1 \
        || apt-get install -y "linux-headers-$KREL" >/dev/null 2>&1 \
        || apt-get install -y "pve-headers-$KREL"   >/dev/null 2>&1 \
        || die "не нашёл пакет заголовков для $KREL — поставь вручную"
fi
[ -d "/lib/modules/$KREL/build" ] || die "нет /lib/modules/$KREL/build"

# ------------------------------------------------------------- исходник ----

mkdir -p "$WORK"
SRC_C="$WORK/rndis_host-$KBASE.c"

if [ ! -f "$SRC_C" ]; then
    # Иногда исходник уже лежит рядом с заголовками — тогда качать не нужно
    found=$(find "/lib/modules/$KREL/build" /usr/src -maxdepth 6 \
                 -path '*drivers/net/usb/rndis_host.c' 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        say "исходник найден локально: $found"
        cp -f "$found" "$SRC_C"
    else
        TAR="$WORK/linux-$KBASE.tar.xz"
        URL="https://cdn.kernel.org/pub/linux/kernel/v${KMAJ}.x/linux-$KBASE.tar.xz"
        say "тяну исходник ядра $KBASE"
        [ -f "$TAR" ] || wget -q --show-progress -O "$TAR" "$URL" \
            || die "не скачался $URL — положи rndis_host.c в $SRC_C вручную"
        tar -xf "$TAR" -C "$WORK" --wildcards "linux-$KBASE/drivers/net/usb/rndis_host.c" \
            || die "в архиве нет drivers/net/usb/rndis_host.c"
        cp -f "$WORK/linux-$KBASE/drivers/net/usb/rndis_host.c" "$SRC_C"
        rm -rf "$WORK/linux-$KBASE"
    fi
fi

# ---------------------------------------------------------------- патч -----

say "готовлю $SRCDIR"
rm -rf "$SRCDIR"; mkdir -p "$SRCDIR"
cp -f "$SRC_C" "$SRCDIR/rndis_host.c"

python3 "$HERE/patch.py" "$SRCDIR/rndis_host.c" || die "патч не наложился"
grep -q rx_urb_size_override "$SRCDIR/rndis_host.c" || die "патча нет в исходнике"

printf 'obj-m += rndis_host.o\n' >"$SRCDIR/Makefile"

cat >"$SRCDIR/dkms.conf" <<CONF
PACKAGE_NAME="$PKG"
PACKAGE_VERSION="$VER"
BUILT_MODULE_NAME[0]="rndis_host"
# /updates имеет приоритет над kernel/drivers/net/usb — так наш модуль
# перекрывает штатный, не удаляя его. Откат = снять пакет.
DEST_MODULE_LOCATION[0]="/updates"
AUTOINSTALL="yes"
MAKE[0]="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build modules"
CLEAN="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build clean"
CONF

# ---------------------------------------------------------------- сборка ---

say "регистрирую в DKMS"
dkms remove -m "$PKG" -v "$VER" --all >/dev/null 2>&1 || true
dkms add    -m "$PKG" -v "$VER"       2>&1 | sed 's/^/   /'
dkms build  -m "$PKG" -v "$VER"       2>&1 | tail -8 | sed 's/^/   /' \
    || die "сборка не прошла — смотри /var/lib/dkms/$PKG/$VER/build/make.log"
dkms install -m "$PKG" -v "$VER" --force 2>&1 | sed 's/^/   /'

# ------------------------------------------------------------- параметр ----

say "параметр модуля"
cat >"$MODPROBE_CONF" <<EOF
# hivelink: обход бага rndis_host (разрыв RNDIS-сообщений между URB).
# 0 вернёт штатное поведение ядра — медленно, но безопасно.
options rndis_host rx_urb_size_override=$SIZE
EOF
sed 's/^/   /' "$MODPROBE_CONF"
depmod -a

# ------------------------------------------------------------- проверка ----

say "проверка"
f=$(modinfo rndis_host 2>/dev/null | awk '/^filename/{print $2}')
printf '   модуль: %s\n' "${f:-не найден}"
case "$f" in
    */updates/*) printf '   \033[32mOK — активен исправленный модуль\033[0m\n' ;;
    *)           warn "загружается штатный модуль. Перезагрузи его: rmmod rndis_host && modprobe rndis_host" ;;
esac
dkms status 2>/dev/null | grep "^$PKG" | sed 's/^/   /'

say "готово"
