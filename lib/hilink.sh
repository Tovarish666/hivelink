#!/bin/bash
# hivelink / hilink.sh — клиент веб-API модемов Huawei HiLink.
#
# API требует сессию: GET /api/webserver/SesTokInfo отдаёт пару
# SessionID + RequestVerificationToken, которые идут в каждый запрос.
# Без них любой вызов возвращает <code>125002</code>.
#
# Функции с суффиксом _at работают по явному адресу шлюза — они нужны
# на стадии переопределения, когда модем ещё сидит на заводской подсети
# и его «своего» адреса просто не существует.

# Заводские адреса HiLink. Свежий модем из коробки — 192.168.8.1,
# и у ВСЕХ модемов партии он одинаковый. Пока не переопределим,
# больше одного такого модема на хосте работать не может.
HL_HILINK_DEFAULT_LANS="${HL_HILINK_DEFAULT_LANS:-192.168.8.1 192.168.1.1 192.168.0.1 192.168.100.1}"

hl_xml() { sed -n "s#.*<$2>\(.*\)</$2>.*#\1#p" <<<"$1" | head -1; }
hl_api_errcode() { hl_xml "$1" code; }

# ------------------------------------------------------------- сессия ------

_hl_sess_file() { printf '%s/session.%s' "$HL_RUN" "$(printf '%s' "$1" | tr . _)"; }

# hl_api_session_at <шлюз> <адрес-источник>
hl_api_session_at() {
    local gw="$1" src="$2" f raw sess tok
    f=$(_hl_sess_file "$gw")

    if [ -f "$f" ] && [ "$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))" -lt 60 ]; then
        cat "$f"; return 0
    fi

    raw=$(curl -s -m "$HL_HILINK_TIMEOUT" --interface "$src" \
              "http://$gw/api/webserver/SesTokInfo" 2>/dev/null) || return 1
    sess=$(hl_xml "$raw" SesInfo); tok=$(hl_xml "$raw" TokInfo)
    [ -n "$sess" ] && [ -n "$tok" ] || return 1

    mkdir -p "$HL_RUN"
    printf '%s\t%s\n' "$sess" "$tok" >"$f"
    chmod 600 "$f" 2>/dev/null
    cat "$f"
}

hl_api_get_at() {
    local gw="$1" src="$2" ep="$3" s
    s=$(hl_api_session_at "$gw" "$src") || return 1
    curl -s -m "$HL_HILINK_TIMEOUT" --interface "$src" \
        -H "Cookie: $(cut -f1 <<<"$s")" \
        -H "__RequestVerificationToken: $(cut -f2 <<<"$s")" \
        "http://$gw/api/$ep" 2>/dev/null
}

hl_api_post_at() {
    local gw="$1" src="$2" ep="$3" body="$4" s out
    s=$(hl_api_session_at "$gw" "$src") || return 1
    out=$(curl -s -m "$HL_HILINK_TIMEOUT" --interface "$src" \
        -H "Cookie: $(cut -f1 <<<"$s")" \
        -H "__RequestVerificationToken: $(cut -f2 <<<"$s")" \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        -X POST --data "$body" "http://$gw/api/$ep" 2>/dev/null)
    rm -f "$(_hl_sess_file "$gw")"      # токен одноразовый
    printf '%s\n' "$out"
}

# Обёртки «по слоту» — обычный режим, когда модем уже на своём адресе
hl_api_get()  { hl_api_get_at  "$(hl_gw "$1")" "$(hl_host "$1")" "$2"; }
hl_api_post() { hl_api_post_at "$(hl_gw "$1")" "$(hl_host "$1")" "$2" "$3"; }

# ------------------------------------------ переопределение LAN модема -----
#
# Ключевая стадия для фермы. Пока модем на заводских 192.168.8.1, второй
# такой же модем в тот же хост воткнуть нельзя: одинаковая подсеть, драка
# маршрутов, ARP-каша. Поэтому каждому модему прописывается СВОЯ подсеть,
# совпадающая с его номером слота.
#
# Курица и яйцо решается так: чтобы достучаться до API, надо быть в сети
# модема, поэтому хост временно берёт адрес в заводской подсети, отдаёт
# команду, и модем переезжает на целевой адрес вместе с хостом.

hl_hilink_lan_ip() {
    local gw="$1" src="$2" x
    x=$(hl_api_get_at "$gw" "$src" dhcp/settings) || return 1
    hl_xml "$x" DhcpIPAddress
}

# hl_hilink_set_lan <текущий шлюз> <адрес-источник> <новый адрес шлюза>
hl_hilink_set_lan() {
    local gw="$1" src="$2" new="$3" net out
    net="${new%.*}"
    out=$(hl_api_post_at "$gw" "$src" dhcp/settings \
"<?xml version=\"1.0\" encoding=\"UTF-8\"?><request>\
<DhcpIPAddress>$new</DhcpIPAddress>\
<DhcpLanNetmask>255.255.255.0</DhcpLanNetmask>\
<DhcpStatus>1</DhcpStatus>\
<DhcpStartIPAddress>$net.100</DhcpStartIPAddress>\
<DhcpEndIPAddress>$net.200</DhcpEndIPAddress>\
<DhcpLeaseTime>86400</DhcpLeaseTime>\
<DnsStatus>1</DnsStatus>\
<PrimaryDns>$new</PrimaryDns>\
<SecondaryDns>$new</SecondaryDns>\
</request>")
    case "$out" in
        *'<response>OK</response>'*) return 0 ;;
    esac
    warn "переопределение LAN $gw -> $new не прошло (code=$(hl_api_errcode "$out"))"
    return 1
}

