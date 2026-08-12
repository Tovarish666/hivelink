#!/usr/bin/env bash
# =============================================================================
#  e3372-driver — установка.
#
#    bash <(curl -fsSL https://raw.githubusercontent.com/Tovarish666/hivelink/main/install.sh)
#  либо из клона репозитория:
#    git clone … && cd e3372-proxmox && sudo bash install.sh
#
#  Идемпотентно. Root. Debian 12/13, Proxmox VE 8/9, amd64.
# =============================================================================
set -uo pipefail

REPO_RAW="https://raw.githubusercontent.com/Tovarish666/hivelink/main"
TAR_URLS=(
  "https://codeload.github.com/Tovarish666/hivelink/tar.gz/refs/heads/main"
  "https://github.com/Tovarish666/hivelink/archive/refs/heads/main.tar.gz"
)

PREFIX_LIB=/usr/local/lib/e3372
PREFIX_SBIN=/usr/local/sbin
PREFIX_BIN=/usr/local/bin
CONFDIR=/etc/e3372

c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_r=$'\033[1;31m'; c_0=$'\033[0m'
log()  { printf '%s[e3372]%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s[e3372]%s %s\n' "$c_y" "$c_0" "$*"; }
die()  { printf '%s[e3372] %s%s\n' "$c_r" "$*" "$c_0" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "нужен root"
command -v systemctl >/dev/null 2>&1 || die "нужен systemd"
[ -d /etc/systemd/network ] || mkdir -p /etc/systemd/network

# ---------------------------------------------------------------------------
# 1. Исходники: локальный клон или архив с GitHub
# ---------------------------------------------------------------------------
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) || SELF_DIR=""
SRC=""
if [ -n "$SELF_DIR" ] && [ -r "$SELF_DIR/lib/common.sh" ]; then
    SRC="$SELF_DIR"
    log "1/8 ставлю из локального дерева: $SRC"
else
    command -v curl >/dev/null 2>&1 || die "нужен curl (apt install curl)"
    log "1/8 качаю репозиторий с GitHub…"
    WORK=$(mktemp -d) || die "нет /tmp"
    trap 'rm -rf "$WORK"' EXIT
    ok=0
    for url in "${TAR_URLS[@]}"; do
        echo "      → $url"
        curl -fL --retry 5 --retry-delay 2 --retry-connrefused \
             --connect-timeout 30 --max-time 900 -o "$WORK/repo.tgz" "$url" && { ok=1; break; }
        warn "не вышло, пробую следующее зеркало…"
    done
    [ "$ok" = 1 ] || die "не скачал архив (нет связи с github.com)"
    tar -xzf "$WORK/repo.tgz" -C "$WORK" || die "битый архив"
    # Имя каталога в архиве зависит от имени репозитория, поэтому ищем не по
    # имени, а по содержимому: единственный каталог верхнего уровня с lib/common.sh
    SRC=$(find "$WORK" -maxdepth 3 -type f -name common.sh -path '*/lib/*' \
          -printf '%h\n' 2>/dev/null | head -1)
    SRC="${SRC%/lib}"
    [ -n "$SRC" ] && [ -r "$SRC/lib/common.sh" ] || die "в архиве нет lib/common.sh — неожиданно"
fi

# ---------------------------------------------------------------------------
# 2. Зависимости.
#
#    usb_modeswitch критичен: без него модемы навсегда остаются в Zero-CD, а это
#    первая задача драйвера. Раньше здесь всё уходило в /dev/null, установка
#    проходила вхолостую и на выходе была одна строчка предупреждения, которую
#    легко пролистать. Теперь: ничего не глушится, apt не спрашиваем о том, что
#    ставить (его симуляция и возвращала пустой список), в конце жёсткая проверка.
# ---------------------------------------------------------------------------
log "2/8 зависимости…"
DEBDIR="$SRC/deb"
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'; }

NEED=""
pkg_installed usb-modeswitch       || NEED="$NEED usb-modeswitch"
pkg_installed usb-modeswitch-data  || NEED="$NEED usb-modeswitch-data"
pkg_installed libusb-1.0-0         || NEED="$NEED libusb-1.0-0"
command -v curl    >/dev/null 2>&1 || NEED="$NEED curl"
command -v ethtool >/dev/null 2>&1 || NEED="$NEED ethtool"
command -v lsusb   >/dev/null 2>&1 || NEED="$NEED usbutils"

