#!/bin/bash
# =============================================================================
#  e3372-driver — общая библиотека. Подключается всеми утилитами пакета.
#  Ничего не делает при подключении, только определяет функции и настройки.
# =============================================================================
# shellcheck shell=bash disable=SC2034

E3372_VERSION="2.2.0"

# ---------------------------------------------------------------------------
# Настройки по умолчанию. Переопределяются в /etc/e3372/e3372.conf
# ---------------------------------------------------------------------------
PREFER_DRIVER=rndis_host                          # целевой сетевой драйвер
FALLBACK_DRIVERS="cdc_ether"                      # приемлемо, если целевого нет
BAD_DRIVERS="huawei_cdc_ncm cdc_mbim cdc_ncm qmi_wwan"   # raw-IP, DHCP не работает
HOST_PREFIX="192.168"                             # префикс подсетей модемов
HOST_OCTET=100                                    # адрес, который модем даёт хосту
GW_OCTET=1                                        # адрес самого модема
RULE_PRIO_BASE=1000
CFG_MAX_TRIES=8                                   # перебор USB-конфигураций
ZEROCD_MAX_TRIES=3                                # попытки usb_modeswitch до re-enumerate
ZEROCD_PARALLEL=8                                 # сколько Zero-CD переключать разом
ZEROCD_WAIT=25                                    # сек: повтор для одного модема не раньше
NODRV_GRACE=3                                     # циклов ждать привязки драйвера
DHCP_MAX_TRIES=10                                 # подряд; дальше — раз в DHCP_RETRY_EVERY
DHCP_RETRY_EVERY=300
HILINK_EVERY=4                                    # раз в сколько циклов дёргать web-API
HILINK_CONCURRENCY=8
AUTO_DATASWITCH=1                                 # включать мобильные данные
AUTO_RECONNECT=1                                  # переподнимать соединение
RECONNECT_COOLDOWN=180                            # сек между попытками починки одного модема
AUTO_HEAL=1                                       # лестница починки (см. heal)
STUCK_GRACE=180                                   # сек: «коннектит»/«отключается» дольше — завис
HEAL_REBOOT_AFTER=600                             # сек без связи — перезагрузить модем
HEAL_REBOOT_EVERY=1800                            # перезагрузка одного модема не чаще
NETCHECK_EVERY=300                                # сек: у «онлайн» проверять, ходит ли трафик; 0 — нет
NETCHECK_FAILS=3                                  # неудач подряд — «онлайн, но трафика нет»
NETCHECK_HOST=1.1.1.1
API_DEAD_AFTER=600                                # сек: web-API молчит — заново подключить USB
API_REENUM_EVERY=1800
USB_AUTOSUSPEND_OFF=1
DNS_FALLBACK="1.1.1.1 8.8.8.8"
SKIP_SUBNET_COLLISION=1                           # не трогать модем, чья подсеть = сеть хоста
QUIET_REPEAT=300                                  # сек: не спамить одинаковым сообщением

[ -r /etc/e3372/e3372.conf ] && . /etc/e3372/e3372.conf

RUN=/run/e3372
VAR=/var/lib/e3372
LOCKFILE="$RUN/.lock"
mkdir -p "$RUN" "$VAR" 2>/dev/null

# ---------------------------------------------------------------------------
# Логирование. В journal под тегом e3372; на терминал — только если он есть.
# log_once подавляет повтор одинаковых сообщений чаще QUIET_REPEAT секунд,
# иначе при 40 модемах journal превращается в кашу.
# ---------------------------------------------------------------------------
TAG="${E3372_TAG:-e3372}"
now() { date +%s; }
log()  { logger -t "$TAG" -- "$*" 2>/dev/null; [ -t 2 ] && printf '%s\n' "$*" >&2; return 0; }
warn() { log "WARN: $*"; }

log_once() {
    local key ts last
    key=$(printf '%s' "$*" | tr -c 'A-Za-z0-9' '_' | cut -c1-80)
    ts=$(now); last=$(cat "$RUN/.msg.$key" 2>/dev/null || echo 0)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $(( ts - last )) -lt "$QUIET_REPEAT" ] && return 0
    printf '%s\n' "$ts" > "$RUN/.msg.$key" 2>/dev/null
    log "$@"
}

