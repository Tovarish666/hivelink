#!/usr/bin/env bash
# =============================================================================
#  e3372-driver / dkms — сборка исправленного rndis_host.
#
#  Зачем DKMS: модуль надо пересобирать на каждое обновление ядра, иначе после
#  первого же apt upgrade вернётся штатный драйвер и приём снова упадёт
#  до ~1.3 Мбит. DKMS делает это сам.
#
#    bash build.sh [размер_буфера]   по умолчанию берётся RX_URB_SIZE из конфига
#    bash build.sh --remove          снять пакет и вернуть штатный модуль
#
#  Исходник rndis_host.c берётся под текущее ядро. Если апстрим перепишет
#  generic_rndis_bind(), сборка честно упадёт с понятной ошибкой — тогда патч
#  переносится вручную, см. patch.py.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PKG=e3372-rndis-fix
KREL="$(uname -r)"
KBASE="$(printf '%s' "$KREL" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?')"
KMAJ="${KBASE%%.*}"
VER="1.0-k${KBASE}"
SRCDIR="/usr/src/$PKG-$VER"
WORK="/var/cache/e3372/kernel-src"
MODPROBE_CONF=/etc/modprobe.d/e3372-rndis.conf

c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_r=$'\033[1;31m'; c_0=$'\033[0m'
log()  { printf '%s[rndis-fix]%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s[rndis-fix]%s %s\n' "$c_y" "$c_0" "$*"; }
die()  { printf '%s[rndis-fix] %s%s\n' "$c_r" "$*" "$c_0" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "нужен root"

# ---------------------------------------------------------------- remove ----
if [ "${1:-}" = "--remove" ]; then
    log "снимаю DKMS-пакеты $PKG"
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
    log "готово, вернулся штатный драйвер"
    exit 0
fi

# --------------------------------------------------------------- размер -----
SIZE="${1:-}"
if [ -z "$SIZE" ]; then
    # shellcheck disable=SC1091
    [ -r /etc/e3372/e3372.conf ] && . /etc/e3372/e3372.conf
    SIZE="${RX_URB_SIZE:-16384}"
fi
[ "$SIZE" = 0 ] && { log "RX_URB_SIZE=0 — фикс отключён конфигом, выхожу"; exit 0; }
log "размер RX-буфера: $SIZE"

# ----------------------------------------------------------- зависимости ----
command -v dkms >/dev/null 2>&1 || {
    log "ставлю dkms"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends dkms \
        >/dev/null 2>&1 || die "не удалось поставить dkms"
}
command -v gcc >/dev/null 2>&1 || {
    log "ставлю build-essential"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends build-essential \
        >/dev/null 2>&1 || die "не удалось поставить компилятор"
}

if [ ! -d "/lib/modules/$KREL/build" ]; then
    log "ставлю заголовки ядра для $KREL"
    for p in "proxmox-headers-$KREL" "pve-headers-$KREL" "linux-headers-$KREL"; do
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$p" \
            >/dev/null 2>&1 && { log "  поставлен $p"; break; }
    done
fi
[ -d "/lib/modules/$KREL/build" ] || die "нет /lib/modules/$KREL/build — поставь заголовки ядра вручную"

# ------------------------------------------------------------- исходник -----
mkdir -p "$WORK"
SRC_C="$WORK/rndis_host-$KBASE.c"

if [ ! -f "$SRC_C" ]; then
    found=$(find "/lib/modules/$KREL/build" /usr/src -maxdepth 6 \
                 -path '*drivers/net/usb/rndis_host.c' 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        log "исходник найден локально: $found"
        cp -f "$found" "$SRC_C"
    else
        TAR="$WORK/linux-$KBASE.tar.xz"
        URL="https://cdn.kernel.org/pub/linux/kernel/v${KMAJ}.x/linux-$KBASE.tar.xz"
        log "тяну исходник ядра $KBASE (нужен один файл)"
        [ -f "$TAR" ] || curl -fL --retry 3 --connect-timeout 30 --max-time 900 \
            -o "$TAR" "$URL" || die "не скачался $URL — положи rndis_host.c в $SRC_C вручную"
        tar -xf "$TAR" -C "$WORK" --wildcards "linux-$KBASE/drivers/net/usb/rndis_host.c" \
            || die "в архиве нет drivers/net/usb/rndis_host.c"
        cp -f "$WORK/linux-$KBASE/drivers/net/usb/rndis_host.c" "$SRC_C"
        rm -rf "${WORK:?}/linux-$KBASE"
    fi
fi

# ---------------------------------------------------------------- патч ------
log "готовлю $SRCDIR"
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

# ---------------------------------------------------------------- сборка ----
log "регистрирую в DKMS"
dkms remove -m "$PKG" -v "$VER" --all >/dev/null 2>&1 || true
dkms add    -m "$PKG" -v "$VER"       2>&1 | sed 's/^/   /'
dkms build  -m "$PKG" -v "$VER"       2>&1 | tail -6 | sed 's/^/   /'
dkms status 2>/dev/null | grep -q "^$PKG.*$KREL" \
    || die "сборка не прошла — смотри /var/lib/dkms/$PKG/$VER/build/make.log"
dkms install -m "$PKG" -v "$VER" --force 2>&1 | sed 's/^/   /'

# ------------------------------------------------------------- параметр -----
cat >"$MODPROBE_CONF" <<EOF
# e3372-driver: обход бага rndis_host (разрыв RNDIS-сообщений между URB).
# 0 вернёт штатное поведение ядра — медленно, но безопасно.
options rndis_host rx_urb_size_override=$SIZE
EOF
depmod -a

# ------------------------------------------------------------- проверка -----
f=$(modinfo rndis_host 2>/dev/null | awk '/^filename/{print $2}')
case "$f" in
    */updates/*) log "OK — активен исправленный модуль ($f)" ;;
    *)           warn "загружается штатный модуль ($f). Перезагрузи: rmmod rndis_host && modprobe rndis_host" ;;
esac
