#!/usr/bin/env bash
# Reproduction / verification harness for the reported defect:
#
#   "three finished PRs parked awaiting the captain's own merge each declared
#    paused: correctly, and the watcher kept emitting stale: firstmate:fm-<task>"
#
# Nothing here asserts on source bytes. It builds a fleet fixture, then drives
# the REAL bin/fm-crew-state.sh and the REAL bin/fm-watch.sh over repeated
# supervision rounds against a fake tmux backend and a fake `no-mistakes` CLI,
# and reports what a captain actually receives: the durable wake queue.
#
# usage: parked-pr-scenario.sh <fm-root> <workdir> <label>
set -u
ROOT=$1; WORK=$2; LABEL=$3
STATE_ROOT="$WORK/$LABEL"
rm -rf "$STATE_ROOT"; mkdir -p "$STATE_ROOT"
TANGLE="$WORK/tangle-$LABEL"; mkdir -p "$TANGLE"
ROUNDS=${ROUNDS:-4}
SESSION=firstmate

# --- fake backend + fake no-mistakes CLI ------------------------------------
mk_fakebin() {  # <fixture-dir>
  local d=$1
  mkdir -p "$d/fakebin" "$d/panes" "$d/cmd" "$d/nm"
  cat > "$d/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
FX=${FM_FIXTURE:?}
sub=${1:-}; shift || true
target=""; fmt=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -t) target=${2:-}; shift 2; continue ;;
    -F) fmt=${2:-}; shift 2; continue ;;
    '#{'*) fmt=$1; shift; continue ;;
  esac
  shift
done
win=${target#*:}
case "$sub" in
  list-windows)
    # -t names a SESSION here; list every window this fixture recorded for it.
    for f in "$FX"/panes/*.txt; do
      [ -e "$f" ] || continue
      b=${f##*/}; printf '%s\n' "${b%.txt}"
    done
    exit 0 ;;
  capture-pane)
    [ -f "$FX/panes/$win.txt" ] || exit 1
    cat "$FX/panes/$win.txt"; exit 0 ;;
  display-message)
    case "$fmt" in
      *pane_current_command*) cat "$FX/cmd/$win" 2>/dev/null || printf '\n'; exit 0 ;;
      *pane_tty*)             printf '/dev/nonexistent-%s\n' "$win"; exit 0 ;;
      *pane_id*)              printf '%%1\n'; exit 0 ;;
      *cursor_y*)             printf '0\n'; exit 0 ;;
    esac
    printf 'fakepane\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$d/fakebin/tmux"
  # Fake `no-mistakes` CLI: answers `axi status` / `axi logs` from files the
  # fixture drops into nm/<branch>.{status,cilog}, keyed on the worktree branch
  # the caller cd'd into. A crew whose branch has no file gets no run at all.
  cat > "$d/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
FX=${FM_FIXTURE:?}
br=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 1
[ -n "$br" ] && [ "$br" != HEAD ] || exit 1
case "${1:-} ${2:-}" in
  "axi status") [ -f "$FX/nm/$br.status" ] || exit 1; cat "$FX/nm/$br.status"; exit 0 ;;
  "axi logs")   [ -f "$FX/nm/$br.cilog" ]  || exit 1; cat "$FX/nm/$br.cilog";  exit 0 ;;
  "runs "*|"runs") exit 1 ;;
esac
exit 1
SH
  chmod +x "$d/fakebin/no-mistakes"
}

# A real git worktree so fm-crew-state.sh can resolve a branch + code identity.
mk_worktree() {  # <dir> <branch>
  local wt=$1 br=$2
  mkdir -p "$wt"
  git -C "$wt" init -q -b "$br" 2>/dev/null
  git -C "$wt" -c user.email=fixture@example.invalid -c user.name=fixture \
    commit -q --allow-empty -m "parked work" 2>/dev/null
  git -C "$wt" rev-parse HEAD
}

# --- one crew fixture -------------------------------------------------------
# mk_crew <name> <task> <status-lines-file-content> <pane-text> <pane-command>
mk_crew() {  # <fixture> <task> <harness-cmd>
  local fx=$1 task=$2 cmd=$3
  mkdir -p "$fx/state"
  printf '%s\n' "$cmd" > "$fx/cmd/fm-$task"
  printf 'idle at the prompt\n' > "$fx/panes/fm-$task.txt"
  printf 'window=%s:fm-%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$SESSION" "$task" > "$fx/state/$task.meta"
}

