#!/bin/bash
# Zero-CD (sbin/e3372-reconcile: step_zerocd) и «только рабочий режим» (lib/common.sh) на
# подставном sysfs: без root и без модемов. Нужен bash 4+ (Linux).   bash tests/zerocd-test.sh
D=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/run" "$T/var" "$T/ms.d" "$T/rnet" "$T/enet" "$T/sys"
sed -e "s#^RUN=/run/e3372#RUN=$T/run#" -e "s#^VAR=/var/lib/e3372#VAR=$T/var#" \
    -e "s#/etc/e3372/e3372.conf#$T/none.conf#g" -e "s#^MODESWITCH_D=.*#MODESWITCH_D=$T/ms.d#" \
    -e "s#/run/systemd/network/#$T/rnet/#g" -e "s#/etc/systemd/network/\*#$T/enet/*#g" \
    -e "s#^ETH0_LINK=.*#ETH0_LINK=$T/enet/10-e3372-eth0.link#" -e "s#^ZEROCD_DELAY=.*#ZEROCD_DELAY=0#" \
    "$D/lib/common.sh" > "$T/common.sh"
. "$T/common.sh"
# шаг Zero-CD из драйвера; воркеры xargs — та же функция в дочернем bash
sed -n '/^zerocd_worker()/,/^}/p; /^step_zerocd()/,/^}/p' "$D/sbin/e3372-reconcile" \
    | sed 's#"\$0" --zerocd#bash -c '"'"'zerocd_worker "$@"'"'"' _#' > "$T/steps.sh"
. "$T/steps.sh"
echo 1 > "$T/ms.d/12d1:1f01"
BASE=1800000000
now() { echo $(( BASE + $(cat "$T/now") )); }
logger() { printf '%s\n' "$*" >> "$T/log"; }
sleep() { printf '%s\n' "$1" >> "$T/sleeps"; }
usb_modeswitch() { printf '%s\n' "$*" >> "$T/ms.log"; [ -f "$T/msfail" ] && echo "Error: no response" || echo "Message successfully sent"; }
usb_reenumerate() { printf '%s\n' "${1##*/}" >> "$T/reenum"; }
export -f zerocd_worker usb_modeswitch log logger
export MODESWITCH_D TAG T
usb_devs() { ls -d "$T"/sys/* 2>/dev/null | grep -v ':'; }

# устройство: порт pid cfg/всего [номер CD-интерфейса в hex, пусто — нет]. Интерфейсы — рядом
# с устройством, как в /sys/bus/usb/devices (3-1.4 и 3-1.4:2.0).
dev() {
    local d="$T/sys/$1" i="$T/sys/$1:${3%/*}"; mkdir -p "$d"
    echo "$2" > "$d/idProduct"; echo "${3%/*}" > "$d/bConfigurationValue"; echo "${3#*/}" > "$d/bNumConfigurations"
    echo 3 > "$d/busnum"; echo "${1##*.}" > "$d/devnum"
    mkdir -p "$i.0"; echo 02 > "$i.0/bInterfaceClass"; echo 00 > "$i.0/bInterfaceNumber"
    if [ -n "${4:-}" ]; then
        mkdir -p "$i.$4"; echo 08 > "$i.$4/bInterfaceClass"; echo "$4" > "$i.$4/bInterfaceNumber"
    fi
}
pass() { echo "$1" > "$T/now"; : > "$T/ms.log"; step_zerocd; }
calls() { grep -c . "$T/ms.log" 2>/dev/null; }

ok=0; bad=0
check() { if [ "$2" = "$3" ]; then ok=$((ok+1)); echo "  ok   $1"; else bad=$((bad+1)); echo "  FAIL $1"; echo "       ждал: $3"; echo "       было: $2"; fi; }

dev 3-1.4 1f01 2/2 02
check "CD-интерфейс в MBIM-конфигурации: номер" "$(ms_iface "$T/sys/3-1.4")" "2"
pass 0
check "команда — в CD-интерфейс текущей cfg (-i 2), своим конфигом" "$(cat "$T/ms.log")" \
      "-v 12d1 -p 1f01 -b 3 -g 4 -c $T/ms.d/12d1:1f01 -i 2"
check "конфигурацию не трогаем" "$(cat "$T/sys/3-1.4/bConfigurationValue")" "2"
pass 10
check "модем ещё переподключается (10 с) — не повторяем" "$(calls)" "0"
pass 30; pass 60
check "через ZEROCD_WAIT — третья попытка" "$(cat "$T/run/zerocd.3-1.4")" "3"
pass 90
check "не переключился за 3 попытки — пере-enumerate" "$(cat "$T/reenum" 2>/dev/null)/$(calls)" "3-1.4/0"