# ---------------------------------------------------------------------------
# Состояние. /run — переживает цикл, но не перезагрузку (счётчики попыток).
# /var/lib — переживает перезагрузку (выученная карта конфигураций).
# ---------------------------------------------------------------------------
st_get() { local v; v=$(cat "$RUN/$1" 2>/dev/null); case "$v" in ''|*[!0-9]*) printf '%s' "${2:-0}" ;; *) printf '%s' "$v" ;; esac; }
st_set() { printf '%s\n' "$2" > "$RUN/$1" 2>/dev/null; return 0; }
st_del() { rm -f "$RUN/$1" 2>/dev/null; return 0; }

# Выученная карта "модель -> номер USB-конфигурации, дающей целевой драйвер".
# Ключ — idProduct:bcdDevice, чтобы разные ревизии прошивки не смешивались.
map_get() { [ -r "$VAR/confmap" ] && awk -v k="$1" '$1==k{print $2; exit}' "$VAR/confmap" 2>/dev/null; return 0; }
map_set() {
    local k="$1" v="$2" tmp
    [ "$(map_get "$k")" = "$v" ] && return 0
    tmp=$(mktemp "$VAR/.confmap.XXXXXX" 2>/dev/null) || return 0
    { [ -r "$VAR/confmap" ] && grep -v "^$k " "$VAR/confmap" 2>/dev/null
      printf '%s %s\n' "$k" "$v"; } > "$tmp" 2>/dev/null
    mv -f "$tmp" "$VAR/confmap" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# Классификация Huawei PID по режиму устройства.
# Источник — INF из оригинального пакета HUAWEI Drivers 5.05.01.158:
#   cdrom        FcSwitch.inf          mass storage / Zero-CD, ждёт переключения
#                                      1f10..1f14 = ветка Vodafone (K5150/K5160)
#   hilink       ewqsnet.inf           RNDIS/ECM — рабочий режим
#   stick        ew_usbenumfilter.inf  composite stick, НЕ HiLink
#   stick-serial ew_hwusbdev*.inf      стик в serial-режиме, НЕ HiLink
# Пакет 2014 г.: PID поздних ревизий (E3372h-320) сюда не входят -> other.
# other не считается ошибкой — устройство просто проверяется по драйверу.
# ---------------------------------------------------------------------------
pid_mode() {
    case "${1,,}" in
        1f01|1f02|1f10|1f11|1f12|1f13|1f14|1440)
            echo cdrom ;;
        1400|1441|14bb|14bc|14bd|14be|14d[7-9a-f]|14e[0-9a-f]|14f[6-9a]|14fd|1565|1566|157[5-9ab]|157f|159[0-2])
            echo hilink ;;
        150[6-9a-f]|14c[6-9a-f]|151[b-f]|156[b-f]|158[5-9]|159[3-68ace]|15a[02468a]|15b[0-9a]|15d[1-9a-f]|15e[0-3]|15fd|1c2[5-9a])
            echo stick ;;
        1446|1449|14fe|14ff|1505|151a|156a|15ab|15ac|15ad|15ae|15af|15[2-4][0-9a-f]|155[0-9ab]|15c[a-f]|1c0b|1c1b|1c24)
            echo stick-serial ;;
        *)  echo other ;;
    esac
}

# PID «установочного» (Zero-CD) режима — для usb_modeswitch-конфигов.
ZEROCD_PIDS="1f01 1f02 1f10 1f11 1f12 1f13 1f14 1440"
MODESWITCH_D=/etc/usb_modeswitch.d
# usb-storage не берёт эти PID (флаг i): CD и microSD модема не нужны, а десятки «дисков»
# с ошибками чтения забивают udev и шину сбросами. Сначала самые частые: строка параметра
# модуля — не длиннее 127 символов.
STORAGE_IGNORE="1f01 14dc 14db 1f02 1f10 1f11 1f12 1f13 1f14 1440"
MODPROBE_CONF=/etc/modprobe.d/e3372-modems.conf
ETH0_LINK=/etc/systemd/network/10-e3372-eth0.link