if [ -z "${NEED// /}" ]; then
    log "    всё нужное уже установлено"
else
    log "    не хватает:$NEED"
    # Попытка 1: вшитые .deb напрямую через dpkg. Берём ровно те пакеты, которых
    # нет в системе, поэтому downgrade установленного исключён по построению.
    files=()
    for p in $NEED; do
        fp=$(ls "$DEBDIR/${p}_"*.deb 2>/dev/null | head -1)
        if [ -n "$fp" ]; then files+=("$fp"); else warn "    в deb/ нет пакета $p"; fi
    done
    if [ "${#files[@]}" -gt 0 ]; then
        log "    ставлю из вшитого репо (${#files[@]} .deb)…"
        dpkg -i "${files[@]}" 2>&1 | sed 's/^/      /'
        dpkg --configure -a 2>&1 | sed 's/^/      /'
    fi
    # Попытка 2: сеть — только для того, что после этого всё ещё отсутствует.
    STILL=""
    for p in $NEED; do pkg_installed "$p" || STILL="$STILL $p"; done
    if [ -n "${STILL// /}" ]; then
        warn "после вшитого репо не хватает:$STILL — пробую apt из сети"
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $STILL 2>&1 \
            | tail -n 8 | sed 's/^/      /'
    fi
fi

if ! command -v usb_modeswitch >/dev/null 2>&1; then
    if [ "${SKIP_MODESWITCH:-0}" = 1 ]; then
        warn "usb_modeswitch нет, но задан SKIP_MODESWITCH=1 — продолжаю без Zero-CD"
    else
        die "usb_modeswitch так и не установился.
     Модемы в Zero-CD (12d1:1f01) переключить нечем — это первая задача драйвера,
     поэтому установка остановлена, чтобы вы не получили молча неработающий парк.
     Поставьте вручную и запустите снова:
         apt-get install -y usb-modeswitch usb-modeswitch-data
     Продолжить без Zero-CD:  SKIP_MODESWITCH=1 bash install.sh"
    fi
fi
for c in curl ethtool; do
    command -v "$c" >/dev/null 2>&1 || warn "$c отсутствует — часть диагностики будет недоступна"
done

modprobe -a cdc_ether rndis_host cdc_ncm huawei_cdc_ncm >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 3. Файлы
# ---------------------------------------------------------------------------
log "3/8 раскладываю файлы…"
install -d "$PREFIX_LIB" "$PREFIX_SBIN" "$PREFIX_BIN" "$CONFDIR" \
           /etc/usb_modeswitch.d /etc/systemd/network /etc/udev/rules.d /etc/sysctl.d \
           /var/lib/e3372
install -m 0644 "$SRC/lib/common.sh"                  "$PREFIX_LIB/common.sh"
install -m 0755 "$SRC/sbin/e3372-reconcile"           "$PREFIX_SBIN/e3372-reconcile"
install -m 0755 "$SRC/bin/e3372-status"               "$PREFIX_BIN/e3372-status"
install -m 0755 "$SRC/bin/e3372-ctl"                  "$PREFIX_BIN/e3372-ctl"
install -m 0755 "$SRC/bin/e3372-doctor"               "$PREFIX_BIN/e3372-doctor"
install -m 0644 "$SRC/systemd/25-e3372.network"       /etc/systemd/network/25-e3372.network
install -m 0644 "$SRC/systemd/e3372-reconcile.service" /etc/systemd/system/e3372-reconcile.service
install -m 0644 "$SRC/systemd/e3372-reconcile.timer"   /etc/systemd/system/e3372-reconcile.timer
install -m 0644 "$SRC/udev/70-e3372.rules"            /etc/udev/rules.d/70-e3372.rules
install -m 0644 "$SRC/udev/71-e3372-ports.rules"      /etc/udev/rules.d/71-e3372-ports.rules
install -m 0644 "$SRC/sysctl/99-e3372.conf"           /etc/sysctl.d/99-e3372.conf
# конфиг пользователя не перезаписываем никогда
if [ ! -f "$CONFDIR/e3372.conf" ]; then
    install -m 0644 "$SRC/etc/e3372.conf" "$CONFDIR/e3372.conf"
else
    install -m 0644 "$SRC/etc/e3372.conf" "$CONFDIR/e3372.conf.new"
    warn "конфиг сохранён: свой оставлен, новый рядом как e3372.conf.new"