# Привести модем на подсеть своего слота. Идемпотентна: если модем уже
# там, где надо, ничего не делает.
#
#   hl_hilink_provision <slot> <iface>   -> 0 модем на своём адресе
hl_hilink_provision() {
    local slot="$1" iface="$2"
    local want_gw want_host cand tmp_host ok=1

    want_gw=$(hl_gw "$slot"); want_host=$(hl_host "$slot")

    # Уже на месте?
    if ping -c1 -W2 -I "$want_host" "$want_gw" >/dev/null 2>&1; then
        return 0
    fi

    local tries
    tries=$(hl_cnt_get provision "$slot")
    if [ "$tries" -ge 5 ]; then
        dbg "слот $slot: переопределение уже пробовали $tries раз, жду смены обстановки"
        return 1
    fi

    for cand in $HL_HILINK_DEFAULT_LANS; do
        [ "$cand" = "$want_gw" ] && continue
        tmp_host="${cand%.*}.$HL_HOST_OCTET"

        ip addr add "$tmp_host/24" dev "$iface" 2>/dev/null || continue
        ip link set dev "$iface" up 2>/dev/null
        sleep 1

        if ping -c1 -W2 -I "$tmp_host" "$cand" >/dev/null 2>&1 &&
           hl_api_session_at "$cand" "$tmp_host" >/dev/null 2>&1; then

            hl_cnt_bump provision "$slot" >/dev/null
            info "слот $slot: модем на заводском $cand — переопределяю на $want_gw"

            if hl_hilink_set_lan "$cand" "$tmp_host" "$want_gw"; then
                ip addr del "$tmp_host/24" dev "$iface" 2>/dev/null
                # Модем перестраивает LAN несколько секунд
                sleep 6
                ok=0
            else
                ip addr del "$tmp_host/24" dev "$iface" 2>/dev/null
            fi
            break
        fi
        ip addr del "$tmp_host/24" dev "$iface" 2>/dev/null
    done

    if [ "$ok" = 0 ]; then
        hl_cnt_clear provision "$slot"
        info "слот $slot: модем переехал на $want_gw"
        return 0
    fi
    dbg "слот $slot: заводского адреса не нашёл, модем молчит на всех кандидатах"
    return 1
}

# --------------------------------------------------------------- статус ----

hl_hilink_conn_status() { hl_xml "$(hl_api_get "$1" monitoring/status)" ConnectionStatus; }
hl_hilink_info()        { hl_api_get "$1" device/information; }

# Печатает: <модель> <прошивка> <IMEI> <WAN IP>
hl_hilink_ident() {
    local x; x=$(hl_hilink_info "$1") || return 1
    [ -n "$(hl_xml "$x" DeviceName)" ] || return 1
    printf '%s %s %s %s\n' \
        "$(hl_xml "$x" DeviceName)" "$(hl_xml "$x" SoftwareVersion)" \
        "$(hl_xml "$x" Imei)"       "$(hl_xml "$x" WanIPAddress)"
}

hl_hilink_imei() { hl_xml "$(hl_hilink_info "$1")" Imei; }

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

hl_hilink_ensure_connected() {
    local slot="$1" st
    [ "$HL_HILINK_ENABLE" = 1 ] || return 0

    st=$(hl_hilink_conn_status "$slot")
    if [ -z "$st" ]; then
        dbg "слот $slot: API молчит (модем ещё поднимается или не HiLink)"
        return 1
    fi

    case "$st" in
        901)     dbg "слот $slot: подключён"; return 0 ;;
        905|900) dbg "слот $slot: подключается ($st)"; return 0 ;;
    esac

    warn "слот $slot: ConnectionStatus=$st, поднимаю"
    [ "$HL_HILINK_DATASWITCH" = 1 ] && hl_hilink_dataswitch_on "$slot"
    hl_api_post "$slot" dialup/dial \
        '<?xml version="1.0" encoding="UTF-8"?><request><Action>1</Action></request>' >/dev/null
    return 1
}

# ------------------------------------------------------------------ SMS ----

hl_hilink_sms_count() { hl_xml "$(hl_api_get "$1" sms/sms-count)" LocalInbox; }

hl_hilink_sms_list() {
    local slot="$1" page="${2:-1}" n="${3:-20}"
    hl_api_post "$slot" sms/sms-list "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request>\
<PageIndex>$page</PageIndex><ReadCount>$n</ReadCount><BoxType>1</BoxType>\
<SortType>0</SortType><Ascending>0</Ascending><UnreadPreferred>1</UnreadPreferred></request>"
}
