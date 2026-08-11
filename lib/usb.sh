#!/bin/bash
# hivelink / usb.sh — обнаружение устройств, Zero-CD, драйверы, сброс шины.

# ------------------------------------------------------------- обнаружение --

# Печатает по строке на устройство:  <порт> <vid> <pid> <bcdDevice>
# Порт — это USB-путь вида 3-1.4.2, он же вечный якорь для номера модема.
hl_usb_devices() {
    local d port vid pid bcd
    for d in /sys/bus/usb/devices/*/; do
        [ -f "$d/idVendor" ] || continue
        vid=$(cat "$d/idVendor" 2>/dev/null)
        printf '%s\n' "$HL_VENDORS" | tr ' ' '\n' | grep -qx "$vid" || continue
        port=$(basename "$d")
        case "$port" in *:*) continue ;; esac        # это интерфейс, не устройство
        pid=$(cat "$d/idProduct"  2>/dev/null)
        bcd=$(cat "$d/bcdDevice"  2>/dev/null)
        printf '%s %s %s %s\n' "$port" "$vid" "$pid" "$bcd"
    done
}

hl_dev_path()  { printf '/sys/bus/usb/devices/%s' "$1"; }
hl_dev_attr()  { cat "$(hl_dev_path "$1")/$2" 2>/dev/null; }

hl_is_zerocd() {
    local pid="$1"
    printf '%s\n' "$HL_ZEROCD_PIDS" | tr ' ' '\n' | grep -qix "$pid"
}

# Сетевой интерфейс, принадлежащий порту (ищем по всем его USB-интерфейсам)
hl_netdev_of_port() {
    local port="$1" n
    for n in "$(hl_dev_path "$port")"/"$port":*/net/*; do
        [ -d "$n" ] || continue
        basename "$n"
        return 0
    done
    return 1
}

# Драйвер, привязанный к сетевому интерфейсу порта
hl_driver_of_port() {
    local port="$1" iface
    iface=$(hl_netdev_of_port "$port") || return 1
    basename "$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null)" 2>/dev/null
}

# Обратно: USB-порт по имени интерфейса
hl_port_of_netdev() {
    local iface="$1" p
    p=$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null) || return 1
    p=$(basename "$(dirname "$p")")
    case "$p" in *:*) p="${p%%:*}" ;; esac
    printf '%s\n' "$p"
}

# --------------------------------------------------------------- реестр ----

# hl_registry_lookup <vid> <pid>  ->  "<семейство> <драйвер>"
# Неизвестное устройство не отвергаем: определяем семейство по дескрипторам.
hl_registry_lookup() {
    local vid="$1" pid="$2" line
    line=$(printf '%s\n' "$HL_REGISTRY" | awk -v k="$vid:$pid" '$1==k{print $2, $3; exit}')
    if [ -n "$line" ]; then printf '%s\n' "$line"; return 0; fi
    printf 'generic %s\n' "$(hl_guess_driver "$vid:$pid")"
}

# Драйвер по классам интерфейсов, если устройства нет в реестре
hl_guess_driver() {
    local vp="$1" out
    out=$(lsusb -v -d "$vp" 2>/dev/null | awk '
        /bInterfaceClass/ { c=$2 }
        /bInterfaceProtocol/ {
            if (c==224 && $2==3) { print "rndis_host"; exit }
        }
        /bInterfaceSubClass/ {
            if (c==2 && $2==6)  { print "cdc_ether"; exit }
            if (c==2 && $2==13) { print "cdc_ncm";   exit }
        }')
    printf '%s\n' "${out:-rndis_host}"
}

# ------------------------------------------------------------- Zero-CD -----
#
# Старый стек здесь молча выходил, если не было usb_modeswitch. Не повторяем.

hl_modeswitch() {
    local port="$1" vid="$2" pid="$3" tries=0 cfg

    require usb_modeswitch usb-modeswitch "$HL_MODESWITCH_REQUIRED" || {
        err "$port: устройство в Zero-CD ($vid:$pid), а переключать нечем — модем не поднимется"
        return 1
    }

    cfg="/etc/usb_modeswitch.d/$vid:$pid"
    [ -f "$cfg" ] || cfg="/usr/share/usb_modeswitch/$vid:$pid"
    if [ ! -f "$cfg" ]; then
        warn "$port: нет конфига usb_modeswitch для $vid:$pid, пробую HuaweiNewMode вслепую"
        cfg=""
    fi

    while [ "$tries" -lt "$HL_ZEROCD_TRIES" ]; do
        info "$port: Zero-CD $vid:$pid — usb_modeswitch (попытка $((tries + 1)))"
        if [ -n "$cfg" ]; then
            usb_modeswitch -v "$vid" -p "$pid" -c "$cfg" >/dev/null 2>&1
        else
            usb_modeswitch -v "$vid" -p "$pid" -J >/dev/null 2>&1
        fi
        sleep 3
        local now
        now=$(hl_dev_attr "$port" idProduct)
        if [ -n "$now" ] && ! hl_is_zerocd "$now"; then
            info "$port: переключился в $vid:$now"
            return 0
        fi
        tries=$((tries + 1))
    done

    warn "$port: usb_modeswitch не справился за $HL_ZEROCD_TRIES попыток — принудительный re-enumerate"
    hl_usb_reset "$port"
    return 1
}

# ------------------------------------------------------------- сброс USB ---

hl_usb_reset() {
    local port="$1" p
    p=$(hl_dev_path "$port")
    [ -d "$p" ] || return 1
    if [ -w "$p/authorized" ]; then
        info "$port: re-enumerate через authorized"
        echo 0 >"$p/authorized" 2>/dev/null
        sleep 2
        echo 1 >"$p/authorized" 2>/dev/null
        sleep 3
        return 0
    fi
    warn "$port: сбросить не получилось (нет authorized)"
    return 1
}

# Отвязать/привязать драйвер, не трогая питание — мягче полного сброса
hl_rebind() {
    local port="$1" intf drv
    for intf in "$(hl_dev_path "$port")"/"$port":*; do
        [ -d "$intf" ] || continue
        drv=$(basename "$(readlink -f "$intf/driver" 2>/dev/null)" 2>/dev/null)
        [ -n "$drv" ] && [ "$drv" != "." ] || continue
        info "$port: rebind $(basename "$intf") на $drv"
        echo "$(basename "$intf")" >"/sys/bus/usb/drivers/$drv/unbind" 2>/dev/null
        sleep 1
        echo "$(basename "$intf")" >"/sys/bus/usb/drivers/$drv/bind"   2>/dev/null
    done
    sleep 2
}

# ------------------------------------------------------ энергосбережение ---
#
# USB autosuspend на модеме = случайные обрывы. Выключаем всегда.

hl_disable_autosuspend() {
    local port="$1" p
    p=$(hl_dev_path "$port")
    [ -w "$p/power/control" ] || return 0
    if [ "$(cat "$p/power/control" 2>/dev/null)" != "on" ]; then
        echo on >"$p/power/control" 2>/dev/null &&
            dbg "$port: autosuspend выключен"
    fi
}

# --------------------------------------------------- переименование ссылки --
#
# Все модемы партии имеют одинаковый MAC, поэтому имя от MAC не годится.
# Имя берём от номера слота, номер — от физического порта.

hl_rename_netdev() {
    local iface="$1" want="$2"
    [ "$iface" = "$want" ] && return 0
    if [ -e "/sys/class/net/$want" ]; then
        warn "$want уже занят другим интерфейсом — не переименовываю $iface"
        return 1
    fi
    ip link set dev "$iface" down 2>/dev/null
    if ip link set dev "$iface" name "$want" 2>/dev/null; then
        ip link set dev "$want" up 2>/dev/null
        info "$iface -> $want"
        return 0
    fi
    ip link set dev "$iface" up 2>/dev/null
    warn "не удалось переименовать $iface в $want"
    return 1
}
