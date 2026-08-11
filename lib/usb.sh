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
    local port="$1" vid="$2" pid="$3" tries=0 cfg cur total

    require usb_modeswitch usb-modeswitch "$HL_MODESWITCH_REQUIRED" || {
        err "$port: устройство в Zero-CD ($vid:$pid), а переключать нечем — модем не поднимется"
        return 1
    }

    # Ядро могло сесть не на ту конфигурацию. У этих устройств в Zero-CD
    # бывает вторая конфигурация с MBIM: cdc_mbim её захватывает, появляется
    # бесполезный wwanN, а mass-storage endpoint, куда usb_modeswitch шлёт
    # своё сообщение, в ней просто отсутствует. Отсюда бесконечные
    # безрезультатные попытки. Сначала возвращаем конфигурацию 1.
    cur=$(hl_cfg_current "$port")
    total=$(hl_cfg_count "$port")
    if [ -n "$cur" ] && [ "$cur" != 1 ] && [ "$total" -gt 1 ] 2>/dev/null; then
        warn "$port: Zero-CD в конфигурации $cur из $total — usb_modeswitch там бессилен, ставлю 1"
        if hl_cfg_set "$port" 1; then
            sleep 2
            pid=$(hl_dev_attr "$port" idProduct)
            hl_is_zerocd "$pid" || { info "$port: после смены конфигурации уже $vid:$pid"; return 0; }
        fi
    fi

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
#
# Потолок обязателен: без него модем, который не оживает в принципе,
# будет пересоздаваться вечно и мешать соседям по хабу. Счётчик
# сбрасывается ТОЛЬКО при успешном выходе модема в сеть.

hl_usb_reset() {
    local port="$1" p n
    p=$(hl_dev_path "$port")
    [ -d "$p" ] || return 1

    n=$(hl_cnt_bump reenum "$port")
    if [ "$n" -gt "${HL_REENUM_MAX:-5}" ]; then
        warn "$port: уже $((n - 1)) re-enumerate без толку — больше не трогаю до успеха"
        return 1
    fi

    if [ -w "$p/authorized" ]; then
        info "$port: re-enumerate через authorized (попытка $n/${HL_REENUM_MAX:-5})"
        echo 0 >"$p/authorized" 2>/dev/null
        sleep 2
        echo 1 >"$p/authorized" 2>/dev/null
        sleep 3
        return 0
    fi
    warn "$port: сбросить не получилось (нет authorized)"
    return 1
}

# ------------------------------------------- перебор USB-конфигураций ------
#
# Ядро само выбирает конфигурацию и порой садится не на ту: у HiLink это
# обычно NCM-конфигурация, дающая wwanN без DHCP вместо ethN с DHCP.
# Перебираем bConfigurationValue и запоминаем удачную ПО МОДЕЛИ, чтобы
# одинаковые модемы правились сразу, без перебора.
#
# Запись bConfigurationValue при активной конфигурации отбивается EBUSY,
# поэтому сначала -1 (расконфигурировать), и только потом целевое значение.

hl_cfg_count() {
    local port="$1" v
    v=$(hl_dev_attr "$port" bNumConfigurations)
    printf '%s\n' "${v:-1}"
}

hl_cfg_current() { hl_dev_attr "$1" bConfigurationValue; }

hl_cfg_set() {
    local port="$1" val="$2" f
    f="$(hl_dev_path "$port")/bConfigurationValue"
    [ -w "$f" ] || { dbg "$port: bConfigurationValue не пишется"; return 1; }

    # Расконфигурировать, иначе ядро вернёт EBUSY
    echo -1 >"$f" 2>/dev/null
    sleep 1
    if echo "$val" >"$f" 2>/dev/null; then
        sleep 2
        return 0
    fi
    warn "$port: не удалось выставить конфигурацию $val"
    return 1
}

# ГОДНЫЙ интерфейс, а не любой.
#
# wwanN на cdc_mbim/qmi_wwan — это raw-IP без DHCP и без веб-морды HiLink.
# Формально сетевой интерфейс есть, фактически модем бесполезен: адреса
# взять неоткуда, API недостижим. Считать такую конфигурацию удачной —
# значит своими руками загнать модем в нерабочее состояние.
hl_netdev_usable() {
    local port="$1" iface drv
    iface=$(hl_netdev_of_port "$port" 2>/dev/null) || return 1
    drv=$(basename "$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null)" 2>/dev/null)
    case "$drv" in
        rndis_host|cdc_ether|cdc_ncm|huawei_cdc_ncm) ;;
        *) dbg "$port: $iface на драйвере '$drv' — не годится"; return 1 ;;
    esac
    # NOARP = raw-IP режим, DHCP по нему не поедет
    case "$(cat "/sys/class/net/$iface/flags" 2>/dev/null)" in
        "") return 1 ;;
    esac
    if ip link show "$iface" 2>/dev/null | grep -q NOARP; then
        dbg "$port: $iface в режиме NOARP (raw-IP) — DHCP и веб-морда недоступны"
        return 1
    fi
    printf '%s\n' "$iface"
    return 0
}

