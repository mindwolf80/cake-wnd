# cake-wnd

Drop-in `sch_cake.ko` for OpenWrt on the GL.iNet Flint 2 (GL-MT6000). When a TCP flow's
packets start queueing in the ingress CAKE, the egress CAKE lowers the receive window
advertised in that flow's ACKs, so the sender slows down before CAKE has to drop.
With `wnd_clamp=0` (the default) it behaves exactly like stock CAKE.

## Target (read from the router, 2026-11-02)

`check-vermagic.sh` parses the two backticked values below; CI fails if the build differs.

- Release: OpenWrt 25.12.6 r33311-981c978eff, `mediatek/filogic`, `aarch64_cortex-a53`
- Kernel: 6.12.112
- Kernel package: `kernel-6.12.112~f0a7348f9cb959e1bf4d0447669b031e-r1`
- Module vermagic: `6.12.112 SMP mod_unload aarch64`
- Package manager: apk
- SQM: egress `cake` on `eth1` (nat dual-srchost), ingress `cake` on `ifb4eth1` (nat dual-dsthost ingress), software flow offloading on

After any firmware upgrade, re-read these, update the lines above, `SDK_URL`/`SDK_SHA256`
in the workflow, and re-take `sch_cake.c` (below).

## Source

`package/cake-wnd/src/sch_cake.c` is `net/sched/sch_cake.c` from Linux v6.12.112 plus the
`sch_cake.c` hunks of OpenWrt v25.12.6 `target/linux/generic/backport-6.12/700-0{2,3,4,5,7}-*`
and `701-0{1,2}-*` (the cake_mq backports), i.e. the stock module. The window-clamp code is
everything under `cake_wnd_*` / `wnd_*` plus two hooks (`cake_enqueue`, `cake_dequeue`).

On top of that base (`bbbe44a`), the following upstream `sch_cake` fixes not yet in the
backport set above are carried by hand and should be re-applied (or re-checked against the
new upstream state) on the next re-take: net-next `d23a16d907dc` ("net/sched/sch_cake:
serialize reconfiguration with the datapath", commits config and reconfigures under
`sch_tree_lock`, `READ_ONCE`/`WRITE_ONCE` on `rate_bps`); net-next `d7010be1ba23` ("reduce
parent backlog when clearing a tin") plus its prerequisite `a3729e0df005` ("skip clearing
unused tins during rate adjustment"); net-next `7cbfb180945c` ("fix autorate reconfiguration
throttling", sets `last_reconfig_time`); and Yuchao Zhang's `[PATCH net v4 1/2 + 2/2]` (cake
list, 2026-09-28) making `cake_overhead()` fall back to plain overhead when the transport
header is unset, the offset is negative, or `segs <= 1`, instead of charging the shaper
~4 GB / ~66 KB per segment.

## How it works

- Ingress-mode CAKE, on dequeue: when COBALT drops (or CE-marks) a TCP packet, it flags
  that flow in a shared 1024-slot table keyed by the data-direction 5-tuple. On the WAN
  side both qdiscs see the same post-NAT addresses, so no NAT translation is needed.
- Egress-mode CAKE, on enqueue: an ACK whose flow is flagged gets its window lowered
  (never raised), checksum fixed incrementally. The clamp starts at 3/4 of the window the
  receiver was advertising and is cut by another 1/4 each CAKE `rtt` interval while the
  flow keeps flagging, down to `wnd_min_bytes`. When no slow packet has been seen for
  `wnd_hold_ms`, the flag expires and the clamp is raised by 1/4 per interval until it
  reaches the advertised window, so the sender does not burst back to full speed.
- So the clamp never prevents the first drop. It turns that drop into a window cut, so
  CAKE needs fewer drops afterwards. (A sojourn-based trigger fired on transient bursts and
  cost ~37% throughput with no standing queue; see `results/`.)
- Each table slot holds the full flow tuple. A flow whose slot is held by another live flow
  is not clamped (`wnd_skip_collide`); one flow's clamp is never applied to another.
- Window scale comes from conntrack (`seen[dir].td_scale`), used only when conntrack saw the
  ACK sender's SYN with a window-scale option. Flow-offloaded packets carry no conntrack
  entry, so the module looks it up in the conntrack table instead.
- Untouched: non-TCP (QUIC), IPv6 with extension headers, PPPoE, GSO ACKs, SYN/RST, flows
  conntrack picked up mid-stream.

## When it helps

What the clamp measurably changes: when long TCP downloads fill the ingress shaper, CAKE drops
far fewer packets (-87% at 60Mbit, `results/ab-real-*`) at the same throughput and latency.
So it matters where long TCP downloads regularly saturate the link:

- Game downloads and updates (Steam, Xbox, PlayStation, Battle.net): hour-long TCP downloads.
- OS updates (Windows Update, macOS) on several devices at once.
- TCP video streaming (Netflix, Disney+, Prime) while someone else downloads.
- Modest links (50-100Mbit cable/DSL) shared by a household: the shaper is often full, so
  there is more to save than on a fast, rarely-saturated link.
