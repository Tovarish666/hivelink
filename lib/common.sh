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
HL_SLOT_MIN=2                   # диапазон номеров модемов (3-й октет подсети)
HL_SLOT_MAX=254                 # 253 модема на префикс; больше — меняй HL_SUBNET_PREFIX
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

# ------------------------------------------------------------- масштаб -----
# Модемов может быть под три сотни. Структурная часть цикла дешёвая (только
# sysfs и ip), а вот пинги и веб-API стоят секунд — поэтому они идут
# параллельно и не на каждом цикле.

HL_PARALLEL=auto                # число рабочих потоков; auto = nproc, максимум 32
HL_HEALTH_INTERVAL=120          # как часто проверять живость каждого модема, сек
HL_GC=1                         # убирать правила и маршруты исчезнувших слотов

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

# Логгер зовётся по несколько раз на каждый модем. При двух сотнях модемов
# любая подоболочка или проверка внешней команды внутри него превращается
# в тысячи запусков процессов, поэтому всё решается заранее и один раз.

case "$HL_LOG_LEVEL" in
    debug) _HL_LVL=10 ;; warn) _HL_LVL=30 ;; error) _HL_LVL=40 ;; *) _HL_LVL=20 ;;
esac

if command -v systemd-cat >/dev/null 2>&1; then _HL_CAT=1; else _HL_CAT=0; fi

case "$HL_LOG_STDERR" in
    1) _HL_ERR=1 ;;
    0) _HL_ERR=0 ;;
    *) if [ -t 2 ]; then _HL_ERR=1; else _HL_ERR=0; fi ;;
esac

log() {
    local lvl="$1"; shift
    local num pri c
    case "$lvl" in
        debug) num=10; pri=7; c='\033[90m' ;;
        info)  num=20; pri=6; c='\033[36m' ;;
        warn)  num=30; pri=4; c='\033[33m' ;;
        error) num=40; pri=3; c='\033[31m' ;;
        *)     num=20; pri=6; c='' ;;
    esac
    [ "$num" -ge "$_HL_LVL" ] || return 0

    [ "$_HL_CAT" = 1 ] && printf '%s\n' "$*" | systemd-cat -t hivelink -p "$pri" 2>/dev/null
    [ "$_HL_ERR" = 1 ] && printf "${c}%-5s\033[0m %s\n" "$lvl" "$*" >&2
    return 0
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

    # Без flock блокировки не будет. Это деградация, а не повод молча выйти:
    # цикл всё равно должен отработать, но пользователь обязан узнать почему.
    if ! command -v flock >/dev/null 2>&1; then
        err "нет flock (apt install util-linux) — работаю БЕЗ блокировки;"
        err "при одновременном запуске возможны гонки за маршруты"
        return 0
    fi

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

declare -A HL_MAP_PORT2SLOT=()   # usb-путь -> номер
declare -A HL_MAP_USED=()        # номер -> занят

hl_state_init() {
    mkdir -p "$HL_VAR" "$HL_RUN"
    [ -f "$HL_SLOTS" ]   || : >"$HL_SLOTS"
    [ -f "$HL_CONFMAP" ] || : >"$HL_CONFMAP"
    hl_slots_load
}

# Карта грузится в память один раз за цикл. При 200 модемах любой поиск
# через awk или grep превращается в тысячи запусков процессов, поэтому
# вся работа с номерами идёт по ассоциативным массивам.
hl_slots_load() {
    local p n pin
    HL_MAP_PORT2SLOT=(); HL_MAP_USED=()
    while read -r p n; do
        [ -n "${p:-}" ] && [ -n "${n:-}" ] || continue
        HL_MAP_PORT2SLOT["$p"]="$n"
        HL_MAP_USED["$n"]=1
    done <"$HL_SLOTS"
    # Закреплённые в конфиге номера тоже заняты, иначе автовыдача
    # наступит на пин и два модема получат один адрес.
    for pin in $HL_SLOT_PIN; do
        [ -n "$pin" ] && HL_MAP_USED["${pin#*:}"]=1
    done
}