# ---------------------------------------------------------------------------
# USB
# ---------------------------------------------------------------------------
# Все USB-устройства Huawei (именно устройства, не интерфейсы).
usb_devs() {
    local d
    for d in /sys/bus/usb/devices/*; do
        [ -r "$d/idVendor" ] || continue
        [ "$(cat "$d/idVendor" 2>/dev/null)" = "12d1" ] || continue
        case "${d##*/}" in *:*) continue ;; esac
        printf '%s\n' "$d"
    done
    return 0
}

dev_port() { printf '%s' "${1##*/}"; }
dev_attr() { cat "$1/$2" 2>/dev/null; return 0; }

# Номер mass-storage интерфейса (CD модема) в ТЕКУЩЕЙ конфигурации, пусто — нет такого.
# У Zero-CD Huawei он есть и в cfg 1, и в MBIM-конфигурации 2 (там третьим интерфейсом).
ms_iface() {
    local i
    for i in "$1":*; do
        [ -r "$i/bInterfaceClass" ] || continue
        [ "$(cat "$i/bInterfaceClass" 2>/dev/null)" = 08 ] || continue
        printf '%d' "0x$(cat "$i/bInterfaceNumber" 2>/dev/null || echo 0)"
        return 0
    done
    return 0
}

# Драйверы, привязанные к интерфейсам устройства.
dev_drivers() {
    local i drv
    for i in "$1":*; do
        [ -e "$i/driver" ] || continue
        drv=$(basename "$(readlink -f "$i/driver" 2>/dev/null)" 2>/dev/null)
        [ -n "$drv" ] && printf '%s\n' "$drv"
    done
    return 0
}

is_ok_driver()  { case " $PREFER_DRIVER $FALLBACK_DRIVERS " in *" $1 "*) return 0 ;; esac; return 1; }
is_bad_driver() { case " $BAD_DRIVERS " in *" $1 "*) return 0 ;; esac; return 1; }

# Сетевой драйвер устройства: печатает первый известный, пусто если ни одного.
dev_net_driver() {
    local drv
    while read -r drv; do
        if is_ok_driver "$drv" || is_bad_driver "$drv"; then printf '%s' "$drv"; return 0; fi
    done < <(dev_drivers "$1")
    return 1
}

iface_driver() { basename "$(readlink -f "/sys/class/net/$1/device/driver" 2>/dev/null)" 2>/dev/null; return 0; }

# Путь USB-устройства для сетевого интерфейса (стабильный идентификатор гнезда).
iface_usb_port() {
    local dl
    dl=$(readlink -f "/sys/class/net/$1/device" 2>/dev/null) || return 1
    [ -n "$dl" ] || return 1
    printf '%s' "$(basename "$(dirname "$dl")")"
}

# Смена USB-конфигурации. Прямая запись обычно проходит (ядро само отвязывает
# драйверы); если занято — сначала расконфигурировать (-1), потом поставить.
set_config() {
    local d="$1" v="$2"
    printf '%s\n' "$v" > "$d/bConfigurationValue" 2>/dev/null && return 0
    printf '%s\n' "-1" > "$d/bConfigurationValue" 2>/dev/null
    sleep 1
    printf '%s\n' "$v" > "$d/bConfigurationValue" 2>/dev/null
    return 0
}

