#!/bin/bash
# Alternate wnd_clamp off/on back to back under the same load and record per-run deltas.
# usage: ab-test.sh [rounds=2] [ookla server id]   (rounds=2 -> off,on,off,on)
# Load is the Ookla CLI pinned to one server; the first run's server is reused if none given.
set -euo pipefail
R=root@192.168.1.1
ROUNDS=${1:-2}
SID=${2:-}
OUT=ab-$(date +%F-%H%M).csv
P=/sys/module/sch_cake/parameters

ssh -o BatchMode=yes $R "[ -w $P/wnd_clamp ]" || { echo "cake-wnd module not loaded"; exit 1; }
trap 'ssh -o BatchMode=yes $R "echo 0 > $P/wnd_clamp" && echo "wnd_clamp reset to 0"' EXIT

# ifb_drops eth1_drops flagged cuts raises clamped skip_noct skip_collide
router_snap() {
	ssh -o BatchMode=yes $R "
		for d in ifb4eth1 eth1; do tc -s qdisc show dev \$d | sed -n 's/.*(dropped \([0-9]*\),.*/\1/p' | head -1; done
		cat $P/wnd_flagged $P/wnd_cuts $P/wnd_raises $P/wnd_clamped $P/wnd_skip_noct $P/wnd_skip_collide" | tr '\n' ' '
}
retrans() { nstat -asz TcpRetransSegs | awk '/TcpRetransSegs/{print $2}'; }

echo "time,clamp,server,down_mbps,up_mbps,idle_ms,down_lat_iqm_ms,up_lat_iqm_ms,ifb_drops,eth1_drops,flagged,cuts,raises,clamped,skip_noct,skip_collide,client_retrans" > "$OUT"

for ((i = 0; i < ROUNDS; i++)); do
	for clamp in 0 1; do
		ssh -o BatchMode=yes $R "echo $clamp > $P/wnd_clamp"
		read -ra a <<< "$(router_snap)"; r0=$(retrans)
		json=$(speedtest -f json ${SID:+-s $SID})
		read -ra b <<< "$(router_snap)"; r1=$(retrans)

		line=$(python3 -Ic 'import json,sys
j=json.loads(sys.argv[1])
print(j["server"]["id"], round(j["download"]["bandwidth"]*8/1e6,1), round(j["upload"]["bandwidth"]*8/1e6,1),
      j["ping"]["latency"], j["download"]["latency"]["iqm"], j["upload"]["latency"]["iqm"])' "$json")
		read -r sid down up idle dl ul <<< "$line"
		SID=${SID:-$sid}

		d=""
		for k in 0 1 2 3 4 5 6 7; do d+=",$(( b[k] - a[k] ))"; done
		echo "$(date +%T),$clamp,$sid,$down,$up,$idle,$dl,$ul$d,$(( r1 - r0 ))" | tee -a "$OUT"
	done
done
echo "results: $OUT"