- Cloud backup restores and large sync downloads (OneDrive, Google Drive, iCloud, Backblaze).
- Shared houses / student flats: many concurrent downloads, link always at its limit.

No effect on: QUIC (YouTube, most Google services), UDP games and voice/video calls, web
browsing (flows end before CAKE drops), uploads, or links that rarely saturate. Only tested on
the target below; other link types (DSL, PPPoE, IPv6-heavy) are untested.

## Parameters (`/sys/module/sch_cake/parameters/`)

| Name | Default | |
|---|---|---|
| `wnd_clamp` | `N` | master switch |
| `wnd_min_bytes` | `5792` | clamp floor (4 × 1448 MSS) |
| `wnd_hold_ms` | `200` | flag lifetime after the last slow packet |
| `wnd_flagged` | ro | ingress COBALT drops/marks of TCP packets (flag events) |
| `wnd_cuts` | ro | clamp reductions |
| `wnd_raises` | ro | clamp release steps |
| `wnd_clamped` | ro | ACKs rewritten |
| `wnd_skip_noct` | ro | flagged ACKs skipped, scale unknown |
| `wnd_skip_other` | ro | flagged ACKs skipped, GSO / not writable |
| `wnd_skip_collide` | ro | flags dropped, slot held by another flow |

Writable values set through sysfs last until reboot. Values that persist live in
`/etc/modules.d/sched-cake` (shipped by this package as a conffile, kept on reinstall),
e.g. `sch_cake wnd_clamp=1 wnd_min_bytes=5792 wnd_hold_ms=200`.

## Build

Push or run the `build` workflow manually. It downloads the exact 25.12.6 SDK (sha256-checked),
builds only this package, checks vermagic against this README, and uploads
`kmod-sched-cake-wnd-6.12.112-r1.apk` as the `kmod-sched-cake-wnd` artifact.

## Install

The package overwrites `sch_cake.ko` and `/etc/modules.d/sched-cake` and leaves
`kmod-sched-cake` installed, because `sqm-scripts` depends on it. `sch_cake` can't be
unloaded while CAKE qdiscs exist, so SQM is stopped first.

```sh
scp -O kmod-sched-cake-wnd-6.12.112-r1.apk root@192.168.1.1:/tmp/
ssh root@192.168.1.1
/etc/init.d/sqm stop
rmmod sch_cake
apk add --allow-untrusted --force-overwrite /tmp/kmod-sched-cake-wnd-6.12.112-r1.apk  # post-install loads it via /etc/modules.d
lsmod | grep -q sch_cake || insmod sch_cake $(cut -d' ' -f2- /etc/modules.d/sched-cake)
/etc/init.d/sqm start
modinfo sch_cake | grep -E 'filename|vermagic|parm'
tc -s qdisc | grep -A2 cake
```

## Test

Keep `wnd_clamp=0` in `/etc/modules.d/sched-cake` and turn the clamp on only through sysfs
until it has survived real load. If the clamp code crashes the kernel, the reboot then comes
back with the clamp off. (Removing the autoload line wouldn't help: SQM's `tc qdisc add ... cake`
makes the kernel load `sch_cake` on its own.)

1. Toggle off: run the same bufferbloat tests as the existing baseline; results must match stock.
2. Toggle on: `echo 1 > /sys/module/sch_cake/parameters/wnd_clamp`, repeat the tests and compare
   latency under load, retransmits (`ss -ti` on the client) and throughput.
3. Check counters: `grep . /sys/module/sch_cake/parameters/wnd_*`.
   A high `wnd_skip_noct` means conntrack is missing the handshakes.
4. Watch retransmits per sender. Each cut moves the window's right edge backward
   (window shrinking, which RFC 9293 discourages). Linux and Windows senders cope; a
   sender whose retransmits jump only with the clamp on is one that doesn't.

## Rollback

```sh
echo 0 > /sys/module/sch_cake/parameters/wnd_clamp      # instant, no reload
# full removal:
/etc/init.d/sqm stop
rmmod sch_cake
apk del kmod-sched-cake-wnd
apk update && apk fix --reinstall kmod-sched-cake
insmod sch_cake
/etc/init.d/sqm start
```

## Upgrades

Stock `kmod-sched-cake` also owns `/etc/modules.d/sched-cake`: any upgrade or reinstall of it
silently replaces the parameter line (and `sch_cake.ko`). After any package update, check
`cat /etc/modules.d/sched-cake` and `modinfo sch_cake | grep parm` first.

A sysupgrade puts stock CAKE back, and any new release (25.12.7, ...) changes the kernel
hash, so this package won't install. For every release: update the Target lines, the
SDK URL/hash in the workflow, re-take `sch_cake.c` with that release's patches, re-run CI.