# Подобрать конфигурацию, при которой появляется ГОДНЫЙ интерфейс.
# Возвращает 0, если он есть (в том числе если был изначально).
hl_cfg_probe() {
    local port="$1" model="$2" total cur known n try start

    [ "${HL_CFG_PROBE:-1}" = 1 ] || return 1
    hl_netdev_usable "$port" >/dev/null 2>&1 && return 0

    # Запоминаем, с чего начали: если перебор ничего не даст, надо
    # вернуть модем как было, а не бросить в случайной конфигурации.
    start=$(hl_cfg_current "$port")

    total=$(hl_cfg_count "$port")
    [ "$total" -gt 1 ] 2>/dev/null || {
        dbg "$port: конфигурация одна, перебирать нечего"
        return 1
    }

    # Удачная конфигурация для этой модели уже известна?
    known=$(hl_confmap_get "cfg:$model")
    if [ -n "$known" ] && [ "$known" != none ]; then
        cur=$(hl_cfg_current "$port")
        if [ "$cur" != "$known" ]; then
            info "$port: ставлю известную для модели конфигурацию $known"
            hl_cfg_set "$port" "$known" && hl_netdev_usable "$port" >/dev/null 2>&1 && return 0
        fi
    fi

    try=$(hl_cnt_get cfg "$port")
    if [ "$try" -ge "${HL_CFG_MAX_TRIES:-6}" ]; then
        warn "$port: перебор конфигураций исчерпан ($try), возвращаю исходную $start"
        hl_cfg_set "$port" "${known:-$start}" >/dev/null 2>&1
        return 1
    fi

    for n in $(seq 1 "$total"); do
        hl_cnt_bump cfg "$port" >/dev/null
        [ "$(hl_cfg_current "$port")" = "$n" ] && continue
        info "$port: пробую конфигурацию $n из $total"
        hl_cfg_set "$port" "$n" || continue
        if hl_netdev_usable "$port" >/dev/null 2>&1; then
            info "$port: конфигурация $n дала годный интерфейс — запоминаю для модели $model"
            hl_confmap_set "cfg:$model" "$n"
            hl_cnt_clear cfg "$port"
            return 0
        fi
        dbg "$port: конфигурация $n не дала годного интерфейса"
    done

    # Ничего не подошло — возвращаем как было. Оставить модем в чужой
    # конфигурации хуже, чем не трогать вовсе.
    warn "$port: ни одна из $total конфигураций не дала годного интерфейса, откатываю на $start"
    [ -n "$start" ] && hl_cfg_set "$port" "$start" >/dev/null 2>&1
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
    return 0
}

# Уснувший ХАБ утаскивает за собой всю ветку — модемы под ним просто
# исчезают, и это выглядит как отказ железа. Гасим энергосбережение
# на всех хабах, а не только на модемах.
hl_disable_hub_autosuspend() {
    local d n=0
    for d in /sys/bus/usb/devices/*/; do
        [ -f "$d/bDeviceClass" ] || continue
        [ "$(cat "$d/bDeviceClass" 2>/dev/null)" = "09" ] || continue
        [ -w "$d/power/control" ] || continue
        if [ "$(cat "$d/power/control" 2>/dev/null)" != "on" ]; then
            echo on >"$d/power/control" 2>/dev/null && n=$((n + 1))
        fi
        # autosuspend_delay -1 запрещает засыпание окончательно
        [ -w "$d/power/autosuspend_delay_ms" ] &&
            echo -1 >"$d/power/autosuspend_delay_ms" 2>/dev/null
    done
    [ "$n" -gt 0 ] && info "погашен autosuspend на $n хабах"
    return 0
}

# Буфер usbfs. По умолчанию 16 МБ на всё ядро. При десятках модемов
# с крупными RX-URB (наш фикс поднимает их до 16 КБ) это упирается,
# и submit начинает падать с ENOMEM — выглядит как случайные обрывы.
hl_usbfs_tune() {
    local want="${HL_USBFS_MB:-1024}" f=/sys/module/usbcore/parameters/usbfs_memory_mb cur
    [ -w "$f" ] || return 0
    cur=$(cat "$f" 2>/dev/null || echo 0)
    [ "$cur" -ge "$want" ] 2>/dev/null && return 0
    echo "$want" >"$f" 2>/dev/null && info "usbfs_memory_mb: $cur -> $want"
    return 0
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
