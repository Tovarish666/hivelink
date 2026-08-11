#!/bin/bash
# hivelink / net.sh — адресация, policy routing, защита резолвера.

# ------------------------------------------------------------- параметры ---
#
# Ставятся один раз при установке и подтверждаются каждым циклом.
#   rp_filter=2      строгая проверка обратного пути ломает policy routing
#   arp_ignore=1     вся партия модемов имеет одинаковый MAC — без этого
#   arp_announce=2   ARP-ответы уезжают не в ту подсеть
#   gc_thresh        десятки подсетей переполняют neighbour table

hl_sysctl_apply() {
    local n
    # arp_ignore/arp_announce на all меняют поведение ВСЕГО хоста.
    # Для фермы с одинаковыми MAC это необходимо, но если hivelink
    # подселён к чему-то чувствительному — выключается одной строкой.
    [ "${HL_SYSCTL_GLOBAL:-1}" = 1 ] || {
        sysctl -qw net.ipv4.ip_forward=1 2>/dev/null
        return 0
    }
    for n in all default; do
        sysctl -qw "net.ipv4.conf.$n.rp_filter=2"    2>/dev/null
        sysctl -qw "net.ipv4.conf.$n.arp_ignore=1"   2>/dev/null
        sysctl -qw "net.ipv4.conf.$n.arp_announce=2" 2>/dev/null
    done
    sysctl -qw net.ipv4.neigh.default.gc_thresh1=1024 2>/dev/null
    sysctl -qw net.ipv4.neigh.default.gc_thresh2=4096 2>/dev/null
    sysctl -qw net.ipv4.neigh.default.gc_thresh3=8192 2>/dev/null
    sysctl -qw net.ipv4.ip_forward=1                  2>/dev/null
}

hl_sysctl_iface() {
    local iface="$1"
    sysctl -qw "net.ipv4.conf.$iface.rp_filter=2"    2>/dev/null
    sysctl -qw "net.ipv4.conf.$iface.arp_ignore=1"   2>/dev/null
    sysctl -qw "net.ipv4.conf.$iface.arp_announce=2" 2>/dev/null
    sysctl -qw "net.ipv4.conf.$iface.accept_redirects=0" 2>/dev/null
}

# ------------------------------------------------------------- адресация ---
#
# Статика по умолчанию. Это не только проще DHCP, но и полностью снимает
# угон резолвера: без DHCP-клиента модему просто нечем подсунуть свой DNS.

hl_addr_configure() {
    local slot="$1" iface="$2"
    local host gw net table
    host=$(hl_host "$slot"); gw=$(hl_gw "$slot")
    net=$(hl_net "$slot");   table=$(hl_table "$slot")

    ip link set dev "$iface" up 2>/dev/null
    hl_sysctl_iface "$iface"

    if ! ip -4 addr show dev "$iface" 2>/dev/null | grep -q "inet $host/24"; then
        ip -4 addr flush dev "$iface" 2>/dev/null
        if ip addr add "$host/24" dev "$iface" 2>/dev/null; then
            info "$iface: адрес $host/24"
        else
            err "$iface: не удалось назначить $host/24"
            return 1
        fi
    fi

    # Персональная таблица маршрутов: весь трафик с этого адреса уходит
    # только через свой модем и никогда не путается с соседями.
    ip route replace default via "$gw" dev "$iface" table "$table" 2>/dev/null \
        || { err "$iface: не задать default в таблице $table"; return 1; }
    ip route replace "$net.0/24" dev "$iface" src "$host" table "$table" 2>/dev/null

    hl_rule_ensure "$slot" "$host" "$table"

    # Локальный маршрут в подсети модема, чтобы веб-морда была достижима
    ip route replace "$net.0/24" dev "$iface" src "$host" 2>/dev/null

    return 0
}

hl_addr_teardown() {
    local slot="$1" iface="${2:-}" host table
    host=$(hl_host "$slot"); table=$(hl_table "$slot")
    ip rule del from "$host" lookup "$table" 2>/dev/null || true
    ip route flush table "$table" 2>/dev/null || true
    [ -n "$iface" ] && ip -4 addr flush dev "$iface" 2>/dev/null || true
    return 0
}

# ------------------------------------------------------- сборка мусора -----
#
# Номер модема может смениться: переткнули в другое гнездо, поставили пин,
# потеряли карту слотов. Старое правило "from 192.168.101.100 lookup 10101"
# при этом остаётся жить и рано или поздно перехватит трафик чужого модема.
# Поэтому каждый цикл сверяем: всё, что в нашем диапазоне таблиц, но не
# принадлежит ни одному активному слоту — сносим.
#
#   hl_gc_orphans "<активные слоты через пробел>"

