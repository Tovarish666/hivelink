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

    if [ -n "${HL_RULES_SNAPSHOT:-}" ]; then
        hl_rule_exists "$host" "$table" \
            || ip rule add from "$host" lookup "$table" pref "$((HL_TABLE_BASE + slot))" 2>/dev/null
    else
        ip rule list 2>/dev/null | grep -q "from $host lookup $table" \
            || ip rule add from "$host" lookup "$table" pref "$((HL_TABLE_BASE + slot))" 2>/dev/null
    fi

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
    hl_dns_hijacked || return 0

    err "резолвер угнан модемом: в /etc/resolv.conf прописан $HL_SUBNET_PREFIX.*"

    if [ -z "${HL_DNS_UPSTREAM:-}" ]; then
        warn "HL_DNS_UPSTREAM не задан в $HL_CONF — чинить нечем, только сообщаю"
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
# Главное здесь — UseDNS=no: не пускать DNS модема в системный резолвер.
[Match]
Name=${HL_IFACE_PREFIX}*

[Network]
DHCP=no
LinkLocalAddressing=no
IPv6AcceptRA=no

[DHCPv4]
UseDNS=no
UseNTP=no
UseRoutes=no
UseDomains=no
EOF
    dbg "networkd drop-in: $f"
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
