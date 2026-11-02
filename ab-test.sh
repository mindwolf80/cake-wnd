#!/bin/bash
# Alternate wnd_clamp off/on under the same load and record per-run deltas.
# usage: ab-test.sh [pairs=6] [load=ookla|long|cubic|real] [ookla server id]
# Pairs run ABBA (off,on / on,off / ...) so drift hits both conditions evenly.
# Refuses to run over Wi-Fi: turns Wi-Fi off if needed (back on at exit) and checks
# that the test routes leave on a wired interface.
#   ookla: Ookla CLI, multi-stream, ~10-15 s per direction; first run's server is reused.
#   long:  60 s download over $STREAMS parallel streams (default 1), ping to 1.1.1.1 alongside.
#   cubic: 60 s iperf3 reverse test, $STREAMS streams, server forced to CUBIC (loss-based,
#          fills the buffer until CAKE drops); records the server's retransmits.
#   real:  60 s of real-world downloads at once: distro ISO, distro mirror, Akamai CDN,
#          Google CDN (one connection each), ping to 1.1.1.1 alongside.
#   long, cubic and real lower the ingress shaper to $LONG_SHAPE so the streams queue in CAKE.
set -euo pipefail
R=root@192.168.1.1
PAIRS=${1:-6}
LOAD=${2:-ookla}
SID=${3:-}
LONG_HOST=ash-speed.hetzner.com
LONG_URL=https://$LONG_HOST/10GB.bin
LONG_SHAPE=${LONG_SHAPE:-200Mbit}
STREAMS=${STREAMS:-1}
CUBIC_HOST=${CUBIC_HOST:-ash.speedtest.clouvider.net}
# Debian is pinned to one mirror so every run takes the same path
REAL_URLS=(
	https://releases.ubuntu.com/24.04/ubuntu-24.04.4-desktop-amd64.iso
	https://gemmei.ftp.acc.umu.se/debian-cd/current/amd64/iso-dvd/debian-13.7.0-amd64-DVD-1.iso
	https://us.download.nvidia.com/XFree86/Linux-x86_64/595.112.07/NVIDIA-Linux-x86_64-595.112.07.run
	https://dl.google.com/android/repository/sys-img/google_apis/x86_64-36_r07.zip
)
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
TEST_HOST=$LONG_HOST; [ "$LOAD" = cubic ] && TEST_HOST=$CUBIC_HOST; [ "$LOAD" = real ] && TEST_HOST=releases.ubuntu.com
TEST_IP=$(getent ahostsv4 $TEST_HOST | awk 'NR == 1 {print $1}')
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
if [ "$LOAD" != ookla ]; then
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

