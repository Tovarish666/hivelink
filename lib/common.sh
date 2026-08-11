#!/bin/bash
# hivelink / common.sh — общая база: конфиг, лог, блокировки, состояние.
# Подключается всеми остальными модулями:  . /opt/hivelink/lib/common.sh

# shellcheck disable=SC2034

HL_LIB="${HL_LIB:-/opt/hivelink/lib}"
HL_ETC="${HL_ETC:-/etc/hivelink}"
HL_VAR="${HL_VAR:-/var/lib/hivelink}"
HL_RUN="${HL_RUN:-/run/hivelink}"
HL_CONF="$HL_ETC/hivelink.conf"

# ------------------------------------------------------------- умолчания ----
# Всё это перекрывается в /etc/hivelink/hivelink.conf

HL_SUBNET_PREFIX="192.168"      # модем N живёт в $PREFIX.$N.0/24
HL_HOST_OCTET=100               # адрес хоста в подсети модема
HL_GW_OCTET=1                   # адрес модема (веб-морда HiLink)
HL_TABLE_BASE=10000             # таблица policy routing = BASE + N
HL_SLOT_MIN=101                 # диапазон номеров модемов
HL_SLOT_MAX=250
HL_IFACE_PREFIX="mdm"           # имя интерфейса = mdm<N>

# Жёсткая привязка «USB-порт:номер» через пробел, например "3-3:104 3-1.4.1.1:101".
# Приоритет надо всем: нужна, когда номер уже зашит во внешние системы
# (прокси, правила, выгрузки) и менять адрес нельзя.
HL_SLOT_PIN=""

HL_PREFER_DRIVER="auto"         # auto | rndis_host | cdc_ether | cdc_ncm
HL_RX_URB_SIZE=16384            # обход бага rndis_host, 0 = штатное поведение
HL_DNS_GUARD=1                  # не пускать DNS модема в системный резолвер
HL_DHCP=0                       # 0 = статика на хосте, 1 = DHCP от модема

HL_HILINK_ENABLE=1              # ходить в веб-API модема
HL_HILINK_TIMEOUT=6
HL_HILINK_DATASWITCH=1          # включать передачу данных, если выключена

HL_ZEROCD_TRIES=3               # попыток usb_modeswitch до re-enumerate
HL_MODESWITCH_REQUIRED=1        # 1 = отсутствие usb_modeswitch это ОШИБКА

HL_WATCHDOG_ENABLE=1
HL_WATCHDOG_PING="1.1.1.1"      # что пинговать через модем для проверки живости
HL_WATCHDOG_FAILS=3             # неудач подряд до эскалации
HL_WATCHDOG_ESCALATE=1          # 1 = разрешить usb reset при глухом модеме

HL_LOG_LEVEL=info               # debug | info | warn | error
HL_LOG_STDERR=auto              # auto | 1 | 0  (auto: в tty пишем, иначе только journal)

# Реестр устройств: "vid:pid  семейство  предпочтительный_драйвер"
# Семейства: hilink (веб-API + DHCP от модема), ncm, ether, generic
HL_REGISTRY_DEFAULT='
12d1:14db hilink rndis_host
12d1:14dc hilink cdc_ether
12d1:1506 ncm    cdc_ncm
12d1:155e hilink rndis_host
12d1:14ac hilink cdc_ether
12d1:1442 hilink cdc_ether
'
# PID «установочного» Zero-CD режима — их надо переключать
HL_ZEROCD_PIDS="1f01 1f02 1f10 1f11 1f12 1f13 1f14 1440"
# Вендоры, которые вообще рассматриваем как модемы
HL_VENDORS="12d1"

[ -r "$HL_CONF" ] && . "$HL_CONF"

HL_REGISTRY="${HL_REGISTRY:-$HL_REGISTRY_DEFAULT}"

# ------------------------------------------------------------------- лог ----

_hl_lvl_num() {
    case "$1" in
        debug) echo 10 ;; info) echo 20 ;;
        warn)  echo 30 ;; error) echo 40 ;; *) echo 20 ;;
    esac
}

_HL_LVL=$(_hl_lvl_num "$HL_LOG_LEVEL")

_hl_want_stderr() {
    case "$HL_LOG_STDERR" in
        1) return 0 ;;
        0) return 1 ;;
        *) [ -t 2 ] ;;
    esac
}

log() {
    local lvl="$1"; shift
    [ "$(_hl_lvl_num "$lvl")" -ge "$_HL_LVL" ] || return 0
    local msg="$*"
    local pri
    case "$lvl" in
        debug) pri=7 ;; info) pri=6 ;; warn) pri=4 ;; error) pri=3 ;; *) pri=6 ;;
    esac
    command -v systemd-cat >/dev/null 2>&1 &&
        printf '%s\n' "$msg" | systemd-cat -t hivelink -p "$pri" 2>/dev/null
    if _hl_want_stderr; then
        local c=""
        case "$lvl" in
            debug) c='\033[90m' ;; info) c='\033[36m' ;;
            warn)  c='\033[33m' ;; error) c='\033[31m' ;;
        esac
        printf "${c}%-5s\033[0m %s\n" "$lvl" "$msg" >&2
    fi
}

