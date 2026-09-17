#!/usr/bin/env bash
# usage: shard-order-harness.sh <label> <repo-root> <cpu-list> <rounds>
# Reproduces the CI shard-4 neighbourhood: fm-startup-network.test.sh, then
# fm-pi-watch-extension.test.sh straight after it, all pinned to 4 CPUs.
set -u
label=$1 root=$2 cpus=$3 rounds=$4
unset FM_HOME
export TMPDIR; TMPDIR=$(mktemp -d /tmp/fm-shard-order.XXXXXX)
leftover() { pgrep -f "$TMPDIR/fm-startup-network-tests\." | wc -l; }
pass=0
printf '== %s: startup-network -> pi-watch-extension, pinned to cpus %s, %s rounds\n' "$label" "$cpus" "$rounds"
for i in $(seq "$rounds"); do
  (cd "$root" && taskset -c "$cpus" bash tests/fm-startup-network.test.sh >/dev/null 2>&1); rc1=$?
  left_before=$(leftover)
  start=$(date +%s)
  out=$(cd "$root" && taskset -c "$cpus" bash tests/fm-pi-watch-extension.test.sh 2>&1); rc2=$?
  dur=$(( $(date +%s) - start ))
  left_after=$(leftover)
  [ "$rc2" -eq 0 ] && pass=$((pass + 1))
  printf 'round %s: startup-network rc=%s | workers left when Pi suite starts=%s, when it ends=%s | Pi suite rc=%s ok=%s %ss\n' \
    "$i" "$rc1" "$left_before" "$left_after" "$rc2" "$(printf '%s\n' "$out" | grep -c '^ok ')" "$dur"
  [ "$rc2" -eq 0 ] || printf '%s\n' "$out" | grep -v '^ok ' | head -4 | sed 's/^/    /'
  pkill -KILL -f "$TMPDIR/fm-startup-network-tests\." 2>/dev/null
done
printf '== %s result: Pi suite passed %s of %s rounds\n' "$label" "$pass" "$rounds"
rm -rf "$TMPDIR"