hl_gc_orphans() {
    [ "${HL_GC:-1}" = 1 ] || return 0
    local active=" $1 " pref slot n=0

    # 1) правила с приоритетом из нашего диапазона
    while read -r pref; do
        [ -n "$pref" ] || continue
        slot=$((pref - HL_TABLE_BASE))
        [ "$slot" -ge "$HL_SLOT_MIN" ] 2>/dev/null || continue
        [ "$slot" -le "$HL_SLOT_MAX" ] 2>/dev/null || continue
        case "$active" in *" $slot "*) continue ;; esac
        warn "сборка мусора: слот $slot больше не занят — снимаю правило и таблицу"
        hl_addr_teardown "$slot"
        n=$((n + 1))
    done < <(ip rule list 2>/dev/null | sed -n 's/^\([0-9]\+\):.*lookup.*/\1/p' | sort -u)

    # 2) слоты, явно помеченные при перекрытии пином
    if [ -f "$HL_RUN/stale-slots" ]; then
        while read -r slot; do
            [ -n "$slot" ] || continue
            case "$active" in *" $slot "*) continue ;; esac
            hl_addr_teardown "$slot"
            n=$((n + 1))
        done <"$HL_RUN/stale-slots"
        rm -f "$HL_RUN/stale-slots"
    fi

    [ "$n" -gt 0 ] && info "сборка мусора: снято $n осиротевших слотов"
    return 0
}

# Снимок правил один раз за цикл: при 200 модемах вызывать "ip rule list"
# на каждый модем — это 200 запусков процесса на ровном месте.
hl_rules_cache() { HL_RULES_SNAPSHOT=$(ip rule list 2>/dev/null); }

hl_rule_exists() {
    case "${HL_RULES_SNAPSHOT:-}" in
        *"from $1 lookup $2"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Ровно одно правило на слот. Каждый hotplug раньше добавлял ещё одну
# копию, и они накапливались сотнями: ядро проходит их по очереди,
# а `ip rule list` превращается в простыню.
hl_rule_ensure() {
    local slot="$1" host="$2" table="$3" pref n
    pref=$((HL_TABLE_BASE + slot))

    n=$(ip rule list 2>/dev/null | grep -c "from $host lookup $table" || true)

    if [ "$n" = 0 ]; then
        ip rule add from "$host" lookup "$table" pref "$pref" 2>/dev/null
        return 0
    fi
    while [ "$n" -gt 1 ] 2>/dev/null; do
        ip rule del from "$host" lookup "$table" 2>/dev/null || break
        n=$((n - 1))
        dbg "слот $slot: снят дубль правила"
    done
    return 0
}

# Две разные железки, оказавшиеся в одной подсети, — верный признак того,
# что модем не переопределился и остался на заводском адресе.
# Обслуживаем первого, второго громко помечаем: чинится переопределением,
# а не маршрутами.
hl_subnet_conflict() {
    local slot="$1" iface="$2" host other
    host=$(hl_host "$slot")
    other=$(ip -4 -o addr show 2>/dev/null | awk -v h="$host" -v i="$iface" \
            '$4 ~ "^"h"/" && $2!=i {print $2; exit}')
    if [ -n "$other" ]; then
        err "слот $slot: адрес $host уже висит на $other — два модема в одной подсети;"
        err "  скорее всего модем не переопределился с заводского адреса"
        return 0
    fi
    return 1
}

# --------------------------------------------------------- защита DNS ------
#
# Известный косяк: модем раздаёт себя как DNS, что-нибудь на хосте это
# подхватывает — и резолвинг всего сервера уезжает в случайный модем.
# При статике этого не случается, но проверяем и чиним на всякий случай:
# путей утечки много (dhclient-хуки, networkd, NM).

hl_dns_hijacked() {
    local f=/etc/resolv.conf ns
    [ -r "$f" ] || return 1
    while read -r ns; do
        case "$ns" in
            "$HL_SUBNET_PREFIX".*) return 0 ;;
        esac
    done < <(awk '/^nameserver/{print $2}' "$f" 2>/dev/null)
    return 1
}

hl_dns_guard() {
    [ "$HL_DNS_GUARD" = 1 ] || return 0

    # Пустой резолвер — такая же поломка, как угнанный: хост без DNS.
    local empty=0
    grep -q '^nameserver' /etc/resolv.conf 2>/dev/null || empty=1
    [ "$empty" = 1 ] || hl_dns_hijacked || return 0

    if [ "$empty" = 1 ]; then
        err "в /etc/resolv.conf не осталось ни одного nameserver"
    else
        err "резолвер угнан модемом: в /etc/resolv.conf прописан $HL_SUBNET_PREFIX.*"
    fi

    # Источник правды: явная настройка, иначе снимок, снятый при установке
    if [ -z "${HL_DNS_UPSTREAM:-}" ] && [ -s "$HL_VAR/resolv.upstream" ]; then
        HL_DNS_UPSTREAM=$(tr '\n' ' ' <"$HL_VAR/resolv.upstream")
        dbg "беру DNS из снимка: $HL_DNS_UPSTREAM"
    fi

    if [ -z "${HL_DNS_UPSTREAM:-}" ]; then
        warn "HL_DNS_UPSTREAM не задан и снимка нет — чинить нечем, только сообщаю"
        return 1
    fi

    if [ -L /etc/resolv.conf ]; then
        warn "/etc/resolv.conf это симлинк на $(readlink -f /etc/resolv.conf) — чинит его владелец, не трогаю"
        return 1
    fi

    cp -a /etc/resolv.conf "/etc/resolv.conf.hivelink-bak" 2>/dev/null
    {
        echo "# восстановлено hivelink"
        for ns in $HL_DNS_UPSTREAM; do echo "nameserver $ns"; done
    } >/etc/resolv.conf
    info "резолвер восстановлен: $HL_DNS_UPSTREAM (бэкап в /etc/resolv.conf.hivelink-bak)"
}

