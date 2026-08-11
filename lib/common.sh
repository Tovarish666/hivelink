#!/bin/bash
# =============================================================================
#  e3372-driver — общая библиотека. Подключается всеми утилитами пакета.
#  Ничего не делает при подключении, только определяет функции и настройки.
# =============================================================================
# shellcheck shell=bash disable=SC2034

E3372_VERSION="2.0.0"

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
NODRV_GRACE=3                                     # циклов ждать привязки драйвера
DHCP_MAX_TRIES=10
HILINK_EVERY=4                                    # раз в сколько циклов дёргать web-API
HILINK_CONCURRENCY=8
AUTO_DATASWITCH=1                                 # включать мобильные данные
AUTO_RECONNECT=1                                  # переподнимать соединение
RECONNECT_COOLDOWN=180                            # сек между попытками дозвона
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
# Обработка одного модема через web-API. Вызывается параллельно через xargs,
# поэтому не должна ничего писать в общее состояние кроме своих ключей.
# ---------------------------------------------------------------------------
modem_worker() {
    local iface="$1" ip="$2" n gw ses sid tok st cs sw last ts
    n=$(printf '%s' "$ip" | cut -d. -f3)
    gw="$HOST_PREFIX.$n.$GW_OCTET"

    ses=$(hl_session "$gw") || { log_once "N=$n: web-API не отвечает"; return 0; }
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

    # 2. данные включены, но соединения нет -> дозвон, с выдержкой
    st=$(hl_get "$gw" "$sid" "$tok" /api/monitoring/status)
    cs=$(printf '%s' "$st" | xmlval ConnectionStatus)
    case "$cs" in
        901|900|903) st_del "dial.$n"; return 0 ;;
        '')          log_once "N=$n: статус не читается (сессия/прошивка)"; return 0 ;;
        90[7]|11[2-5]) log_once "N=$n: нет регистрации в сети (SIM/сигнал/APN)"; return 0 ;;
    esac
    [ "${AUTO_RECONNECT:-1}" = 1 ] || return 0
    ts=$(now); last=$(st_get "dial.$n" 0)
    [ $(( ts - last )) -lt "$RECONNECT_COOLDOWN" ] && return 0
    st_set "dial.$n" "$ts"
    log "N=$n: ConnectionStatus=$cs ($(conn_text "$cs")) — дозваниваюсь"
    hl_post "$gw" "$sid" "$tok" /api/dialup/dial \
        '<?xml version="1.0" encoding="UTF-8"?><request><Action>1</Action></request>' >/dev/null
    return 0
}