rm -rf "$T/sys" "$T/run"/* "$T/reenum"; mkdir -p "$T/sys"
dev 3-1.5 1f01 2/2
pass 0
check "CD-интерфейса нет — cfg 1" "$(cat "$T/sys/3-1.5/bConfigurationValue")" "1"
echo 2 > "$T/sys/3-1.5/bConfigurationValue"; pass 1; pass 2; pass 3
check "…и не каждый проход (модем на смену cfg переподключается)" "$(cat "$T/sys/3-1.5/bConfigurationValue")" "2"
pass 4
check "…раз в 4 прохода" "$(cat "$T/sys/3-1.5/bConfigurationValue")" "1"

rm -rf "$T/sys" "$T/run"/*; mkdir -p "$T/sys"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do dev "3-1.$i" 1f01 2/2 02; done
dev 3-2.1 14db 1/2
pass 0
check "двенадцать Zero-CD — двенадцать команд" "$(calls)" "12"
check "не все сразу: по 2, между партиями пауза 3 с (5 пауз)" "$(grep -c '^3$' "$T/sleeps")" "5"
check "каждому — своё устройство" "$(sed 's/.*-g \([0-9]*\).*/\1/' "$T/ms.log" | sort -n | tr '\n' ' ')" "1 2 3 4 5 6 7 8 9 10 11 12 "
check "HiLink-модем не трогаем" "$(grep -c -- '-p 14db' "$T/ms.log")" "0"
check "в журнале — сколько переключаю" "$(grep -c 'Zero-CD: переключаю 12' "$T/log")" "1"
rm -rf "$T/sys" "$T/run"/*; mkdir -p "$T/sys"; : > "$T/log"
dev 3-1.9 1f01 1/2 0a; touch "$T/msfail"; pass 0; rm -f "$T/msfail"
check "CD-интерфейс в hex (0a = 10)" "$(sed 's/.*-i //' "$T/ms.log")" "10"
check "не отправил — в журнал с ответом" "$(grep -c 'не отправил (попытка 1): Error: no response' "$T/log")" "1"
echo 14db > "$T/sys/3-1.9/idProduct"; pass 200
check "переключился — счётчики чистятся" "$(ls "$T/run" | grep -c '3-1.9')" "0"

rm -rf "$T/sys" "$T/run"/*; mkdir -p "$T/sys"
ZEROCD_DELAY=10
dev 3-1.7 1f01 1/2 02
pass 0; pass 5
check "только появился — первые 10 с не трогаем (модем грузится)" "$(calls)" "0"
pass 11
check "через 10 с — переключаем" "$(calls)" "1"
ZEROCD_DELAY=0

q=$(storage_quirks "0bc2:2322:u,12d1:1f01:u")
check "quirks: чужие на месте, наши «i», старые 12d1 заменены" "${q%%,*} $(echo "$q" | tr ',' '\n' | grep -c '^12d1:.*:i$') $(echo "$q" | grep -c '12d1:1f01:u')" "0bc2:2322:u 9 0"
check "quirks: не длиннее 127" "$([ ${#q} -le 127 ] && echo да)" "да"
long=$(printf 'abcd:%04x:u,' $(seq 1 8)); long=${long%,}
q=$(storage_quirks "$long")
check "quirks: чужие не выталкиваем, наши — сколько влезет" "$([ "${q:0:${#long}}" = "$long" ] && [ ${#q} -le 127 ] && echo да) $(echo "$q" | tr ',' '\n' | grep -c '^12d1:')" "да 2"
check "modprobe: MBIM запрещён, usb-storage с quirks" "$(modprobe_text | grep -cE '^(blacklist cdc_mbim|install cdc_mbim /bin/true|options usb-storage quirks=12d1:1f01:i,)')" "3"

printf '[Match]\nPermanentMACAddress=BC:24:11:AA:BB:CC\n[Link]\nName=eth0\nWakeOnLan=off\n' > "$T/rnet/10-netplan-eth0.link"
check "MAC основной карты — из .link netplan (Name=eth0)" "$(primary_mac)" "bc:24:11:aa:bb:cc"
rm "$T/rnet/10-netplan-eth0.link"; printf '[Match]\nMACAddress=bc:24:11:00:00:01\n[Link]\nName=vmbr9\n' > "$T/enet/20-x.link"
check "нет правила eth0 (хост Proxmox) — пусто" "$(primary_mac)" ""
check ".link: eth0 по постоянному MAC" "$(eth0_link_text bc:24:11:aa:bb:cc | grep -cE '^(PermanentMACAddress=bc:24:11:aa:bb:cc|Name=eth0)$')" "2"

echo; echo "итого: ok $ok, fail $bad"
[ "$bad" = 0 ]