seen_sig() {  # <state> <file>
  FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    sig=$(fm_wake_signal_sig "$3") || exit 1
    printf "%s" "$sig" > "$(fm_wake_signal_seen_path "$2" "$3")"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

drain_ack() {  # <state>
  local state=$1 err sequence generation
  err="$state/.drain.err"
  FM_ROOT_OVERRIDE="$TANGLE" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$err" || true
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 0
  FM_ROOT_OVERRIDE="$TANGLE" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" \
    --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1 || true
}

stale_wakes_for() {  # <state> <window>
  awk -F '\t' -v w="$2" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}
all_wakes_for() {  # <state> <window>
  awk -F '\t' -v w="$2" '$4 == w { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

run_watcher() {  # <fixture> <state> <extra env...>; leaves WATCH_EXITED / WATCH_OUT
  local fx=$1 state=$2; shift 2
  local out="$fx/watch.out" pid i=0
  env FM_FIXTURE="$fx" PATH="$fx/fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$@" "$ROOT/bin/fm-watch.sh" >> "$out" 2>&1 &
  pid=$!
  WATCH_EXITED=no
  while [ "$i" -lt 60 ]; do
    kill -0 "$pid" 2>/dev/null || { WATCH_EXITED=yes; break; }
    sleep 0.1; i=$((i + 1))
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  WATCH_OUT="$out"
}

hr() { printf '%s\n' "------------------------------------------------------------------------"; }

printf '========================================================================\n'
printf 'firstmate watcher - declared external wait vs stale-pane wedge escalation\n'
printf 'source tree under test: %s\n' "$LABEL"
printf '========================================================================\n\n'

# ---------------------------------------------------------------------------
# Part 1 - the reported trigger: three finished PRs parked awaiting the
# captain's own merge, each having correctly declared `paused:`.
# ---------------------------------------------------------------------------
declare -a PARKED=(alpha beta gamma)
declare -A PR=([alpha]=41 [beta]=42 [gamma]=43)

for task in "${PARKED[@]}"; do
  fx="$STATE_ROOT/$task"; mkdir -p "$fx/state"
  mk_fakebin "$fx"
  mk_crew "$fx" "$task" grok
  if [ "$task" = gamma ]; then
    # This one's PR is up and green, so its own no-mistakes run is what
    # fm-crew-state.sh reads - the run outranks the log.
    head=$(mk_worktree "$fx/wt" "fm/fm-gamma")
    printf 'window=%s:fm-%s\nkind=ship\nharness=grok\nbackend=tmux\nworktree=%s\n' \
      "$SESSION" "$task" "$fx/wt" > "$fx/state/$task.meta"
    mkdir -p "$fx/nm/fm"
    printf 'id: run-43\nbranch: fm/fm-gamma\nhead: %s\nstatus: ci\noutcome: checks-passed\n' \
      "$head" > "$fx/nm/fm/fm-gamma.status"
  else
    mkdir -p "$fx/wt"
    printf 'window=%s:fm-%s\nkind=ship\nharness=grok\nbackend=tmux\nworktree=%s\n' \
      "$SESSION" "$task" "$fx/wt" > "$fx/state/$task.meta"
  fi
  printf 'done: PR https://example.invalid/pull/%s checks green\npaused: awaiting the captain merge on PR %s\n' \
    "${PR[$task]}" "${PR[$task]}" > "$fx/state/$task.status"
  seen_sig "$fx/state" "$fx/state/$task.status"
done

printf 'REPRODUCE STEP 1 - what the authoritative reader says about each parked crew\n'
printf '  (real bin/fm-crew-state.sh, real bin/fm-classify-lib.sh)\n\n'
for task in "${PARKED[@]}"; do
  fx="$STATE_ROOT/$task"
  printf '  $ bin/fm-crew-state.sh %s\n' "$task"
  printf '    last status line : %s\n' "$(tail -1 "$fx/state/$task.status")"
  printf '    verdict          : %s\n' \
    "$(FM_FIXTURE="$fx" PATH="$fx/fakebin:$PATH" FM_STATE_OVERRIDE="$fx/state" \
        bash "$ROOT/bin/fm-crew-state.sh" "$task")"
  printf '\n'
done
hr

printf '\nREPRODUCE STEP 2 - %s supervision rounds per crew. The crew is idle at its\n' "$ROUNDS"
printf 'prompt with a live agent; its harness footer redraws between rounds, so each\n'
printf 'round presents the watcher a FRESH stale pane hash. Each round is armed,\n'
printf 'drained and acknowledged exactly as a supervision turn does.\n\n'

declare -A TOTAL
for task in "${PARKED[@]}"; do
  fx="$STATE_ROOT/$task"; win="$SESSION:fm-$task"
  printf '  crew fm-%s (PR %s)\n' "$task" "${PR[$task]}"
  r=1
  while [ "$r" -le "$ROUNDS" ]; do
    printf 'idle at the prompt, awaiting captain merge on PR %s (ctx %s%%)\n' \
      "${PR[$task]}" "$((99 - r))" > "$fx/panes/fm-$task.txt"
    before=$(stale_wakes_for "$fx/state" "$win")
    run_watcher "$fx" "$fx/state" FM_PAUSE_RESURFACE_SECS=999999 FM_STALE_ESCALATE_SECS=240
    after=$(stale_wakes_for "$fx/state" "$win")
    TOTAL[$task]=$(( ${TOTAL[$task]:-0} + after - before ))
    if [ "$after" -gt "$before" ]; then
      printf '    round %s: WOKE THE CAPTAIN -> %s\n' "$r" \
        "$(awk -F '\t' -v w="$win" '$3=="stale" && $4==w { last=$5 } END { print last }' "$fx/state/.wake-queue")"
    else
      printf '    round %s: absorbed (watcher still armed, no wake, no wedge timer)\n' "$r"
    fi
    drain_ack "$fx/state"
    r=$((r + 1))
  done
  printf '    => %s stale wake(s) over %s rounds; pause cadence marker: %s; wedge timer: %s\n\n' \
    "${TOTAL[$task]:-0}" "$ROUNDS" \
    "$([ -e "$fx/state/.paused-${SESSION}_fm-$task" ] && echo present || echo absent)" \
    "$([ -e "$fx/state/.stale-since-${SESSION}_fm-$task" ] && echo running || echo none)"
done
hr

# ---------------------------------------------------------------------------
# Part 2 - the other direction. Absorbing a declared wait must not blind the
# watcher to a real failure, and must not silence the crew forever.
# ---------------------------------------------------------------------------
printf '\nCOUNTER-CASES - what STILL reaches the captain under the same declared wait\n\n'

# (a) The wait turned into a real blocker: a later status line.
fx="$STATE_ROOT/delta"; mkdir -p "$fx/state"; mk_fakebin "$fx"; mkdir -p "$fx/wt"
mk_crew "$fx" delta grok
printf 'window=%s:fm-delta\nkind=ship\nharness=grok\nbackend=tmux\nworktree=%s\n' "$SESSION" "$fx/wt" > "$fx/state/delta.meta"
printf 'paused: awaiting the captain merge on PR 44\nblocked: the merge needs a branch-protection override I cannot grant\n' > "$fx/state/delta.status"
seen_sig "$fx/state" "$fx/state/delta.status"
printf 'idle after the merge turned into a blocker\n' > "$fx/panes/fm-delta.txt"
printf '  (a) the crew later appended `blocked:` under the same declared wait\n'
printf '      verdict   : %s\n' "$(FM_FIXTURE="$fx" PATH="$fx/fakebin:$PATH" FM_STATE_OVERRIDE="$fx/state" bash "$ROOT/bin/fm-crew-state.sh" delta)"
run_watcher "$fx" "$fx/state" FM_PAUSE_RESURFACE_SECS=999999 FM_STALE_ESCALATE_SECS=240
printf '      watcher   : %s (exited=%s)\n' \
  "$(awk -F '\t' -v w="$SESSION:fm-delta" '$4==w { last=$5 } END { print (last == "" ? "NO WAKE" : last) }' "$fx/state/.wake-queue" 2>/dev/null)" "$WATCH_EXITED"
printf '      pause cadence marker: %s\n\n' \
  "$([ -e "$fx/state/.paused-${SESSION}_fm-delta" ] && echo 'present (WRONG)' || echo 'absent - never took the pause cadence')"

# (b) The crew resumed real work under the same declared pause, then froze.
fx="$STATE_ROOT/epsilon"; mkdir -p "$fx/state"; mk_fakebin "$fx"
head=$(mk_worktree "$fx/wt" "fm/fm-epsilon")
mk_crew "$fx" epsilon grok
printf 'window=%s:fm-epsilon\nkind=ship\nharness=grok\nbackend=tmux\nworktree=%s\n' "$SESSION" "$fx/wt" > "$fx/state/epsilon.meta"
mkdir -p "$fx/nm/fm"
printf 'id: run-45\nbranch: fm/fm-epsilon\nhead: %s\nstatus: ci\n' "$head" > "$fx/nm/fm/fm-epsilon.status"
printf 'CI checks running\n' > "$fx/nm/fm/fm-epsilon.cilog"
printf 'paused: awaiting the captain merge on PR 45\n' > "$fx/state/epsilon.status"
seen_sig "$fx/state" "$fx/state/epsilon.status"
printf 'a static pane while the pipeline runs CI\n' > "$fx/panes/fm-epsilon.txt"
printf '  (b) the crew RESUMED work under the same declared pause (an actively\n'
printf '      running no-mistakes CI step - the second absorb signal)\n'
printf '      verdict   : %s\n' "$(FM_FIXTURE="$fx" PATH="$fx/fakebin:$PATH" FM_STATE_OVERRIDE="$fx/state" bash "$ROOT/bin/fm-crew-state.sh" epsilon)"
run_watcher "$fx" "$fx/state" FM_PAUSE_RESURFACE_SECS=999999 FM_STALE_ESCALATE_SECS=240
printf '      first sighting: absorbed=%s, wedge timer %s, pause cadence %s\n' \
  "$([ "$WATCH_EXITED" = no ] && echo yes || echo no)" \
  "$([ -e "$fx/state/.stale-since-${SESSION}_fm-epsilon" ] && echo started || echo 'NOT started')" \
  "$([ -e "$fx/state/.paused-${SESSION}_fm-epsilon" ] && echo 'taken (WRONG)' || echo 'not taken')"
drain_ack "$fx/state"
printf '%s\n' "$(( $(date +%s) - 500 ))" > "$fx/state/.stale-since-${SESSION}_fm-epsilon"
run_watcher "$fx" "$fx/state" FM_PAUSE_RESURFACE_SECS=999999 FM_STALE_ESCALATE_SECS=240
printf '      once that run froze past FM_STALE_ESCALATE_SECS:\n        %s\n\n' \
  "$(awk -F '\t' -v w="$SESSION:fm-epsilon" '$4==w { last=$5 } END { print (last == "" ? "NO WAKE (WRONG)" : last) }' "$fx/state/.wake-queue" 2>/dev/null)"

# (c) The declared wait's own verdict is gone while the agent is still alive.
fx="$STATE_ROOT/zeta"; mkdir -p "$fx/state"; mk_fakebin "$fx"; mkdir -p "$fx/wt"
mk_crew "$fx" zeta claude
printf 'window=%s:fm-zeta\nkind=ship\nharness=claude\nbackend=tmux\nworktree=%s\n' "$SESSION" "$fx/wt" > "$fx/state/zeta.meta"
printf 'paused: awaiting the captain merge on PR 46\n' > "$fx/state/zeta.status"
seen_sig "$fx/state" "$fx/state/zeta.status"
printf 'a bare prompt where the declared wait can no longer be read\n' > "$fx/panes/fm-zeta.txt"
printf '  (c) the declared wait no longer reads as absorbing, agent still alive\n'
printf '      verdict   : %s\n' "$(FM_FIXTURE="$fx" PATH="$fx/fakebin:$PATH" FM_STATE_OVERRIDE="$fx/state" bash "$ROOT/bin/fm-crew-state.sh" zeta)"
run_watcher "$fx" "$fx/state" FM_PAUSE_RESURFACE_SECS=999999 FM_STALE_ESCALATE_SECS=240
printf '      watcher   : %s (exited=%s)\n\n' \
  "$(awk -F '\t' -v w="$SESSION:fm-zeta" '$3=="stale" && $4==w { last=$5 } END { print (last == "" ? "NO WAKE (WRONG)" : last) }' "$fx/state/.wake-queue" 2>/dev/null)" "$WATCH_EXITED"

# (d) Absorbing is bounded, never permanent: the same standing wait comes back
#     on the long pause cadence.
fx="$STATE_ROOT/alpha"; back=$(( $(date +%s) - 500 ))
touch -m -d "@$back" "$fx/state/alpha.status" 2>/dev/null || touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$fx/state/alpha.status"
seen_sig "$fx/state" "$fx/state/alpha.status"
printf 'idle at the prompt, awaiting captain merge on PR 41 (ctx 71%%)\n' > "$fx/panes/fm-alpha.txt"
printf '  (d) the SAME crew fm-alpha once its declared wait aged past\n'
printf '      FM_PAUSE_RESURFACE_SECS - absorbing is bounded, not permanent silence\n'
run_watcher "$fx" "$fx/state" FM_PAUSE_RESURFACE_SECS=240 FM_STALE_ESCALATE_SECS=240
printf '      watcher   : %s\n' \
  "$(awk -F '\t' -v w="$SESSION:fm-alpha" '$3=="stale" && $4==w { last=$5 } END { print (last == "" ? "NO WAKE (WRONG)" : last) }' "$fx/state/.wake-queue" 2>/dev/null)"
printf '      escalated as a possible wedge? %s\n\n' \
  "$(grep -Fq 'possible wedge' "$fx/state/.wake-queue" 2>/dev/null && echo 'yes (WRONG)' || echo 'no - a recheck, not a wedge')"
hr