fi

# --- прежняя версия репозитория: снять то, что больше не используется --------
for old in /etc/networkd-dispatcher/routable.d/50-e3372 \
           /usr/local/sbin/e3372-watchdog.sh \
           /etc/systemd/network/25-hilink.network \
           /etc/systemd/system/e3372-watchdog.service \
           /etc/systemd/system/e3372-watchdog.timer; do
    [ -e "$old" ] || continue
    systemctl disable --now e3372-watchdog.timer >/dev/null 2>&1 || true
    rm -f "$old"
    warn "убран артефакт прошлой версии: $old"
done

# ---------------------------------------------------------------------------
# 4. usb_modeswitch: Zero-CD PID по FcSwitch.inf
# ---------------------------------------------------------------------------
log "4/8 usb_modeswitch: Zero-CD PID (вкл. ветку Vodafone K5150/K5160)…"
# 14fe/1505/155a/1c0b ставили прошлые версии — это switcher-serial PID
# (ew_hwusbdev.inf), а не mass storage. Конфиг для них бесполезен, убираем.
for stale in 14fe 1505 155a 1c0b; do
    cfg="/etc/usb_modeswitch.d/12d1:$stale"
    if [ -f "$cfg.e3372.bak" ]; then mv -f "$cfg.e3372.bak" "$cfg"
    elif [ -f "$cfg" ] && grep -q '^HuaweiNewMode=1' "$cfg" 2>/dev/null; then rm -f "$cfg"; fi
done
for pid in 1f01 1f02 1f10 1f11 1f12 1f13 1f14 1440; do
    cfg="/etc/usb_modeswitch.d/12d1:$pid"
    [ -f "$cfg" ] && [ ! -f "$cfg.e3372.bak" ] && cp -a "$cfg" "$cfg.e3372.bak"
    install -m 0644 "$SRC/modeswitch/zerocd.conf" "$cfg"
done

# --- перехват автоматики usb_modeswitch --------------------------------------
#
# /lib/udev/rules.d/40-usb_modeswitch.rules дёргает usb_modeswitch на КАЖДОМ
# устройстве вендора независимо и без координации. На двух десятках модемов это
# шторм, а его диспетчер при неудаче перебирает USB-конфигурации и уводит
# устройство в конфигурацию с MBIM, где mass-storage endpoint отсутствует и
# переключение невозможно в принципе.
#
# Наблюдалось вживую: драйвер ставит cfg 1, автоматика возвращает cfg 2,
# и так по кругу — Zero-CD не дожимается никогда.
#
# Одноимённый файл в /etc полностью отменяет тот, что в /lib. Копируем штатный,
# добавляя ранний выход для 12d1: этим вендором управляет драйвер сам, под
# flock и со счётчиками попыток. Для остальных устройств поведение штатное.
STOCK_MS=/lib/udev/rules.d/40-usb_modeswitch.rules
OUR_MS=/etc/udev/rules.d/40-usb_modeswitch.rules
if [ -f "$STOCK_MS" ]; then
    {
        printf '# e3372-driver: перехват штатного авто-переключения.\n'
        printf '# Копия %s с ранним выходом для 12d1 —\n' "$STOCK_MS"
        printf '# этим вендором управляет e3372-reconcile сам, под блокировкой.\n'
        printf '# Файл пересоздаётся установщиком и удаляется uninstall.sh.\n#\n'
        awk '
            !ins && /^ACTION!=/ {
                print
                printf "\n# Huawei переключает e3372-reconcile сам\nATTRS{idVendor}==\"12d1\", GOTO=\"modeswitch_rules_end\"\n"
                ins = 1
                next
            }
            { print }
        ' "$STOCK_MS"
    } >"$OUR_MS"
    chmod 644 "$OUR_MS"
    log "    штатное авто-переключение перехвачено (12d1 обслуживает драйвер)"
else
    warn "    $STOCK_MS не найден — перехватывать нечего"
fi

# ---------------------------------------------------------------------------
# 5. sysctl
# ---------------------------------------------------------------------------
log "5/8 sysctl…"
sysctl -q --system >/dev/null 2>&1 || warn "sysctl --system с предупреждениями"

