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

# ------------------------------------------------------------- initramfs ----
#
# Debian по умолчанию собирает initramfs с MODULES=most, то есть кладёт туда
# и USB-сетевые драйверы. При загрузке udev ВНУТРИ initramfs видит модемы и
# грузит ШТАТНЫЙ rndis_host из образа. К моменту монтирования настоящего корня
# модуль уже в памяти, /etc/modprobe.d не применяется, и фикс молча не работает
# после каждой перезагрузки — при том что modinfo показывает правильный файл.
#
# Поэтому пересобираем образ, чтобы туда попал модуль из /updates.
if command -v update-initramfs >/dev/null 2>&1; then
    IMG="/boot/initrd.img-$KREL"
    before=0
    command -v lsinitramfs >/dev/null 2>&1 && [ -r "$IMG" ] &&
        before=$(lsinitramfs "$IMG" 2>/dev/null | grep -c 'rndis_host' || echo 0)
    if [ "$before" -gt 0 ] 2>/dev/null; then
        log "в initramfs лежит свой rndis_host — пересобираю образ"
        if update-initramfs -u -k "$KREL" >/tmp/e3372-initramfs.log 2>&1; then
            after=$(lsinitramfs "$IMG" 2>/dev/null | grep -c 'rndis_host' || echo 0)
            log "  готово, вхождений rndis_host в образе: было $before, стало $after"
        else
            warn "  update-initramfs не отработал, подробности в /tmp/e3372-initramfs.log"
            warn "  без этого фикс не переживёт перезагрузку"
        fi
    else
        log "в initramfs своего rndis_host нет — пересобирать не нужно"
    fi
else
    warn "нет update-initramfs — если модуль попадёт в initramfs, фикс не переживёт ребут"
fi

# --------------------------------------------------- перезагрузка модуля ----
#
# Файл на диске подменён, но в памяти остаётся СТАРЫЙ модуль: простой rmmod
# не может выгрузить драйвер, к которому привязаны интерфейсы, и молча падает.
# Ровно на этом фикс однажды оказался «установлен, но не работает»: modinfo
# показывал пропатченный файл, а /sys/module/.../rx_urb_size_override
# отсутствовал, и приём продолжал сыпаться.
#
# Поэтому: сначала отвязываем все устройства, потом выгружаем, потом грузим
# и ПРОВЕРЯЕМ, что параметр появился.

# Подмена модуля гонится с самим драйвером: его таймер тикает каждые 15 секунд
# и привязывает интерфейсы обратно, пока мы пытаемся выгрузить модуль. rmmod
# падает, modprobe для уже загруженного модуля — пустышка, и в памяти остаётся
# старое значение при новом конфиге. Наблюдалось: четыре неудачных попытки
# подряд из скрипта, а вручную минутой позже — с первой.
#
# Поэтому на время подмены глушим таймер и возвращаем его в конце при любом
# исходе.
log "перезагружаю модуль"
TIMER_WAS=$(systemctl is-active e3372-reconcile.timer 2>/dev/null || echo unknown)
if [ "$TIMER_WAS" = active ]; then
    systemctl stop e3372-reconcile.timer >/dev/null 2>&1
    log "  таймер драйвера приостановлен на время подмены"
fi
restore_timer() {
    [ "$TIMER_WAS" = active ] && systemctl start e3372-reconcile.timer >/dev/null 2>&1
    return 0
}
trap restore_timer EXIT

# Запоминаем, что отвязали: обратно оно само НЕ вернётся. udevadm trigger
# явно отвязанный интерфейс не переподключает, и модемы остаются без сетевой
# функции — наблюдалось: пять устройств после подмены пропали из парка.
UNBOUND=""

i=1
while [ "$i" -le 5 ]; do
    n=0
    for l in /sys/bus/usb/drivers/rndis_host/*:*; do
        [ -e "$l" ] || continue
        b=$(basename "$l")
        if echo "$b" > /sys/bus/usb/drivers/rndis_host/unbind 2>/dev/null; then
            n=$((n + 1))
            case " $UNBOUND " in *" $b "*) ;; *) UNBOUND="$UNBOUND $b" ;; esac
        fi
    done
    [ "$n" -gt 0 ] && log "  попытка $i: отвязано интерфейсов $n"
    sleep 3
    if lsmod | grep -q '^rndis_host'; then
        rmmod rndis_host 2>/dev/null || log "  попытка $i: модуль ещё занят, жду"
    fi
    lsmod | grep -q '^rndis_host' || modprobe rndis_host 2>/dev/null
    [ "$(cat /sys/module/rndis_host/parameters/rx_urb_size_override 2>/dev/null)" = "$SIZE" ] && break
    i=$((i + 1))
done

# Возвращаем ровно то, что отвязали.
back=0
for b in $UNBOUND; do
    [ -d "/sys/bus/usb/devices/$b" ] || continue
    [ -e "/sys/bus/usb/devices/$b/driver" ] && continue
    echo "$b" > /sys/bus/usb/drivers/rndis_host/bind 2>/dev/null && back=$((back + 1))
done

# Подстраховка: любой RNDIS-интерфейс (класс e0/01/03) без драйвера.
for l in /sys/bus/usb/devices/*:*; do
    [ -d "$l" ] || continue
    [ "$(cat "$l/bInterfaceClass" 2>/dev/null)" = "e0" ] || continue
    [ -e "$l/driver" ] && continue
    echo "$(basename "$l")" > /sys/bus/usb/drivers/rndis_host/bind 2>/dev/null && back=$((back + 1))
done
[ "$back" -gt 0 ] && log "  привязано обратно интерфейсов: $back"

udevadm trigger --subsystem-match=usb --attr-match=idVendor=12d1 >/dev/null 2>&1 || true
sleep 2

# ------------------------------------------------------------- проверка -----
f=$(modinfo rndis_host 2>/dev/null | awk '/^filename/{print $2}')
p=$(cat /sys/module/rndis_host/parameters/rx_urb_size_override 2>/dev/null)

log "проверка:"
log "  файл:     ${f:-не найден}"
log "  параметр: ${p:-ОТСУТСТВУЕТ}"

case "$f" in
    */updates/*) : ;;
    *) warn "  на диске штатный модуль — DKMS не подменил его" ;;
esac

if [ -n "$p" ] && [ "$p" != "$SIZE" ] && [ "$p" != 0 ]; then
    warn "  в памяти $p, а в конфиге $SIZE — модуль не перезагрузился за 4 попытки."
    warn "  Освободи драйвер и повтори, либо перезагрузи хост."
    exit 1
fi

if [ -z "$p" ]; then
    warn "  ПАРАМЕТРА НЕТ: в памяти загружен старый модуль, фикс НЕ работает."
    warn "  Освободи драйвер и повтори, либо перезагрузи хост:"
    warn "     for l in /sys/bus/usb/drivers/rndis_host/*:*; do echo \$(basename \$l) > /sys/bus/usb/drivers/rndis_host/unbind; done"
    warn "     rmmod rndis_host && modprobe rndis_host"
    exit 1
elif [ "$p" = 0 ]; then
    warn "  параметр 0 — фикс выключен, приём останется ~1.3 Мбит"
else
    log "  OK — фикс активен, rx_urb_size = $p"
fi