# Запрет networkd брать DNS с модемных линков
hl_networkd_dropin() {
    local dir=/etc/systemd/network
    [ -d "$dir" ] || return 0
    local f="$dir/10-hivelink-modems.network"
    cat >"$f" <<EOF
# hivelink: модемные линки настраиваются нами вручную.
#
# UseDNS=no + DNS= + DNSDefaultRoute=no — не пускать DNS модема
#   в системный резолвер, иначе резолвинг всего хоста уедет в модем.
# UseGateway/UseRoutes=no — иначе сорок default route дерутся с маршрутом
#   хоста; наши маршруты живут только в своих таблицах.
# RequiredForOnline=no — иначе загрузка ждёт готовности всех модемов.
[Match]
Name=${HL_IFACE_PREFIX}*
Driver=rndis_host cdc_ether cdc_ncm huawei_cdc_ncm

[Link]
RequiredForOnline=no

[Network]
DHCP=no
LinkLocalAddressing=no
IPv6AcceptRA=no
DNS=
DNSDefaultRoute=no

[DHCPv4]
UseDNS=no
UseNTP=no
UseRoutes=no
UseGateway=no
UseDomains=no
EOF
    dbg "networkd drop-in: $f"
}

# Снимок рабочего резолвера. Делается при установке, пока всё ещё цело,
# и служит источником правды для стража DNS.
hl_dns_snapshot() {
    local f="$HL_VAR/resolv.upstream"
    [ -s "$f" ] && return 0
    hl_dns_hijacked && { warn "резолвер уже угнан — снимок не делаю"; return 1; }
    awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null \
        | grep -v "^${HL_SUBNET_PREFIX}\." >"$f"
    if [ -s "$f" ]; then
        info "снимок резолвера: $(tr '\n' ' ' <"$f")"
    else
        rm -f "$f"
        warn "в /etc/resolv.conf нет пригодных nameserver — задай HL_DNS_UPSTREAM вручную"
        return 1
    fi
}

# ------------------------------------------------------------- разведка ---
#
# Прежде чем что-то менять, надо узнать, где модем УЖЕ живёт. Иначе
# hivelink переселит нормально работающий модем со своего адреса на «свой»
# и сломает то, что работало.
#
# Спрашиваем сам модем через DHCP. Хук намеренно ничего не настраивает —
# штатный скрипт udhcpc прописал бы DNS модема в системный резолвер.
#
# Печатает третий октет подсети модема, либо ничего.

hl_discover_lan() {
    local iface="$1" out gw n
    out="$HL_RUN/dhcp.$iface"
    rm -f "$out"

    ip link set dev "$iface" up 2>/dev/null

    if command -v udhcpc >/dev/null 2>&1; then
        HL_DHCP_OUT="$out" timeout 8 udhcpc -i "$iface" -q -n -t 3 -T 2 \
            -s "$HL_LIB/dhcp-probe.sh" >/dev/null 2>&1
    elif command -v busybox >/dev/null 2>&1; then
        HL_DHCP_OUT="$out" timeout 8 busybox udhcpc -i "$iface" -q -n -t 3 -T 2 \
            -s "$HL_LIB/dhcp-probe.sh" >/dev/null 2>&1
    else
        dbg "$iface: нет udhcpc, разведка подсети недоступна"
        return 1
    fi

    [ -s "$out" ] || return 1
    gw=$(awk '{print $2}' "$out")
    rm -f "$out"
    [ -n "$gw" ] || return 1

    # интересует только наш префикс: 192.168.N.1 -> N
    case "$gw" in
        "$HL_SUBNET_PREFIX".*) ;;
        *) dbg "$iface: модем на $gw, это вне префикса $HL_SUBNET_PREFIX"; return 1 ;;
    esac
    n=$(printf '%s' "$gw" | cut -d. -f3)
    [ "$n" -ge "$HL_SLOT_MIN" ] 2>/dev/null || return 1
    [ "$n" -le "$HL_SLOT_MAX" ] 2>/dev/null || return 1

    printf '%s\n' "$n"
}

# --------------------------------------------------------- проверка связи --

hl_probe() {
    local slot="$1" host target="${2:-$HL_WATCHDOG_PING}"
    host=$(hl_host "$slot")
    ping -c1 -W3 -I "$host" "$target" >/dev/null 2>&1
}

hl_probe_gw() {
    local slot="$1" host gw
    host=$(hl_host "$slot"); gw=$(hl_gw "$slot")
    ping -c1 -W2 -I "$host" "$gw" >/dev/null 2>&1
}