# Принудительное пере-enumeration: аналог CM_Reenumerate_DevNode в виндовом стеке.
usb_reenumerate() {
    local d="$1"
    [ -w "$d/authorized" ] || return 1
    printf '0\n' > "$d/authorized" 2>/dev/null
    sleep 2
    printf '1\n' > "$d/authorized" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# Сеть
# ---------------------------------------------------------------------------
# Интерфейсы модемов с выданным адресом: "iface ip"
modem_ips() {
    ip -4 -o addr show 2>/dev/null | awk -v p="$HOST_PREFIX" -v o="$HOST_OCTET" '
        { split($4, a, "/"); split(a[1], b, ".")
          if (b[1] "." b[2] == p && b[4] == o) print $2, a[1] }'
    return 0
}

# Номер таблицы маршрутизации. 253/254/255 зарезервированы (default/main/local),
# 0 недопустим — такие N уводим в отдельный диапазон, иначе снесём таблицы ядра.
table_for() {
    local n="$1"
    if [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le 252 ] 2>/dev/null
    then printf '%s' "$n"
    else printf '%s' $(( 10000 + n )); fi
}

# Подсеть модема пересекается с адресом на другом интерфейсе (сеть хоста)?
subnet_busy() {
    ip -4 -o addr show 2>/dev/null | awk -v pat="$HOST_PREFIX.$1." -v me="$2" \
        '$2 != me && index($4, pat) == 1 { f = 1 } END { exit !f }'
}

# Идемпотентная установка ip rule: дубликаты не копятся.
rule_ensure() {
    local ip="$1" tbl="$2" prio="$3" i=0
    ip rule show 2>/dev/null | grep -q "from $ip lookup $tbl" && return 0
    while [ "$i" -lt 5 ]; do ip rule del from "$ip/32" 2>/dev/null || break; i=$(( i + 1 )); done
    ip rule add from "$ip/32" table "$tbl" priority "$prio" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# HiLink web-API. Прошивки этого поколения требуют сессию:
#   GET /api/webserver/SesTokInfo -> Cookie: SessionID=... + __RequestVerificationToken
# Без них любой запрос отдаёт <error><code>125002</code>.
# ---------------------------------------------------------------------------
xmlval() { tr -d '\r\n' | sed -n "s:.*<$1>\([^<]*\)</$1>.*:\1:p"; }

hl_session() {                    # gw -> "SID|TOK"
    local s sid tok
    s=$(curl -s -m4 "http://$1/api/webserver/SesTokInfo" 2>/dev/null) || return 1
    sid=$(printf '%s' "$s" | xmlval SesInfo)
    tok=$(printf '%s' "$s" | xmlval TokInfo)
    [ -n "$sid" ] || return 1
    printf '%s|%s' "$sid" "$tok"
}

hl_get()  {                       # gw sid tok path
    curl -s -m5 -H "Cookie: $2" -H "__RequestVerificationToken: $3" "http://$1$4" 2>/dev/null
    return 0
}

hl_post() {                       # gw sid tok path body
    curl -s -m8 -X POST -H "Cookie: $2" -H "__RequestVerificationToken: $3" \
         -H 'Content-Type: application/xml; charset=UTF-8' -d "$5" "http://$1$4" 2>/dev/null
    return 0
}

conn_text() {
    case "$1" in
        901) echo онлайн ;;      900) echo коннектит ;;   902) echo отключён ;;
        903) echo отключается ;; 904) echo сбой ;;        905) echo сбой-сети ;;
        906) echo сбой-роуминг ;; 907) echo нет-сети ;;
        11[2-5]) echo нет-регистрации ;;
        '')  echo нет-ответа ;;  *) echo "$1" ;;
    esac
}

net_text() {
    case "$1" in
        0) echo нет ;; 1|2|3) echo 2G ;; 4|5|6|7|8|9) echo 3G ;;
        4[1-6]|10[1-9]|11[0-9]) echo 3G+ ;; 19|101) echo LTE ;;
        '') echo ? ;; *) echo "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# Лестница починки. Модем без связи не ждёт человека: чем дольше нет связи,
# тем сильнее средство (одна попытка на модем не чаще RECONNECT_COOLDOWN):
#   0. дозвон (Action=1)                           — «отключён», «сбой»
#   1. отключить и подключить (Action 0 -> 1)      — то же, что e3372-ctl reconnect
#   2. перерегистрация: данные выкл -> режим сети туда-обратно -> данные вкл
#   3. перезагрузка модема — без связи дольше HEAL_REBOOT_AFTER,
#      не чаще HEAL_REBOOT_EVERY на модем
# «Без связи» — это ещё и: «коннектит»/«отключается» дольше STUCK_GRACE (с 1);
# нет регистрации при SIM на месте (с 2; сначала модем ищет сеть сам);
# «онлайн», но трафик с адреса модема не идёт NETCHECK_FAILS раз подряд (с 1).
# Web-API молчит дольше API_DEAD_AFTER, а адрес есть — USB-устройство заново.
# Раньше в этих случаях драйвер только писал в журнал и ждал команды руками.
# ---------------------------------------------------------------------------
LADDER=("дозвон" "откл -> вкл" "перерегистрация в сети" "перезагрузка модема")

