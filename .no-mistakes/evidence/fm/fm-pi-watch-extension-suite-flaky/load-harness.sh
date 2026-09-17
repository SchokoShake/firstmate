#!/usr/bin/env bash
# usage: load-harness.sh <label> <repo-root> <cpu> <spinners> <runs> <suite>
# Pins <spinners> busy loops and the suite to one CPU, runs the suite <runs> times.
set -u
label=$1 root=$2 cpu=$3 spinners=$4 runs=$5 suite=$6
unset FM_HOME
pids=()
for _ in $(seq "$spinners"); do
  taskset -c "$cpu" bash -c 'while :; do :; done' &
  pids+=($!)
done
trap 'kill "${pids[@]}" 2>/dev/null' EXIT
pass=0
printf '== %s: %s pinned to cpu %s with %s spinners, %s runs (%s, node %s)\n' \
  "$label" "$suite" "$cpu" "$spinners" "$runs" "$(git -C "$root" rev-parse --short HEAD 2>/dev/null || basename "$root")" "$(node --version)"
for i in $(seq "$runs"); do
  start=$(date +%s)
  out=$(cd "$root" && taskset -c "$cpu" bash "$suite" 2>&1); rc=$?
  dur=$(( $(date +%s) - start ))
  oks=$(printf '%s\n' "$out" | grep -c '^ok ')
  if [ "$rc" -eq 0 ]; then
    pass=$((pass + 1))
    printf 'run %s: PASS rc=0 ok=%s %ss\n' "$i" "$oks" "$dur"
  else
    printf 'run %s: FAIL rc=%s ok=%s %ss\n' "$i" "$rc" "$oks" "$dur"
    printf '%s\n' "$out" | grep -v '^ok ' | head -8 | sed 's/^/    /'
  fi
done
printf '== %s result: %s of %s passed\n' "$label" "$pass" "$runs"