# Номер модема по USB-пути. Привязка вечная: тот же физический порт —
# всегда тот же N, независимо от порядка появления и от того, кто поднялся первым.
#
# Порядок разрешения:
#   1) HL_SLOT_PIN из конфига — декларативно, переживает потерю состояния
#   2) ранее выданный номер из карты слотов
#   3) первый свободный номер, с записью в карту
hl_slot_for_port() {
    local port="$1" n pin old n2

    # 1) пин из конфига
    for pin in $HL_SLOT_PIN; do
        case "$pin" in
            "$port":*)
                n="${pin#*:}"
                # В карте мог остаться старый автономер этого же порта.
                # Если его не снять, он навечно займёт номер, который никому
                # уже не принадлежит, и следующий модем получит не тот адрес.
                old="${HL_MAP_PORT2SLOT[$port]:-}"
                if [ -n "$old" ] && [ "$old" != "$n" ]; then
                    warn "порт $port: пин $n перекрывает выданный ранее $old — снимаю старую запись"
                    hl_slot_forget_port "$port"
                    hl_slot_mark_stale "$old"
                    unset "HL_MAP_PORT2SLOT[$port]" "HL_MAP_USED[$old]"
                fi
                printf '%s\n' "$n"; return 0 ;;
        esac
    done

    # 2) ранее выданный
    n="${HL_MAP_PORT2SLOT[$port]:-}"
    if [ -n "$n" ]; then printf '%s\n' "$n"; return 0; fi

    # 3) первый свободный
    n2="$HL_SLOT_MIN"
    while [ "$n2" -le "$HL_SLOT_MAX" ]; do
        [ -z "${HL_MAP_USED[$n2]:-}" ] && break
        n2=$((n2 + 1))
    done
    [ "$n2" -le "$HL_SLOT_MAX" ] || {
        err "кончились номера ($HL_SLOT_MIN..$HL_SLOT_MAX), это потолок в $((HL_SLOT_MAX - HL_SLOT_MIN + 1)) модемов на префикс $HL_SUBNET_PREFIX"
        return 1
    }

    printf '%s %s\n' "$port" "$n2" >>"$HL_SLOTS"
    HL_MAP_PORT2SLOT["$port"]="$n2"
    HL_MAP_USED["$n2"]=1
    info "новый модем на порту $port -> слот $n2 (закреплено навсегда)"
    printf '%s\n' "$n2"
}

hl_port_for_slot() { awk -v n="$1" '$2==n{print $1; exit}' "$HL_SLOTS" 2>/dev/null; }

hl_slot_forget_port() {
    local port="$1" tmp
    tmp=$(mktemp "$HL_SLOTS.XXXXXX" 2>/dev/null) || return 0
    awk -v p="$port" '$1!=p' "$HL_SLOTS" 2>/dev/null >"$tmp" && mv -f "$tmp" "$HL_SLOTS"
    rm -f "$tmp" 2>/dev/null
    return 0
}

# Номер, переставший принадлежать порту. Помечаем, чтобы сборщик мусора
# снял его правило и таблицу маршрутов, а не оставил перехватывать чужой трафик.
hl_slot_mark_stale() { printf '%s\n' "$1" >>"$HL_RUN/stale-slots"; }

hl_confmap_get() { awk -v k="$1" '$1==k{print $2; exit}' "$HL_CONFMAP" 2>/dev/null; }

# Пишется из параллельных рабочих потоков, поэтому под собственным локом:
# без него read-modify-write двух потоков затрёт друг друга.
# Нет flock — пишем без него: потерять запись кэша не страшно,
# а вот молча не писать вообще — это уже скрытый отказ.
hl_confmap_set() {
    local k="$1" v="$2" tmp lfd locked=0
    # НЕ "$HL_CONFMAP.$$": в фоновом процессе bash подставляет PID родителя,
    # и все параллельные потоки получат одно и то же имя файла.
    tmp=$(mktemp "$HL_CONFMAP.XXXXXX" 2>/dev/null) || return 0

    if command -v flock >/dev/null 2>&1; then
        if exec {lfd}>"$HL_RUN/confmap.lock" 2>/dev/null; then
            flock -w 5 "$lfd" 2>/dev/null && locked=1
        fi
    fi

    { awk -v k="$k" '$1!=k' "$HL_CONFMAP" 2>/dev/null
      printf '%s %s\n' "$k" "$v"; } >"$tmp" && mv -f "$tmp" "$HL_CONFMAP"
    rm -f "$tmp" 2>/dev/null

    [ "$locked" = 1 ] && exec {lfd}>&-
    return 0
}

# Число рабочих потоков: столько ядер, сколько есть, но не больше 32 —
# упираемся не в CPU, а в таймауты пингов и веб-API.
hl_parallelism() {
    local p="${HL_PARALLEL:-auto}"
    if [ "$p" = auto ]; then
        p=$(nproc 2>/dev/null || echo 4)
        p=$((p * 2))
    fi
    [ "$p" -lt 1 ] 2>/dev/null && p=1
    [ "$p" -gt 32 ] 2>/dev/null && p=32
    printf '%s\n' "$p"
}

# ---------------------------------------------------------------- адреса ----

hl_net()  { printf '%s.%s'    "$HL_SUBNET_PREFIX" "$1"; }               # 192.168.N
hl_host() { printf '%s.%s.%s' "$HL_SUBNET_PREFIX" "$1" "$HL_HOST_OCTET"; }
hl_gw()   { printf '%s.%s.%s' "$HL_SUBNET_PREFIX" "$1" "$HL_GW_OCTET"; }
hl_table(){ printf '%s' "$((HL_TABLE_BASE + $1))"; }
hl_iface(){ printf '%s%s' "$HL_IFACE_PREFIX" "$1"; }