mins() { if [ "$1" -ge 60 ]; then printf '%d мин' $(( $1 / 60 )); else printf '%d с' "$1"; fi; }

# POST со свежей сессией: часть прошивок принимает токен только один раз. 0 — модем ответил OK.
hl_do() {                         # gw path inner
    local ses sid tok
    ses=$(hl_session "$1") || return 1
    sid=${ses%%|*}; tok=${ses##*|}
    hl_post "$1" "$sid" "$tok" "$2" "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request>$3</request>" \
        | tr -d '\r\n' | grep -q '<response>[[:space:]]*OK[[:space:]]*</response>'
}
hl_again() { local i; for i in 1 2 3; do hl_do "$@" && return 0; [ "$i" -lt 3 ] && sleep 2; done; return 1; }

# Данные выкл -> режим сети туда-обратно -> данные вкл: модем заново регистрируется
# у оператора. Режим и диапазоны возвращаются как были; нет net-mode — хватит данных.
reregister() {                    # n gw
    local n="$1" gw="$2" ses sid tok m mode band lte tmp
    if ses=$(hl_session "$gw"); then
        sid=${ses%%|*}; tok=${ses##*|}
        m=$(hl_get "$gw" "$sid" "$tok" /api/net/net-mode)
        mode=$(printf '%s' "$m" | xmlval NetworkMode)
        band=$(printf '%s' "$m" | xmlval NetworkBand); lte=$(printf '%s' "$m" | xmlval LTEBand)
    fi
    band=${band:-3FFFFFFF}; lte=${lte:-7FFFFFFFFFFFFFFF}
    hl_do "$gw" /api/dialup/mobile-dataswitch '<dataswitch>0</dataswitch>'
    sleep 2
    if [ -n "$mode" ]; then
        tmp=02; [ "$mode" = 02 ] && tmp=03
        if hl_do "$gw" /api/net/net-mode "<NetworkMode>$tmp</NetworkMode><NetworkBand>$band</NetworkBand><LTEBand>$lte</LTEBand>"; then
            sleep 2
            hl_again "$gw" /api/net/net-mode "<NetworkMode>$mode</NetworkMode><NetworkBand>$band</NetworkBand><LTEBand>$lte</LTEBand>" \
                || log "N=$n: режим сети не вернулся к $mode"
        fi
    fi
    hl_again "$gw" /api/dialup/mobile-dataswitch '<dataswitch>1</dataswitch>' \
        || log "N=$n: не включилась передача данных"
    return 0
}

heal() {                          # n gw why first-level
    local n="$1" gw="$2" why="$3" first="${4:-0}" ts bad lvl down
    [ "${AUTO_HEAL:-1}" = 1 ] && [ "${AUTO_RECONNECT:-1}" = 1 ] || return 0
    ts=$(now)
    bad=$(st_get "bad.$n" 0); [ "$bad" -gt 0 ] || { bad=$ts; st_set "bad.$n" "$ts"; }
    [ $(( ts - $(st_get "act.$n" 0) )) -lt "$RECONNECT_COOLDOWN" ] && return 0
    lvl=$(st_get "lvl.$n" 0); [ "$lvl" -lt "$first" ] && lvl=$first
    down=$(( ts - bad ))
    if [ "$lvl" -ge 2 ] && [ "$down" -ge "$HEAL_REBOOT_AFTER" ] \
       && [ $(( ts - $(st_get "boot.$n" 0) )) -ge "$HEAL_REBOOT_EVERY" ]; then
        lvl=3
    fi
    log "N=$n: $why; без связи $(mins "$down") — ${LADDER[$lvl]}"
    st_set "act.$n" "$ts"
    if [ "$lvl" -eq 3 ]; then st_set "lvl.$n" 0; else st_set "lvl.$n" $(( lvl >= 1 ? 2 : 1 )); fi
    case "$lvl" in
        0) hl_do "$gw" /api/dialup/dial '<Action>1</Action>' || log "N=$n: дозвон не принят" ;;
        1) hl_do "$gw" /api/dialup/dial '<Action>0</Action>'
           sleep 3
           hl_do "$gw" /api/dialup/dial '<Action>1</Action>' || log "N=$n: откл -> вкл не прошло" ;;
        2) reregister "$n" "$gw" ;;
        3) st_set "boot.$n" "$ts"
           hl_do "$gw" /api/device/control '<Control>1</Control>' || log "N=$n: перезагрузка не принята" ;;
    esac
    return 0
}

