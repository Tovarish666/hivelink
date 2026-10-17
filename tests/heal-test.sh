#!/bin/bash
# Лестница починки (lib/common.sh: modem_worker, heal) на подставном модеме: без root,
# без модемов и без сети. Нужен bash 4+ (Linux).   bash tests/heal-test.sh
D=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/run" "$T/var"
sed -e "s#^RUN=/run/e3372#RUN=$T/run#" -e "s#^VAR=/var/lib/e3372#VAR=$T/var#" -e "s#/etc/e3372/e3372.conf#$T/none.conf#g" "$D/lib/common.sh" > "$T/common.sh"
. "$T/common.sh"
BASE=1800000000
now() { echo $(( BASE + $(cat "$T/now") )); }
logger() { :; }
sleep() { :; }
hl_session() { [ -f "$T/dead" ] && return 1; printf 'SessionID=x|tok'; }
hl_get() {
  case "$4" in
    /api/dialup/mobile-dataswitch) echo '<response><dataswitch>1</dataswitch></response>' ;;
    /api/monitoring/status) echo "<response><ConnectionStatus>$(cat "$T/conn")</ConnectionStatus><SimStatus>$(cat "$T/sim" 2>/dev/null || echo 1)</SimStatus></response>" ;;
    /api/net/net-mode) echo '<response><NetworkMode>00</NetworkMode><NetworkBand>3FFFFFFF</NetworkBand><LTEBand>7FFFFFFFFFFFFFFF</LTEBand></response>' ;;
  esac
}
hl_post() {
  local b="$5" c
  case "$4" in
    /api/dialup/dial) c="dial$(printf '%s' "$b" | xmlval Action)" ;;
    /api/dialup/mobile-dataswitch) c="data$(printf '%s' "$b" | xmlval dataswitch)" ;;
    /api/net/net-mode) c="mode$(printf '%s' "$b" | xmlval NetworkMode)" ;;
    /api/device/control) c=reboot ;;
  esac
  printf '%s ' "$c" >> "$T/calls"; echo '<response>OK</response>'
}
ip() { case "$*" in "rule show") printf '1007:\tfrom 192.168.7.100 lookup 7\n' ;; "route show table 7") [ -f "$T/norule" ] || echo "default via 192.168.7.1 dev eth1" ;; esac; }
curl() { [ -f "$T/netok" ]; }
iface_usb_port() { printf 1-5; }
usb_reenumerate() { printf 'reenum ' >> "$T/calls"; }
ok=0; bad=0
check() { if [ "$2" = "$3" ]; then ok=$((ok+1)); echo "  ok   $1"; else bad=$((bad+1)); echo "  FAIL $1"; echo "       ждал: $3"; echo "       было: $2"; fi; }
fresh() { rm -rf "$T/run" "$T/dead" "$T/norule" "$T/sim"; mkdir -p "$T/run"; touch "$T/netok"; echo "$1" > "$T/conn"; }
runs() { local out="" t; for t in "$@"; do : > "$T/calls"; echo "$t" > "$T/now"; modem_worker eth1 192.168.7.100; out="$out[$(sed 's/ $//' "$T/calls")]"; done; printf '%s' "$out"; }

fresh 902
check "«отключён»: дозвон -> откл/вкл -> перерегистрация -> перезагрузка" \
  "$(runs 0 60 180 360 540 720 780 900)" \
  "[dial1][][dial0 dial1][data0 mode02 mode00 data1][data0 mode02 mode00 data1][reboot][][dial1]"
check "следующая перезагрузка — не раньше чем через 30 мин" "$(runs 1080 1260 1440 2600)" \
  "[dial0 dial1][data0 mode02 mode00 data1][data0 mode02 mode00 data1][reboot]"
fresh 902; runs 0 >/dev/null; echo 901 > "$T/conn"; runs 60 >/dev/null
check "связь вернулась — лестница сначала" "$(ls "$T/run" | grep -cE '^(bad|lvl|act)\.7$')" "0"
fresh 900
check "«коннектит» 3 мин — потом сразу откл/вкл" "$(runs 0 60 120 180 240)" "[][][][dial0 dial1][]"
fresh 907
check "нет регистрации: 3 мин ищет сам, потом перерегистрация" "$(runs 0 60 180 360)" \
  "[][][data0 mode02 mode00 data1][data0 mode02 mode00 data1]"
fresh 907; echo 255 > "$T/sim"
check "нет SIM — не дёргаем" "$(runs 0 200 400 900)" "[][][][]"
fresh 901; rm -f "$T/netok"
check "«онлайн», но трафика нет: три проверки, потом откл/вкл" "$(runs 0 60 120 180)" "[][][dial0 dial1][]"
fresh 901; rm -f "$T/netok"; touch "$T/norule"
check "нет своего выхода у адреса — трафик не проверяем" "$(runs 0 60 120 180)" "[][][][]"
fresh 901
check "здоровый — ничего" "$(runs 0 100 200 400)" "[][][][]"
fresh 901; touch "$T/dead"
check "web-API молчит 10 мин — USB заново, повтор через 30 мин" "$(runs 0 300 600 900 1200 2500)" "[][][reenum][][][reenum]"
fresh 902; AUTO_HEAL=0
check "AUTO_HEAL=0 — ничего" "$(runs 0 200 400)" "[][][]"
echo "итого: ok $ok, fail $bad"
[ "$bad" -eq 0 ]
