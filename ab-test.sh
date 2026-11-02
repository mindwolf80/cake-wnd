#!/bin/bash
# Alternate wnd_clamp off/on under the same load and record per-run deltas.
# usage: ab-test.sh [pairs=6] [load=ookla|long] [ookla server id]
# Pairs run ABBA (off,on / on,off / ...) so drift hits both conditions evenly.
# Refuses to run over Wi-Fi: turns Wi-Fi off if needed (back on at exit) and checks
# that the test routes leave on a wired interface.
#   ookla: Ookla CLI, multi-stream, ~10-15 s per direction; first run's server is reused.
#   long:  one 60 s single-stream download, ping to 1.1.1.1 alongside for loaded latency.
#          The ingress shaper is lowered to $LONG_SHAPE so the stream queues in CAKE.
set -euo pipefail
R=root@192.168.1.1
PAIRS=${1:-6}
LOAD=${2:-ookla}
SID=${3:-}
LONG_HOST=ash-speed.hetzner.com
LONG_URL=https://$LONG_HOST/10GB.bin
LONG_SHAPE=${LONG_SHAPE:-200Mbit}
IFB=ifb4eth1
OUT=ab-$LOAD-$(date +%F-%H%M).csv
P=/sys/module/sch_cake/parameters

ssh -o BatchMode=yes $R "[ -w $P/wnd_clamp ]" || { echo "cake-wnd module not loaded"; exit 1; }
SHAPE0=$(ssh -o BatchMode=yes $R "tc qdisc show dev $IFB" | sed -n 's/.* bandwidth \([0-9]*[KMG]*bit\).*/\1/p')
[ -n "$SHAPE0" ] || { echo "no cake bandwidth on $IFB"; exit 1; }
WIFI_OFFED=0
restore() {
	ssh -o BatchMode=yes $R "echo 0 > $P/wnd_clamp; tc qdisc change dev $IFB root cake bandwidth $SHAPE0" &&
		echo "wnd_clamp reset to 0, $IFB bandwidth restored to $SHAPE0"
	if [ $WIFI_OFFED = 1 ]; then nmcli radio wifi on && echo "Wi-Fi turned back on"; fi
}
trap restore EXIT

route_dev() { ip -4 route get "$1" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p'; }
is_wifi() { [ -z "$1" ] || [ -d "/sys/class/net/$1/wireless" ]; }
TEST_IP=$(getent ahostsv4 $LONG_HOST | awk 'NR == 1 {print $1}')
if is_wifi "$(route_dev 1.1.1.1)" || is_wifi "$(route_dev $TEST_IP)"; then
	echo "test route is on Wi-Fi; turning Wi-Fi off"
	nmcli radio wifi off
	WIFI_OFFED=1
	for _ in $(seq 15); do is_wifi "$(route_dev 1.1.1.1)" || break; sleep 1; done
fi
for ip in 1.1.1.1 $TEST_IP; do
	d=$(route_dev $ip)
	if is_wifi "$d"; then echo "route to $ip uses '${d:-none}', not a wired link - refusing to run"; exit 1; fi
	echo "route to $ip: $d"
done
if [ "$LOAD" = long ]; then
	ssh -o BatchMode=yes $R "tc qdisc change dev $IFB root cake bandwidth $LONG_SHAPE"
	echo "$IFB bandwidth $SHAPE0 -> $LONG_SHAPE for this test"
fi

# ifb_drops eth1_drops flagged cuts raises clamped skip_noct skip_collide
router_snap() {
	ssh -o BatchMode=yes $R "
		for d in $IFB eth1; do tc -s qdisc show dev \$d | sed -n 's/.*(dropped \([0-9]*\),.*/\1/p' | head -1; done
		cat $P/wnd_flagged $P/wnd_cuts $P/wnd_raises $P/wnd_clamped $P/wnd_skip_noct $P/wnd_skip_collide" | tr '\n' ' '
}
retrans() { nstat -asz TcpRetransSegs | awk '/TcpRetransSegs/{print $2}'; }

# prints: server down_mbps up_mbps idle_ms down_lat_ms up_lat_ms
run_ookla() {
	python3 -Ic 'import json,sys
j=json.loads(sys.argv[1])
print(j["server"]["id"], round(j["download"]["bandwidth"]*8/1e6,1), round(j["upload"]["bandwidth"]*8/1e6,1),
      j["ping"]["latency"], j["download"]["latency"]["iqm"], j["upload"]["latency"]["iqm"])' \
		"$(speedtest -f json ${SID:+-s $SID})"
}
run_long() {
	local pf bps
	pf=$(mktemp)
	ping -n -i 0.2 -w 62 1.1.1.1 > "$pf" &
	bps=$(curl -4 -s -o /dev/null --max-time 60 -w '%{speed_download}' "$LONG_URL" || true)
	wait
	# loaded latency = median of pings taken during the download
	echo "hetzner-ash $(awk -v b="$bps" 'BEGIN{printf "%.1f", b*8/1e6}') - -" \
		"$(sed -n 's/.*time=\([0-9.]*\).*/\1/p' "$pf" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')" -
	rm -f "$pf"
}

echo "time,iface,clamp,server,down_mbps,up_mbps,idle_ms,down_lat_ms,up_lat_ms,ifb_drops,eth1_drops,flagged,cuts,raises,clamped,skip_noct,skip_collide,client_retrans" > "$OUT"

for ((i = 0; i < PAIRS; i++)); do
	order="0 1"; ((i % 2)) && order="1 0"
	for clamp in $order; do
		ssh -o BatchMode=yes $R "echo $clamp > $P/wnd_clamp"
		read -ra a <<< "$(router_snap)"; r0=$(retrans)
		read -r sid down up idle dl ul <<< "$(run_$LOAD)"
		read -ra b <<< "$(router_snap)"; r1=$(retrans)
		[ "$LOAD" = ookla ] && SID=${SID:-$sid}

		d=""
		for k in 0 1 2 3 4 5 6 7; do d+=",$(( b[k] - a[k] ))"; done
		echo "$(date +%T),$(route_dev 1.1.1.1),$clamp,$sid,$down,$up,$idle,$dl,$ul$d,$(( r1 - r0 ))" | tee -a "$OUT"
	done
done

echo
echo "results: $OUT"
awk -F, 'NR > 1 {
	c = $3; n[c]++; drops[c] += $10; if (!c) d0[n[c]] = $10; down[c] += $5; dl[c] += $8; rt[c] += $18
	fl[c] += $12; cl[c] += $15; noct[c] += $16; col[c] += $17 }
END {
	for (c = 0; c <= 1; c++) if (n[c])
		printf "clamp=%d  runs=%d  mean ifb_drops=%.0f  down=%.1f Mbps  down_lat=%.1f ms  client_retrans=%.0f\n",
			c, n[c], drops[c]/n[c], down[c]/n[c], dl[c]/n[c], rt[c]/n[c]
	# median, so one run disturbed by other traffic cannot hide a non-bottlenecked test
	if (n[0]) { asort(d0); med0 = d0[int((n[0] + 1) / 2)] }
	if (n[0] && med0 < 50)
		print "WARNING: clamp-off runs barely dropped - CAKE is not the bottleneck, results are meaningless (lower LONG_SHAPE)"
	if (fl[1]) printf "clamp=1 totals: flagged=%d clamped=%d skip_noct=%d (%.0f%% of flagged) skip_collide=%d (%.0f%%)\n",
		fl[1], cl[1], noct[1], 100*noct[1]/fl[1], col[1], 100*col[1]/fl[1]
	else print "clamp=1: nothing flagged - the clamp never engaged"
}' "$OUT"
