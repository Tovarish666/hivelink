#!/bin/bash
# hivelink / health.sh — проверки живости и лестница восстановления.

_hl_fail_file() { printf '%s/fails.%s' "$HL_VAR" "$1"; }

hl_fail_count() { cat "$(_hl_fail_file "$1")" 2>/dev/null || echo 0; }
hl_fail_bump()  { local n; n=$(( $(hl_fail_count "$1") + 1 )); echo "$n" >"$(_hl_fail_file "$1")"; echo "$n"; }
hl_fail_clear() { rm -f "$(_hl_fail_file "$1")"; }

# ----------------------------------------------------------- диагностика ---
#
# Печатает причину первой сработавшей проверки, пустую строку если всё хорошо.
# Порядок от дешёвого к дорогому: не пингуем интернет, если нет даже адреса.

hl_health_reason() {
    local slot="$1" iface="$2" host
    host=$(hl_host "$slot")

    [ -n "$iface" ] && [ -e "/sys/class/net/$iface" ] || { echo "нет интерфейса"; return 1; }

    [ "$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)" = "down" ] &&
        { echo "линк down"; return 1; }

    ip -4 addr show dev "$iface" 2>/dev/null | grep -q "inet $host/" ||
        { echo "нет адреса $host"; return 1; }

    ip route show table "$(hl_table "$slot")" 2>/dev/null | grep -q '^default' ||
        { echo "нет default в таблице $(hl_table "$slot")"; return 1; }

    hl_probe_gw "$slot" || { echo "модем не отвечает на $(hl_gw "$slot")"; return 1; }

    if [ "$HL_HILINK_ENABLE" = 1 ]; then
        local st; st=$(hl_hilink_conn_status "$slot")
        if [ -n "$st" ] && [ "$st" != "901" ] && [ "$st" != "905" ] && [ "$st" != "900" ]; then
            echo "ConnectionStatus=$st"; return 1
        fi
    fi

    hl_probe "$slot" || { echo "нет прохода до $HL_WATCHDOG_PING"; return 1; }

    echo ""; return 0
}

# ------------------------------------------------- признак битого приёма ---
#
# Если фикс rndis_host не активен, приём сыпется в length/frame ошибки.
# Это ловится дёшево и указывает не на модем, а на драйвер.

hl_rx_error_ratio() {
    local iface="$1" p e
    p=$(cat "/sys/class/net/$iface/statistics/rx_packets" 2>/dev/null || echo 0)
    e=$(cat "/sys/class/net/$iface/statistics/rx_errors"  2>/dev/null || echo 0)
    [ "$p" -gt 200 ] 2>/dev/null || { echo 0; return; }
    echo $(( e * 100 / p ))
}

hl_check_driver_fix() {
    local iface="$1" drv ratio active
    drv=$(basename "$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null)" 2>/dev/null)
    [ "$drv" = "rndis_host" ] || return 0

    active=$(cat /sys/module/rndis_host/parameters/rx_urb_size_override 2>/dev/null || echo "")
    if [ -z "$active" ]; then
        warn "$iface: загружен штатный rndis_host без фикса — приём будет ~1 Мбит. Проверь: dkms status"
        return 1
    fi
    if [ "$active" = "0" ]; then
        warn "$iface: фикс собран, но rx_urb_size_override=0. Проверь /etc/modprobe.d/hivelink-rndis.conf"
        return 1
    fi

    ratio=$(hl_rx_error_ratio "$iface")
    if [ "$ratio" -gt 20 ] 2>/dev/null; then
        warn "$iface: ${ratio}% ошибок приёма при активном фиксе — попробуй другой HL_RX_URB_SIZE"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------ лестница -----
#
# Чем дольше модем не оживает, тем грубее лечение. Каждая ступень
# отрабатывает не чаще, чем набежит соответствующее число неудач.

hl_recover() {
    local slot="$1" iface="$2" port="$3" fails="$4" hint

    # Модем может быть совершенно исправен, а не отвечать потому, что мы
    # повесили на интерфейс адрес не из его подсети. Сносить устройство
    # в этой ситуации — сносить исправное железо: rebind и usb reset
    # порождают переподключение, следующий цикл ловит модем без драйвера
    # и бьёт снова. Ровно так драйвер загнал в петлю 14 модемов.
    hint=$(hl_lanhint_get "$port")
    if [ -z "$hint" ]; then
        info "слот $slot: номер не подтверждён разведкой — не трогаю железо, жду её"
        return 0
    fi
    if [ "$hint" != "$slot" ]; then
        warn "слот $slot: модем на самом деле в подсети $hint — это не отказ, а расхождение номера"
        return 0
    fi

    if   [ "$fails" -le "$HL_WATCHDOG_FAILS" ]; then
        info "слот $slot: ступень 1 — переконфигурирую адресацию"
        hl_addr_configure "$slot" "$iface"

    elif [ "$fails" -le $((HL_WATCHDOG_FAILS * 2)) ]; then
        info "слот $slot: ступень 2 — переподключение через API"
        hl_hilink_ensure_connected "$slot"

    elif [ "$fails" -le $((HL_WATCHDOG_FAILS * 3)) ]; then
        info "слот $slot: ступень 3 — rebind драйвера"
        hl_rebind "$port"

    else
        if [ "$HL_WATCHDOG_ESCALATE" = 1 ]; then
            warn "слот $slot: ступень 4 — сброс USB-устройства"
            hl_usb_reset "$port"
            hl_fail_clear "$slot"
        else
            warn "слот $slot: не оживает ($fails неудач), эскалация запрещена конфигом"
        fi
    fi
}