healthy() { st_del "bad.$1"; st_del "lvl.$1"; st_del "act.$1"; st_del "stk.$1"; return 0; }

# У «онлайн»: ходит ли трафик. 1 — NETCHECK_FAILS неудач подряд. Проверяем, только если у
# адреса модема есть свой выход (правило from + default в его таблице), иначе проверка врёт.
netcheck() {                      # n ip
    local n="$1" ip="$2" tbl ts fails
    [ "${NETCHECK_EVERY:-0}" -gt 0 ] 2>/dev/null || return 0
    tbl=$(ip rule show 2>/dev/null | awk -v s="$ip" '$2 == "from" && ($3 == s || $3 == s "/32") { print $5; exit }')
    [ -n "$tbl" ] && ip route show table "$tbl" 2>/dev/null | grep -q '^default' || return 0
    ts=$(now); fails=$(st_get "ncf.$n" 0)
    [ "$fails" -eq 0 ] && [ $(( ts - $(st_get "nc.$n" 0) )) -lt "$NETCHECK_EVERY" ] && return 0
    st_set "nc.$n" "$ts"
    if curl -s -o /dev/null -m 6 --interface "$ip" "http://$NETCHECK_HOST/" 2>/dev/null; then
        [ "$fails" -gt 0 ] && log "N=$n: трафик снова идёт"
        st_del "ncf.$n"
        return 0
    fi
    fails=$(( fails + 1 )); st_set "ncf.$n" "$fails"
    if [ "$fails" -lt "$NETCHECK_FAILS" ]; then
        log "N=$n: «онлайн», но $NETCHECK_HOST не отвечает ($fails из $NETCHECK_FAILS)"
        return 0
    fi
    return 1
}

# Web-API молчит, а адрес есть: после API_DEAD_AFTER — USB-устройство заново (не чаще
# API_REENUM_EVERY). Питание так не снимается, но зависший web-сервер обычно оживает.
api_dead() {                      # n iface
    local n="$1" ifn="$2" ts first port
    [ "${AUTO_HEAL:-1}" = 1 ] || return 0
    ts=$(now)
    first=$(st_get "api.$n" 0); [ "$first" -gt 0 ] || { first=$ts; st_set "api.$n" "$ts"; }
    [ $(( ts - first )) -lt "$API_DEAD_AFTER" ] && return 0
    [ $(( ts - $(st_get "reenum.$n" 0) )) -lt "$API_REENUM_EVERY" ] && return 0
    port=$(iface_usb_port "$ifn") || return 0
    log "N=$n: web-API молчит $(mins $(( ts - first ))) — заново подключаю USB-устройство $port"
    st_set "reenum.$n" "$ts"; st_set "api.$n" "$ts"
    usb_reenumerate "/sys/bus/usb/devices/$port"
    return 0
}