# prints: server down_mbps up_mbps idle_ms down_lat_ms up_lat_ms server_retrans
run_ookla() {
	python3 -Ic 'import json,sys
j=json.loads(sys.argv[1])
print(j["server"]["id"], round(j["download"]["bandwidth"]*8/1e6,1), round(j["upload"]["bandwidth"]*8/1e6,1),
      j["ping"]["latency"], j["download"]["latency"]["iqm"], j["upload"]["latency"]["iqm"], "-")' \
		"$(speedtest -f json ${SID:+-s $SID})"
}
# 60 s of parallel curls to "$@"; prints total Mbps and median ping during the load
download_60s() {
	local pf tf u
	pf=$(mktemp); tf=$(mktemp)
	ping -n -i 0.2 -w 62 1.1.1.1 > "$pf" &
	for u in "$@"; do
		{ curl -4 -sL -o /dev/null --max-time 60 -w '%{speed_download}\n' "$u" || true; } >> "$tf" &
	done
	wait
	echo "$(awk '{s += $1} END {printf "%.1f", s*8/1e6}' "$tf") $(ping_median "$pf")"
	rm -f "$pf" "$tf"
}
run_long() {
	local urls=() s
	for ((s = 0; s < STREAMS; s++)); do urls+=("$LONG_URL"); done
	set -- $(download_60s "${urls[@]}")
	echo "hetzner-ash-x$STREAMS $1 - - $2 - -"
}
run_real() {
	set -- $(download_60s "${REAL_URLS[@]}")
	echo "real-x${#REAL_URLS[@]} $1 - - $2 - -"
}
ping_median() { sed -n 's/.*time=\([0-9.]*\).*/\1/p' "$1" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }
run_cubic() {
	local pf js port pp res
	pf=$(mktemp)
	# public iperf3 servers take one client at a time; try the next port when busy
	for port in $(seq 5200 5209); do
		ping -n -i 0.2 -w 62 1.1.1.1 > "$pf" & pp=$!
		js=$(iperf3 -4 -c "$CUBIC_HOST" -p $port -R -P "$STREAMS" -t 60 -C cubic -J 2>/dev/null || true)
		kill $pp 2>/dev/null; wait $pp 2>/dev/null || true
		res=$(python3 -Ic 'import json,sys
try:
    e = json.loads(sys.argv[1])["end"]
    assert e["sender_tcp_congestion"] == "cubic"
    print(round(e["sum_received"]["bits_per_second"]/1e6, 1), e["sum_sent"]["retransmits"])
except Exception:
    pass' "$js")
		[ -n "$res" ] && break
	done
	[ -n "$res" ] || { echo "no $CUBIC_HOST port accepted a CUBIC test" >&2; rm -f "$pf"; return 1; }
	set -- $res
	echo "${CUBIC_HOST%%.*}:$port-cubic-x$STREAMS $1 - - $(ping_median "$pf") - $2"
	rm -f "$pf"
}

echo "time,iface,clamp,server,down_mbps,up_mbps,idle_ms,down_lat_ms,up_lat_ms,ifb_drops,eth1_drops,flagged,cuts,raises,clamped,skip_noct,skip_collide,client_retrans,server_retrans" > "$OUT"

for ((i = 0; i < PAIRS; i++)); do
	order="0 1"; ((i % 2)) && order="1 0"
	for clamp in $order; do
		ssh -o BatchMode=yes $R "echo $clamp > $P/wnd_clamp"
		read -ra a <<< "$(router_snap)"; r0=$(retrans)
		res=$(run_$LOAD)
		read -r sid down up idle dl ul srt <<< "$res"
		read -ra b <<< "$(router_snap)"; r1=$(retrans)
		[ "$LOAD" = ookla ] && SID=${SID:-$sid}

		d=""
		for k in 0 1 2 3 4 5 6 7; do d+=",$(( b[k] - a[k] ))"; done
		echo "$(date +%T),$(route_dev 1.1.1.1),$clamp,$sid,$down,$up,$idle,$dl,$ul$d,$(( r1 - r0 )),$srt" | tee -a "$OUT"
	done
done

echo
echo "results: $OUT"
awk -F, 'NR > 1 {
	c = $3; n[c]++; drops[c] += $10; if (!c) d0[n[c]] = $10; down[c] += $5; dl[c] += $8; rt[c] += $18
	fl[c] += $12; cl[c] += $15; noct[c] += $16; col[c] += $17
	if ($19 != "-" && $19 != "") { srn[c]++; sr[c] += $19 } }
END {
	for (c = 0; c <= 1; c++) if (n[c])
		printf "clamp=%d  runs=%d  mean ifb_drops=%.0f  down=%.1f Mbps  down_lat=%.1f ms  client_retrans=%.0f\n",
			c, n[c], drops[c]/n[c], down[c]/n[c], dl[c]/n[c], rt[c]/n[c]
	for (c = 0; c <= 1; c++) if (srn[c])
		printf "clamp=%d  mean server_retrans=%.0f\n", c, sr[c]/srn[c]
	# every clamp-off run must build a standing queue in CAKE, or that run says nothing
	low = 0; for (i = 1; i <= n[0]; i++) low += d0[i] < 100
	if (low)
		printf "WARNING: %d of %d clamp-off runs had <100 IFB drops - CAKE was not the bottleneck in those runs\n", low, n[0]
	if (fl[1]) printf "clamp=1 totals: flagged=%d clamped=%d skip_noct=%d (%.0f%% of flagged) skip_collide=%d (%.0f%%)\n",
		fl[1], cl[1], noct[1], 100*noct[1]/fl[1], col[1], 100*col[1]/fl[1]
	else print "clamp=1: nothing flagged - the clamp never engaged"
}' "$OUT"
