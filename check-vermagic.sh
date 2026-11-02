#!/bin/sh
# Fail unless the built kmod matches the router's kernel as recorded in README.md.
# usage: check-vermagic.sh <sdk-dir>
set -eu
sdk=$1
readme=$(dirname "$0")/README.md

want_pkg=$(sed -n 's/^- Kernel package: `\(kernel-[^`]*\)`.*/\1/p' "$readme")
want_vm=$(sed -n 's/^- Module vermagic: `\([^`]*\)`.*/\1/p' "$readme")
[ -n "$want_pkg" ] && [ -n "$want_vm" ] || { echo "README is missing kernel package / vermagic lines"; exit 1; }

apk=$(ls "$sdk"/bin/targets/*/*/packages/kmod-sched-cake-wnd-*.apk)
ko=$(find "$sdk"/build_dir -path '*/cake-wnd/.pkgdir/*' -name sch_cake.ko)

got_vm=$(strings "$ko" | sed -n 's/^vermagic=//p')
got_dep=$("$sdk"/staging_dir/host/bin/apk adbdump "$apk" | sed -n 's/^ *- \(kernel=.*\)/\1/p')
echo "module vermagic: $got_vm (want $want_vm)"
echo "apk depends:     $got_dep (want kernel=${want_pkg#kernel-})"

[ "$got_vm" = "$want_vm" ] || { echo "vermagic mismatch"; exit 1; }
[ "$got_dep" = "kernel=${want_pkg#kernel-}" ] || { echo "kernel package mismatch"; exit 1; }
echo OK
