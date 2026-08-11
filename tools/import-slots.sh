#!/bin/bash
# hivelink — перенос текущей раскладки модемов в новый формат.
#
# ЗАПУСКАТЬ ДО purge-legacy.sh, пока старый стек ещё держит адреса.
#
# Зачем: hivelink выдаёт номера слотов заново, начиная с HL_SLOT_MIN.
# Если этого не сделать, модем, который сегодня живёт на 192.168.104.x,
# после установки может стать 192.168.101.x — и всё, что ссылается на
# старые адреса (прокси, правила, выгрузки), сломается.
#
# Скрипт читает живое состояние: у каждого модемного интерфейса есть
# адрес вида PREFIX.N.HOST, из него и берётся номер N, а порт — из sysfs.
#
#   bash import-slots.sh              показать, что получилось
#   bash import-slots.sh --write      записать в /var/lib/hivelink/slots

set -uo pipefail

WRITE=0
[ "${1:-}" = "--write" ] && WRITE=1

PREFIX="${HL_SUBNET_PREFIX:-192.168}"
HOSTOCT="${HL_HOST_OCTET:-100}"
OUT=/var/lib/hivelink/slots

say()  { printf '\033[36m==\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[31m!!\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "нужен root"

TMP=$(mktemp)
found=0

for d in /sys/class/net/*/device/driver; do
    [ -e "$d" ] || continue
    drv=$(basename "$(readlink -f "$d")")
    case "$drv" in
        rndis_host|cdc_ether|cdc_ncm|huawei_cdc_ncm) ;;
        *) continue ;;
    esac

    iface=$(echo "$d" | cut -d/ -f5)

    # номер берём из назначенного адреса PREFIX.N.HOSTOCT
    n=$(ip -4 -o addr show dev "$iface" 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 \
        | awk -F. -v p1="${PREFIX%%.*}" -v p2="${PREFIX##*.}" -v h="$HOSTOCT" \
              '$1==p1 && $2==p2 && $4==h {print $3; exit}')

    if [ -z "$n" ]; then
        warn "$iface ($drv): нет адреса вида $PREFIX.N.$HOSTOCT — пропускаю"
        continue
    fi

    # физический USB-порт
    p=$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null) || continue
    port=$(basename "$(dirname "$p")")
    case "$port" in *:*) port="${port%%:*}" ;; esac

    printf '%s %s\n' "$port" "$n" >>"$TMP"
    printf '  %-14s %-10s -> слот %s\n' "$port" "$iface" "$n"
    found=$((found + 1))
done

echo
if [ "$found" = 0 ]; then
    rm -f "$TMP"
    die "модемов с настроенными адресами не найдено. Старый стек уже снят?"
fi

# дубликаты номеров — верный признак, что что-то не так
dups=$(awk '{print $2}' "$TMP" | sort | uniq -d)
[ -n "$dups" ] && warn "повторяющиеся номера: $dups — проверь глазами"

say "найдено модемов: $found"

if [ "$WRITE" != 1 ]; then
    rm -f "$TMP"
    say "это был показ. Записать:  bash $0 --write"
    exit 0
fi

mkdir -p "$(dirname "$OUT")"
if [ -s "$OUT" ]; then
    cp -a "$OUT" "$OUT.bak"
    warn "прежняя карта сохранена в $OUT.bak"
fi
sort -k2 -n "$TMP" >"$OUT"
rm -f "$TMP"

say "записано в $OUT"
sed 's/^/  /' "$OUT"
echo
say "теперь можно: bash tools/purge-legacy.sh --apply && bash install.sh"