dbg()  { log debug "$@"; }
info() { log info  "$@"; }
warn() { log warn  "$@"; }
err()  { log error "$@"; }
die()  { log error "$@"; exit 1; }

# ------------------------------------------------------- жёсткие зависимости --
#
# Главный урок старого стека: пропавший usb_modeswitch молча выключал целую
# стадию, и это маскировалось месяцами. Здесь отсутствие обязательной утилиты
# либо валит цикл, либо громко орёт — но никогда не «return 0».

require() {
    local bin="$1" pkg="${2:-$1}" hard="${3:-1}"
    if command -v "$bin" >/dev/null 2>&1; then return 0; fi
    if [ "$hard" = 1 ]; then
        die "нет обязательной утилиты '$bin' (apt install $pkg) — стадия не может работать"
    fi
    warn "нет утилиты '$bin' (apt install $pkg) — функциональность урезана"
    return 1
}

# ------------------------------------------------------------- блокировки ---

hl_lock() {
    local name="${1:-global}" fd
    mkdir -p "$HL_RUN"
    exec {fd}>"$HL_RUN/$name.lock" || die "не открыть лок $name"
    if ! flock -w "${2:-60}" "$fd"; then
        warn "лок '$name' занят дольше ${2:-60}с — выхожу, отработает следующий цикл"
        exit 0
    fi
    eval "HL_LOCK_FD_$name=$fd"
}

# ------------------------------------------------------------- состояние ----
#
# slots   : usb-путь -> номер модема N        (лечит сдвиг портов)
# confmap : idProduct:bcdDevice -> драйвер    (кэш перебора конфигураций)

HL_SLOTS="$HL_VAR/slots"
HL_CONFMAP="$HL_VAR/confmap"

hl_state_init() {
    mkdir -p "$HL_VAR" "$HL_RUN"
    [ -f "$HL_SLOTS" ]   || : >"$HL_SLOTS"
    [ -f "$HL_CONFMAP" ] || : >"$HL_CONFMAP"
}

# Номер модема по USB-пути. Привязка вечная: тот же физический порт —
# всегда тот же N, независимо от порядка появления и от того, кто поднялся первым.
#
# Порядок разрешения:
#   1) HL_SLOT_PIN из конфига — декларативно, переживает потерю состояния
#   2) ранее выданный номер из карты слотов
#   3) первый свободный номер, с записью в карту
hl_slot_for_port() {
    local port="$1" n pin

    for pin in $HL_SLOT_PIN; do
        case "$pin" in
            "$port":*) printf '%s\n' "${pin#*:}"; return 0 ;;
        esac
    done

    n=$(awk -v p="$port" '$1==p{print $2; exit}' "$HL_SLOTS" 2>/dev/null)
    if [ -n "$n" ]; then printf '%s\n' "$n"; return 0; fi

    # Занятыми считаем и выданные ранее, и закреплённые в конфиге —
    # иначе автовыдача наступит на пин и два модема получат один адрес.
    local used n2
    used=$( { awk '{print $2}' "$HL_SLOTS" 2>/dev/null
              for pin in $HL_SLOT_PIN; do printf '%s\n' "${pin#*:}"; done
            } | sort -n )
    n2="$HL_SLOT_MIN"
    while [ "$n2" -le "$HL_SLOT_MAX" ]; do
        printf '%s\n' "$used" | grep -qx "$n2" || break
        n2=$((n2 + 1))
    done
    [ "$n2" -le "$HL_SLOT_MAX" ] || { err "кончились номера ($HL_SLOT_MIN..$HL_SLOT_MAX)"; return 1; }

    printf '%s %s\n' "$port" "$n2" >>"$HL_SLOTS"
    info "новый модем на порту $port -> слот $n2 (закреплено навсегда)"
    printf '%s\n' "$n2"
}

hl_port_for_slot() { awk -v n="$1" '$2==n{print $1; exit}' "$HL_SLOTS" 2>/dev/null; }

hl_confmap_get() { awk -v k="$1" '$1==k{print $2; exit}' "$HL_CONFMAP" 2>/dev/null; }
hl_confmap_set() {
    local k="$1" v="$2" tmp="$HL_CONFMAP.$$"
    awk -v k="$k" '$1!=k' "$HL_CONFMAP" 2>/dev/null >"$tmp"
    printf '%s %s\n' "$k" "$v" >>"$tmp"
    mv -f "$tmp" "$HL_CONFMAP"
}

# ---------------------------------------------------------------- адреса ----

hl_net()  { printf '%s.%s'    "$HL_SUBNET_PREFIX" "$1"; }               # 192.168.N
hl_host() { printf '%s.%s.%s' "$HL_SUBNET_PREFIX" "$1" "$HL_HOST_OCTET"; }
hl_gw()   { printf '%s.%s.%s' "$HL_SUBNET_PREFIX" "$1" "$HL_GW_OCTET"; }
hl_table(){ printf '%s' "$((HL_TABLE_BASE + $1))"; }
hl_iface(){ printf '%s%s' "$HL_IFACE_PREFIX" "$1"; }
