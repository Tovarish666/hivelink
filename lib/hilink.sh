#!/bin/bash
# hivelink / hilink.sh — клиент веб-API модемов Huawei HiLink.
#
# API требует сессию: GET /api/webserver/SesTokInfo отдаёт пару
# SessionID + RequestVerificationToken, которые идут в каждый запрос.
# Без них любой вызов возвращает <code>125002</code>.

hl_api_base() { printf 'http://%s/api' "$(hl_gw "$1")"; }

# Достаём поле XML без парсера: <Tag>значение</Tag>
hl_xml() { sed -n "s#.*<$2>\(.*\)</$2>.*#\1#p" <<<"$1" | head -1; }

hl_api_errcode() { hl_xml "$1" code; }

# ------------------------------------------------------------- сессия ------

_hl_sess_file() { printf '%s/session.%s' "$HL_RUN" "$1"; }

hl_api_session() {
    local slot="$1" f raw sess tok host
    f=$(_hl_sess_file "$slot")
    host=$(hl_host "$slot")

    # Сессия живёт недолго; кэшируем на минуту, чтобы не дёргать модем в каждом цикле
    if [ -f "$f" ] && [ "$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))" -lt 60 ]; then
        cat "$f"; return 0
    fi

    raw=$(curl -s -m "$HL_HILINK_TIMEOUT" --interface "$host" \
              "$(hl_api_base "$slot")/webserver/SesTokInfo" 2>/dev/null) || return 1
    sess=$(hl_xml "$raw" SesInfo)
    tok=$(hl_xml  "$raw" TokInfo)
    [ -n "$sess" ] && [ -n "$tok" ] || { dbg "слот $slot: сессия не выдана"; return 1; }

    mkdir -p "$HL_RUN"
    printf '%s\t%s\n' "$sess" "$tok" >"$f"
    chmod 600 "$f" 2>/dev/null
    cat "$f"
}

hl_api_get() {
    local slot="$1" ep="$2" s host
    s=$(hl_api_session "$slot") || return 1
    host=$(hl_host "$slot")
    curl -s -m "$HL_HILINK_TIMEOUT" --interface "$host" \
        -H "Cookie: $(cut -f1 <<<"$s")" \
        -H "__RequestVerificationToken: $(cut -f2 <<<"$s")" \
        "$(hl_api_base "$slot")/$ep" 2>/dev/null
}

hl_api_post() {
    local slot="$1" ep="$2" body="$3" s host out
    s=$(hl_api_session "$slot") || return 1
    host=$(hl_host "$slot")
    out=$(curl -s -m "$HL_HILINK_TIMEOUT" --interface "$host" \
        -H "Cookie: $(cut -f1 <<<"$s")" \
        -H "__RequestVerificationToken: $(cut -f2 <<<"$s")" \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        -X POST --data "$body" \
        "$(hl_api_base "$slot")/$ep" 2>/dev/null)
    # Токен одноразовый — после POST сессию сбрасываем
    rm -f "$(_hl_sess_file "$slot")"
    printf '%s\n' "$out"
}

# --------------------------------------------------------------- статус ----

# ConnectionStatus: 901 подключён, 902 отключён, 903 отключается,
# 905 подключается, 900/919/920 — переходные и ошибочные.
hl_hilink_conn_status() { hl_xml "$(hl_api_get "$1" monitoring/status)" ConnectionStatus; }

hl_hilink_info() { hl_api_get "$1" device/information; }

# Печатает: <модель> <прошивка> <IMEI> <WAN IP>
hl_hilink_ident() {
    local x; x=$(hl_hilink_info "$1") || return 1
    [ -n "$(hl_xml "$x" DeviceName)" ] || return 1
    printf '%s %s %s %s\n' \
        "$(hl_xml "$x" DeviceName)"      \
        "$(hl_xml "$x" SoftwareVersion)" \
        "$(hl_xml "$x" Imei)"            \
        "$(hl_xml "$x" WanIPAddress)"
}

# Печатает: <тип сети> <RSRP> <RSRQ> <SINR>
hl_hilink_signal() {
    local x; x=$(hl_api_get "$1" device/signal) || return 1
    printf '%s %s %s %s\n' \
        "$(hl_xml "$x" mode)" "$(hl_xml "$x" rsrp)" \
        "$(hl_xml "$x" rsrq)" "$(hl_xml "$x" sinr)"
}

# --------------------------------------------------- поднятие соединения ---

hl_hilink_dataswitch_on() {
    local slot="$1" out
    out=$(hl_api_post "$slot" dialup/mobile-dataswitch \
        '<?xml version="1.0" encoding="UTF-8"?><request><dataswitch>1</dataswitch></request>')
    case "$out" in
        *'<response>OK</response>'*) info "слот $slot: передача данных включена"; return 0 ;;
    esac
    warn "слот $slot: dataswitch не прошёл (code=$(hl_api_errcode "$out"))"
    return 1
}

# Главная функция стадии: убедиться, что модем в сети.
hl_hilink_ensure_connected() {
    local slot="$1" st
    [ "$HL_HILINK_ENABLE" = 1 ] || return 0

    st=$(hl_hilink_conn_status "$slot")
    if [ -z "$st" ]; then
        dbg "слот $slot: API молчит (модем ещё поднимается или не HiLink)"
        return 1
    fi

    case "$st" in
        901) dbg "слот $slot: подключён"; return 0 ;;
        905|900) dbg "слот $slot: подключается ($st)"; return 0 ;;
    esac

    warn "слот $slot: ConnectionStatus=$st, поднимаю"
    [ "$HL_HILINK_DATASWITCH" = 1 ] && hl_hilink_dataswitch_on "$slot"

    hl_api_post "$slot" dialup/dial \
        '<?xml version="1.0" encoding="UTF-8"?><request><Action>1</Action></request>' >/dev/null
    return 1
}

# ------------------------------------------------------------------ SMS ----
#
# Чтение SMS — ближайший пункт дорожной карты по модемам.
# BoxType: 1 входящие, 2 отправленные.

hl_hilink_sms_count() {
    local x; x=$(hl_api_get "$1" sms/sms-count) || return 1
    printf '%s\n' "$(hl_xml "$x" LocalInbox)"
}

hl_hilink_sms_list() {
    local slot="$1" page="${2:-1}" n="${3:-20}"
    hl_api_post "$slot" sms/sms-list "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request>\
<PageIndex>$page</PageIndex><ReadCount>$n</ReadCount><BoxType>1</BoxType>\
<SortType>0</SortType><Ascending>0</Ascending><UnreadPreferred>1</UnreadPreferred></request>"
}
