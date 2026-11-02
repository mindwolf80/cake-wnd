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

## How it works

- Ingress-mode CAKE, on dequeue: a TCP packet whose sojourn exceeds `wnd_sojourn_us` flags
  its flow in a shared 1024-slot table keyed by the data-direction 5-tuple. On the WAN
  side both qdiscs see the same post-NAT addresses, so no NAT translation is needed.
- Egress-mode CAKE, on enqueue: an ACK whose flow is flagged gets its window lowered
  (never raised), checksum fixed incrementally. The clamp starts at 3/4 of the window the
  receiver was advertising and is cut by another 1/4 each CAKE `rtt` interval while the
  flow keeps flagging, down to `wnd_min_bytes`. When no slow packet has been seen for
  `wnd_hold_ms`, the flag expires and the clamp is raised by 1/4 per interval until it
  reaches the advertised window, so the sender does not burst back to full speed.
- Each table slot holds the full flow tuple. A flow whose slot is held by another live flow
  is not clamped (`wnd_skip_collide`); one flow's clamp is never applied to another.
- Window scale comes from conntrack (`seen[dir].td_scale`), used only when conntrack saw the
  ACK sender's SYN with a window-scale option. Flow-offloaded packets carry no conntrack
  entry, so the module looks it up in the conntrack table instead.
- Untouched: non-TCP (QUIC), IPv6 with extension headers, PPPoE, GSO ACKs, SYN/RST, flows
  conntrack picked up mid-stream.

## Parameters (`/sys/module/sch_cake/parameters/`)

| Name | Default | |
|---|---|---|
| `wnd_clamp` | `N` | master switch |
| `wnd_sojourn_us` | `5000` | ingress sojourn that flags a flow |
| `wnd_min_bytes` | `5792` | clamp floor (4 × 1448 MSS) |
| `wnd_hold_ms` | `200` | flag lifetime after the last slow packet |
| `wnd_flagged` | ro | ingress packets over the threshold |
| `wnd_cuts` | ro | clamp reductions |
| `wnd_raises` | ro | clamp release steps |
| `wnd_clamped` | ro | ACKs rewritten |
| `wnd_skip_noct` | ro | flagged ACKs skipped, scale unknown |
| `wnd_skip_other` | ro | flagged ACKs skipped, GSO / not writable |
| `wnd_skip_collide` | ro | flags dropped, slot held by another flow |

Writable values set through sysfs last until reboot. Values that persist live in
`/etc/modules.d/sched-cake` (shipped by this package as a conffile, kept on reinstall),
e.g. `sch_cake wnd_clamp=1 wnd_sojourn_us=5000 wnd_min_bytes=5792 wnd_hold_ms=200`.

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
apk add --allow-untrusted --force-overwrite /tmp/kmod-sched-cake-wnd-6.12.112-r1.apk
insmod sch_cake $(cut -d' ' -f2- /etc/modules.d/sched-cake)
/etc/init.d/sqm start
modinfo sch_cake | grep -E 'filename|vermagic|parm'
tc -s qdisc | grep -A2 cake
```

## Test

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

A sysupgrade puts stock CAKE back, and any new release (25.12.7, ...) changes the kernel
hash, so this package won't install. For every release: update the Target lines, the
SDK URL/hash in the workflow, re-take `sch_cake.c` with that release's patches, re-run CI.