# ---------------------------------------------------------------------------
# Обработка одного модема через web-API. Вызывается параллельно через xargs,
# поэтому не должна ничего писать в общее состояние кроме своих ключей.
# ---------------------------------------------------------------------------
modem_worker() {
    local iface="$1" ip="$2" n gw ses sid tok st cs sw sim ts stk
    n=$(printf '%s' "$ip" | cut -d. -f3)
    gw="$HOST_PREFIX.$n.$GW_OCTET"

    ses=$(hl_session "$gw") || { log_once "N=$n: web-API не отвечает"; api_dead "$n" "$iface"; return 0; }
    st_del "api.$n"
    sid=${ses%%|*}; tok=${ses##*|}

    # 1. мобильные данные выключены -> включить (это и есть «сеть нашёл,
    #    но не подключился»: модем зарегистрирован, передача данных выключена)
    if [ "${AUTO_DATASWITCH:-1}" = 1 ]; then
        sw=$(hl_get "$gw" "$sid" "$tok" /api/dialup/mobile-dataswitch | xmlval dataswitch)
        if [ "$sw" = "0" ]; then
            log "N=$n: мобильные данные выключены — включаю"
            hl_post "$gw" "$sid" "$tok" /api/dialup/mobile-dataswitch \
                '<?xml version="1.0" encoding="UTF-8"?><request><dataswitch>1</dataswitch></request>' >/dev/null
            return 0
        fi
    fi

    # 2. состояние связи -> при беде следующая ступень лестницы (heal)
    st=$(hl_get "$gw" "$sid" "$tok" /api/monitoring/status)
    cs=$(printf '%s' "$st" | xmlval ConnectionStatus)
    sim=$(printf '%s' "$st" | xmlval SimStatus)
    case "$cs" in
        901)
            st_del "stk.$n"
            if netcheck "$n" "$ip"; then healthy "$n"
            else heal "$n" "$gw" "«онлайн», но трафик не идёт ($(st_get "ncf.$n" 0) проверки подряд)" 1; fi
            return 0 ;;
        '') log_once "N=$n: статус не читается (сессия/прошивка)"; return 0 ;;
    esac
    st_del "ncf.$n"
    case "$cs" in
        900|903)
            ts=$(now)
            stk=$(st_get "stk.$n" 0); [ "$stk" -gt 0 ] || { stk=$ts; st_set "stk.$n" "$ts"; }
            [ $(( ts - stk )) -ge "$STUCK_GRACE" ] \
                && heal "$n" "$gw" "«$(conn_text "$cs")» уже $(mins $(( ts - stk )))" 1
            return 0 ;;
    esac
    st_del "stk.$n"
    case "$cs" in
        907|11[2-5])
            if [ -n "$sim" ] && [ "$sim" != 1 ]; then
                log_once "N=$n: SIM не готова (SimStatus=$sim) — проверь SIM-карту"; return 0
            fi
            log_once "N=$n: нет регистрации в сети (сигнал, баланс, APN)"
            [ "$(st_get "act.$n" 0)" -gt 0 ] || st_set "act.$n" "$(now)"     # сначала модем ищет сеть сам
            heal "$n" "$gw" "нет регистрации в сети" 2
            return 0 ;;
    esac
    heal "$n" "$gw" "ConnectionStatus=$cs ($(conn_text "$cs"))" 0
    return 0
}

