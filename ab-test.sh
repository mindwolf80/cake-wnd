#!/bin/bash
# Alternate wnd_clamp off/on under the same load and record per-run deltas.
# usage: ab-test.sh [pairs=6] [load=ookla|long] [ookla server id]
# Pairs run ABBA (off,on / on,off / ...) so drift hits both conditions evenly.
#   ookla: Ookla CLI, multi-stream, ~10-15 s per direction; first run's server is reused.
#   long:  one 60 s single-stream download, ping to 1.1.1.1 alongside for loaded latency.
#          The ingress shaper is lowered to $LONG_SHAPE so the stream queues in CAKE.
set -euo pipefail
R=root@192.168.1.1
PAIRS=${1:-6}
LOAD=${2:-ookla}
SID=${3:-}
LONG_URL=https://ash-speed.hetzner.com/10GB.bin
LONG_SHAPE=${LONG_SHAPE:-200Mbit}
IFB=ifb4eth1
OUT=ab-$LOAD-$(date +%F-%H%M).csv
P=/sys/module/sch_cake/parameters

ssh -o BatchMode=yes $R "[ -w $P/wnd_clamp ]" || { echo "cake-wnd module not loaded"; exit 1; }
SHAPE0=$(ssh -o BatchMode=yes $R "tc qdisc show dev $IFB" | sed -n 's/.* bandwidth \([0-9]*[KMG]*bit\).*/\1/p')
[ -n "$SHAPE0" ] || { echo "no cake bandwidth on $IFB"; exit 1; }
restore() {
	ssh -o BatchMode=yes $R "echo 0 > $P/wnd_clamp; tc qdisc change dev $IFB root cake bandwidth $SHAPE0" &&
		echo "wnd_clamp reset to 0, $IFB bandwidth restored to $SHAPE0"
}
trap restore EXIT
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
	bps=$(curl -s -o /dev/null --max-time 60 -w '%{speed_download}' "$LONG_URL" || true)
	wait
	# loaded latency = median of pings taken during the download
	echo "hetzner-ash $(awk -v b="$bps" 'BEGIN{printf "%.1f", b*8/1e6}') - -" \
		"$(sed -n 's/.*time=\([0-9.]*\).*/\1/p' "$pf" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')" -
	rm -f "$pf"
}

echo "time,clamp,server,down_mbps,up_mbps,idle_ms,down_lat_ms,up_lat_ms,ifb_drops,eth1_drops,flagged,cuts,raises,clamped,skip_noct,skip_collide,client_retrans" > "$OUT"

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
		echo "$(date +%T),$clamp,$sid,$down,$up,$idle,$dl,$ul$d,$(( r1 - r0 ))" | tee -a "$OUT"
	done
done

echo
echo "results: $OUT"
awk -F, 'NR > 1 {
	c = $2; n[c]++; drops[c] += $9; down[c] += $4; dl[c] += $7; rt[c] += $17
	fl[c] += $11; cl[c] += $14; noct[c] += $15; col[c] += $16 }
END {
	for (c = 0; c <= 1; c++) if (n[c])
		printf "clamp=%d  runs=%d  mean ifb_drops=%.0f  down=%.1f Mbps  down_lat=%.1f ms  client_retrans=%.0f\n",
			c, n[c], drops[c]/n[c], down[c]/n[c], dl[c]/n[c], rt[c]/n[c]
	if (n[0] && drops[0]/n[0] < 10)
		print "WARNING: clamp-off runs barely dropped - CAKE is not the bottleneck, results are meaningless (lower LONG_SHAPE)"
	if (fl[1]) printf "clamp=1 totals: flagged=%d clamped=%d skip_noct=%d (%.0f%% of flagged) skip_collide=%d (%.0f%%)\n",
		fl[1], cl[1], noct[1], 100*noct[1]/fl[1], col[1], 100*col[1]/fl[1]
	else print "clamp=1: nothing flagged - the clamp never engaged"
}' "$OUT"