# ---------------------------------------------------------------------------
# 6. Фикс скорости приёма (баг rndis_host).
#
#    Драйвер сообщает модему max_transfer_size = 2048, тот режет батчи под это
#    число, и RNDIS-сообщения перестают помещаться в один URB. Собирать
#    сообщение через границу URB rndis_host не умеет — ~85% приёма уходит
#    в ошибки, download падает до ~1.3 Мбит при совершенно здоровом upload.
#    Замерено на K5160: было 1.26, стало 46.58 Мбит/с.
#
#    Ставится DKMS-пакетом, чтобы переживать обновления ядра. Шаг
#    необязательный: если сборка не прошла, парк работает — просто медленно
#    на приём. Отключается через SKIP_RNDIS_FIX=1 или RX_URB_SIZE=0 в конфиге.
# ---------------------------------------------------------------------------
log "6/8 фикс скорости приёма (DKMS)…"
# Инструменты раскладываем ВСЕГДА, даже когда сборка пропущена: иначе
# передумать и поставить фикс позже будет нечем.
if [ -r "$SRC/dkms/build.sh" ]; then
    install -d "$PREFIX_LIB/dkms"
    install -m 0755 "$SRC/dkms/build.sh" "$PREFIX_LIB/dkms/build.sh"
    install -m 0755 "$SRC/dkms/patch.py" "$PREFIX_LIB/dkms/patch.py"
fi

if [ "${SKIP_RNDIS_FIX:-0}" = 1 ]; then
    warn "    пропущен по SKIP_RNDIS_FIX=1 — приём на RNDIS-модемах останется ~1.3 Мбит"
    warn "    поставить позже: bash $PREFIX_LIB/dkms/build.sh"
elif [ ! -r "$PREFIX_LIB/dkms/build.sh" ]; then
    warn "    в дереве нет dkms/build.sh — пропускаю"
else
    # build.sh сам перезагружает модуль и проверяет, что параметр реально
    # появился в /sys/module — раньше здесь стоял rmmod с проглоченной
    # ошибкой, и фикс молча оставался «установлен, но не загружен».
    if bash "$PREFIX_LIB/dkms/build.sh" 2>&1 | sed 's/^/    /'; then
        log "    фикс установлен и активен"
    else
        warn "    фикс не заработал — парк поднимется, но приём будет ~1.3 Мбит"
        warn "    разбор: bash $PREFIX_LIB/dkms/build.sh"
    fi
fi

# ---------------------------------------------------------------------------
# 7. Сервисы. Снимок resolv.conf до перезапуска networkd — если модемы его
#    обнулят, хост ослепнет, а мы это заметим только по симптомам.
# ---------------------------------------------------------------------------
log "7/8 сервисы…"
RESOLV_BAK=$(mktemp); cp -a /etc/resolv.conf "$RESOLV_BAK" 2>/dev/null || true

udevadm control --reload >/dev/null 2>&1 || true
udevadm trigger --subsystem-match=usb --attr-match=idVendor=12d1 >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable --now systemd-networkd >/dev/null 2>&1 || true
systemctl restart systemd-networkd >/dev/null 2>&1 || true
systemctl enable --now e3372-reconcile.timer >/dev/null 2>&1 \
    || die "не удалось включить e3372-reconcile.timer"

sleep 2
if [ ! -L /etc/resolv.conf ] && ! grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; then
    warn "resolv.conf остался без nameserver — восстанавливаю"
    if grep -q '^nameserver' "$RESOLV_BAK" 2>/dev/null; then cp -a "$RESOLV_BAK" /etc/resolv.conf
    else printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf; fi
fi
rm -f "$RESOLV_BAK"

# ---------------------------------------------------------------------------
# 7. Первый проход
# ---------------------------------------------------------------------------
log "8/8 первый проход драйвера…"
"$PREFIX_SBIN/e3372-reconcile" || true

echo
log "готово. Драйвер работает сам: udev-триггер + таймер каждые 15с."
echo "   состояние:   e3372-status"
echo "   диагностика: e3372-doctor"
echo "   вручную:     e3372-ctl run | dataon --all | reset N | recfg --all"
echo "   журнал:      journalctl -t e3372 -f"
echo
warn "парк из десятков модемов сходится не мгновенно: Zero-CD, перебор"
warn "USB-конфигураций и дозвон занимают несколько циклов. Смотрите e3372-status"
warn "через 2-3 минуты после включения, а не сразу."