# ---------------------------------------------------------------------------
# Модемы — только рабочий режим: MBIM, usb-storage, ModemManager, имя eth0.
# Всё это на сорока модемах мешало переключению (SpbVL-1, октябрь 2026).
# ---------------------------------------------------------------------------
# quirks для usb-storage: чужие записи как были, наши «не брать» — сколько влезет в 127.
storage_quirks() {
    local out="" q p
    for q in $(printf '%s' "${1:-}" | tr ',' ' '); do
        case "${q,,}" in 12d1:*) continue ;; esac
        out="${out:+$out,}$q"
    done
    for p in $STORAGE_IGNORE; do
        q="12d1:$p:i"
        [ ${#out} -gt 0 ] && q=",$q"
        [ $(( ${#out} + ${#q} )) -le 127 ] && out="$out$q"
    done
    printf '%s' "$out"
}

modprobe_text() {
    cat <<EOT
# e3372-driver: настоящие модемы Huawei — только рабочий режим (HiLink: rndis_host/cdc_ether).
# MBIM не нужен: ядро само ставит Zero-CD конфигурацию 2 с MBIM — десятки wwanN, за ними
# ModemManager, а переключению это мешает.
blacklist cdc_mbim
install cdc_mbim /bin/true
# CD и microSD модемов не нужны: Zero-CD переключается через usbfs (usb_modeswitch).
# i — не брать устройство.
options usb-storage quirks=$(storage_quirks)
EOT
}

# То же, что даст modprobe.d после перезагрузки, — сейчас. Печатает, что сделано.
modems_apply_now() {
    local qp=/sys/module/usb_storage/parameters/quirks want i n=0
    if [ -w "$qp" ]; then
        want=$(storage_quirks "$(cat "$qp" 2>/dev/null)")
        if [ "$(cat "$qp" 2>/dev/null)" != "$want" ]; then
            printf '%s' "$want" > "$qp" 2>/dev/null && echo "usb-storage: модемы Huawei не берёт"
        fi
        for i in /sys/bus/usb/drivers/usb-storage/*:*; do
            [ -e "$i" ] || continue
            [ "$(cat "$(dirname "$(readlink -f "$i")")/idVendor" 2>/dev/null)" = 12d1 ] || continue
            printf '%s' "${i##*/}" > /sys/bus/usb/drivers/usb-storage/unbind 2>/dev/null && n=$(( n + 1 ))
        done
        [ "$n" -gt 0 ] && echo "usb-storage отпустил CD/SD модемов: $n"
    fi
    if [ -d /sys/module/cdc_mbim ]; then
        if modprobe -r cdc_mbim 2>/dev/null; then echo "cdc_mbim выгружен"; else echo "cdc_mbim не выгрузился (занят)"; fi
    fi
    return 0
}

# MAC основной сетевой карты, которой .link велит имя eth0 (netplan ВМ из cloud-init).
# Нет такого правила (хост Proxmox: vmbr0, enpXsY) — пусто: eth0 не наше дело.
primary_mac() {
    local f
    for f in /run/systemd/network/*.link /etc/systemd/network/*.link; do
        [ -r "$f" ] || continue
        [ "$f" = "$ETH0_LINK" ] && continue
        grep -qE '^Name=eth0[[:space:]]*$' "$f" 2>/dev/null || continue
        sed -nE 's/^(Permanent)?MACAddress=([0-9A-Fa-f:]{17})[[:space:]]*$/\2/p' "$f" | head -1 | tr 'A-F' 'a-f'
        return 0
    done
    return 0
}

eth0_link_text() {
    printf '# e3372-driver: основной сетевой карте — eth0 с первой секунды загрузки (и в initramfs),\n'
    printf '# чтобы имя не успел занять USB-модем. MAC — из .link netplan (Name=eth0).\n'
    printf '[Match]\nPermanentMACAddress=%s\n\n[Link]\nName=eth0\n' "$1"
}

free_eth() { local i=64; while [ -e "/sys/class/net/eth$i" ]; do i=$(( i + 1 )); done; printf 'eth%d' "$i"; }

# Загрузка: eth0 занял модем (успел раньше основной карты) — модем на свободное ethN,
# основной карте — eth0. Зовёт e3372-eth0.service до запуска сети.
fix_eth0() {
    local mac nic="" n i to
    mac=$(primary_mac)
    [ -n "$mac" ] || { echo "нет правила имени eth0 по MAC — не наше дело"; return 0; }
    for i in $(seq 1 40); do
        for n in /sys/class/net/*; do
            [ "$(cat "$n/address" 2>/dev/null)" = "$mac" ] && { nic=${n##*/}; break; }
        done
        [ -n "$nic" ] && break
        sleep 0.5
    done
    [ -n "$nic" ] || { echo "сетевой карты $mac нет"; return 0; }
    [ "$nic" = eth0 ] && { echo "eth0 на месте"; return 0; }
    if [ -e /sys/class/net/eth0 ]; then
        [ "$(cat "$(readlink -f /sys/class/net/eth0/device)/../idVendor" 2>/dev/null)" = 12d1 ] \
            || { echo "eth0 занят не модемом — не трогаю"; return 0; }
        to=$(free_eth)
        ip link set eth0 down; ip link set eth0 name "$to"
        log "eth0 был у модема — он теперь $to"
    fi
    ip link set "$nic" down; ip link set "$nic" name eth0; ip link set eth0 up
    log "основная сетевая карта $nic ($mac) — снова eth0"
    return 0
}
