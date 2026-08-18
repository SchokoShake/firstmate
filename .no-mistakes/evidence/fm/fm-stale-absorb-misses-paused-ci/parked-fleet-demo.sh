#!/usr/bin/env bash
# End-to-end demo of the reported supervision-noise defect: crewmates that have
# declared a `paused:` external wait (finished PRs parked on the captain's own
# merge). Drives the REAL bin/fm-watch.sh over N supervision rounds against a
# hermetic fake tmux fleet, and after each round drains the durable wake queue
# exactly as firstmate does - so the transcript shows what the captain actually
# sees.
set -u
REPO=${1:?repo root}
ROUNDS=${2:-6}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-demo.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
STATE="$WORK/state"; BIN="$WORK/bin"; CAP="$WORK/cap"
mkdir -p "$STATE" "$BIN" "$CAP"

# --- hermetic fake tmux fleet: three windows, per-window pane capture ---------
cat > "$BIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for a in "$@"; do
  [ "$prev" = "-t" ] && target=$a
  prev=$a
done
sane() { printf '%s' "$1" | tr ':/.' '___'; }
case "${1:-}" in
  list-windows)
    # -t <session> inventory used by the tmux agent-liveness probe, and the
    # bare inventory used by the watcher.
    for w in $FM_FAKE_WINDOWS; do printf '%s\n' "${w#*:}"; done
    exit 0 ;;
  capture-pane)
    f="$FM_FAKE_CAP_DIR/$(sane "$target").txt"
    [ -f "$f" ] && cat "$f"
    exit 0 ;;
  display-message)
    case "$*" in
      *pane_current_command*)
        v="FM_FAKE_CMD_$(printf '%s' "$target" | tr -c 'A-Za-z0-9' '_')"
        printf '%s\n' "${!v:-zsh}"; exit 0 ;;
      *pane_id*) printf '%%1\n'; exit 0 ;;
    esac
    exit 1 ;;
esac
exit 1
SH
chmod +x "$BIN/tmux"

cat > "$BIN/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
key=$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9' '_')
var="FM_FAKE_CREW_STATE_$key"
printf '%s\n' "${!var:-state: unknown · source: none · fake default}"
exit 0
SH
chmod +x "$BIN/fm-crew-state.sh"

sane() { printf '%s' "$1" | tr ':/.' '___'; }
seen_sig() { stat -c '%s:%Y' "$1" 2>/dev/null; }

# --- the fleet ---------------------------------------------------------------
# Three crewmates, each with a finished PR parked on the captain's own merge.
# logbook + bearings read `paused:` from their status log; ledger's own
# no-mistakes run is attributed and green, so fm-crew-state gives the run
# precedence and reports `done` while the log's last line still declares the wait.
FM_FAKE_WINDOWS="firstmate:fm-logbook firstmate:fm-bearings firstmate:fm-ledger"
export FM_FAKE_WINDOWS FM_FAKE_CAP_DIR="$CAP"

for t in logbook bearings ledger; do
  w="firstmate:fm-$t"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$w" > "$STATE/$t.meta"
  export "FM_FAKE_CMD_$(printf '%s' "$w" | tr -c 'A-Za-z0-9' '_')=grok"   # agent ALIVE
done
printf 'done: PR #21 logbook v2 - all checks green\npaused: awaiting the captain merge on PR #21\n' > "$STATE/logbook.status"
printf 'done: PR #22 bearings snapshot - all checks green\npaused: awaiting the captain merge on PR #22\n' > "$STATE/bearings.status"
printf 'paused: awaiting the captain merge on PR #23\n' > "$STATE/ledger.status"
export FM_FAKE_CREW_STATE_logbook='state: paused · source: status-log · awaiting the captain merge on PR #21'
export FM_FAKE_CREW_STATE_bearings='state: paused · source: status-log · awaiting the captain merge on PR #22'
export FM_FAKE_CREW_STATE_ledger='state: done · source: run-step · checks-passed: PR #23 ready for review'
for t in logbook bearings ledger; do
  printf '%s' "$(seen_sig "$STATE/$t.status")" > "$STATE/.seen-${t}_status"
done

drain_round() {  # prints every wake firstmate would receive, then acks it
  local out err seq gen
  out="$WORK/drain.out"; err="$WORK/drain.err"
  FM_STATE_OVERRIDE="$STATE" "$REPO/bin/fm-wake-drain.sh" > "$out" 2> "$err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  awk -F '\t' '$3 == "stale" || $3 == "signal" { printf "      %s\n", $5 }' "$out" 2>/dev/null || true
  if [ -n "$seq" ] && [ -n "$gen" ]; then
    FM_STATE_OVERRIDE="$STATE" "$REPO/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 || true
  fi
}

echo "watcher under test: $REPO/bin/fm-watch.sh"
echo "fleet: three crewmates, PRs finished and green, each parked on the captain's own merge"
echo "       firstmate:fm-logbook   status log last line -> paused:   crew state -> paused (status-log)"
echo "       firstmate:fm-bearings  status log last line -> paused:   crew state -> paused (status-log)"
echo "       firstmate:fm-ledger    status log last line -> paused:   crew state -> done   (run-step, checks-passed)"
echo "       all three agents are ALIVE and idle at the prompt; each idle pane redraws its context counter between rounds"
echo
total=0
round=1
while [ "$round" -le "$ROUNDS" ]; do
  echo "--- supervision round $round -------------------------------------------------"
  for t in logbook bearings ledger; do
    w="firstmate:fm-$t"
    printf 'idle at the prompt - PR parked on captain merge (ctx %s%%)\n' "$((99 - round))" > "$CAP/$(sane "$w").txt"
    rm -f "$STATE/.hash-$(sane "$w")"
    printf '1\n' > "$STATE/.count-$(sane "$w")"
  done
  PATH="$BIN:$PATH" FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$BIN/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=999999 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$REPO/bin/fm-watch.sh" > "$WORK/watch.$round.out" 2>&1 &
  pid=$!
  i=0; while [ "$i" -lt 150 ]; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    echo "    watcher: still supervising (absorbed everything it saw, never woke firstmate)"
  else
    wait "$pid" 2>/dev/null || true
    echo "    watcher: EXITED to wake firstmate -> $(cat "$WORK/watch.$round.out")"
  fi
  for t in logbook bearings ledger; do
    k=$(sane "firstmate:fm-$t")
    marks=""
    [ -e "$STATE/.stale-$k" ] && marks="$marks stale-pane-classified"
    [ -e "$STATE/.paused-$k" ] && marks="$marks pause-cadence-marker"
    [ -e "$STATE/.stale-since-$k" ] && marks="$marks WEDGE-TIMER-RUNNING"
    printf '    %-24s%s\n' "fm-$t:" "${marks:- (no stale classification reached)}"
  done
  echo "    wakes firstmate drains this round:"
  drain_round
  before=$(awk -F '\t' '$3 == "stale" { n++ } END { print n + 0 }' "$WORK/drain.out" 2>/dev/null)
  [ "${before:-0}" -eq 0 ] && echo "      (none)"
  total=$((total + ${before:-0}))
  round=$((round + 1))
done
echo
echo "=============================================================================="
echo "stale wedge wakes queued across $ROUNDS supervision rounds for 3 parked crewmates: $total"
echo "=============================================================================="
