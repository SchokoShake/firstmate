#!/usr/bin/env bash
# Companion to parked-fleet-demo.sh: the property a reviewer cannot read off the
# diff. With the SAME `paused:` declaration standing on the status log and the
# fix in place, every genuine failure route must still reach firstmate. Each case
# below drives the REAL bin/fm-watch.sh and then drains the durable wake queue.
set -u
REPO=${1:?repo root}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-surface.XXXXXX")
[ -n "${FM_DEMO_KEEP:-}" ] || trap 'rm -rf "$WORK"' EXIT
[ -n "${FM_DEMO_KEEP:-}" ] && echo "work: $WORK" >&2
sane() { printf '%s' "$1" | tr ':/.' '___'; }
seen_sig() { stat -c '%s:%Y' "$1" 2>/dev/null; }
hash_text() { printf '%s' "$1" | md5sum | cut -d' ' -f1; }

new_case() {  # <name>; echoes the case dir
  local d="$WORK/$1"; mkdir -p "$d/state" "$d/bin" "$d/cap"
  cat > "$d/bin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""; prev=""
for a in "$@"; do [ "$prev" = "-t" ] && target=$a; prev=$a; done
sane() { printf '%s' "$1" | tr ':/.' '___'; }
case "${1:-}" in
  list-windows) for w in $FM_FAKE_WINDOWS; do printf '%s\n' "${w#*:}"; done; exit 0 ;;
  capture-pane) f="$FM_FAKE_CAP_DIR/$(sane "$target").txt"; [ -f "$f" ] && cat "$f"; exit 0 ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf '%s\n' "${FM_FAKE_CMD:-zsh}"; exit 0 ;;
      *pane_id*) printf '%%1\n'; exit 0 ;;
    esac; exit 1 ;;
esac
exit 1
SH
  chmod +x "$d/bin/tmux"
  cat > "$d/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none · fake default}"
SH
  chmod +x "$d/bin/fm-crew-state.sh"
  printf '%s\n' "$d"
}

run_watch() {  # <case-dir> <extra env...>; runs the real watcher, reports exit
  local d=$1; shift
  local pid i=0
  env PATH="$d/bin:$PATH" FM_STATE_OVERRIDE="$d/state" FM_CREW_STATE_BIN="$d/bin/fm-crew-state.sh" \
    FM_FAKE_CAP_DIR="$d/cap" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$@" "$REPO/bin/fm-watch.sh" > "$d/watch.out" 2>&1 &
  pid=$!
  while [ "$i" -lt 200 ]; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    printf '    watcher: still supervising, firstmate NOT woken\n'
  else
    wait "$pid" 2>/dev/null || true
    printf '    watcher: EXITED to wake firstmate\n'
  fi
}

drain() {  # <case-dir>
  local d=$1 seq gen
  FM_STATE_OVERRIDE="$d/state" "$REPO/bin/fm-wake-drain.sh" > "$d/drain.out" 2> "$d/drain.err" || true
  if [ -s "$d/drain.out" ]; then
    printf '    firstmate drains:\n'
    sed 's/^/      | /' "$d/drain.out"
  else printf '    firstmate drains: (nothing)\n'; fi
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$d/drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$d/drain.err")
  [ -n "$seq" ] && [ -n "$gen" ] && FM_STATE_OVERRIDE="$d/state" "$REPO/bin/fm-wake-drain.sh" \
    --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 || true
}

setup() {  # <case-dir> <task> <window> <status-lines> <pane-text> <crew-state> <cmd>
  local d=$1 task=$2 w=$3 status=$4 pane=$5
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$w" > "$d/state/$task.meta"
  printf '%b' "$status" > "$d/state/$task.status"
  printf '%s' "$(seen_sig "$d/state/$task.status")" > "$d/state/.seen-${task}_status"
  printf '%s\n' "$pane" > "$d/cap/$(sane "$w").txt"
  printf '%s' "$(hash_text "$pane")" > "$d/state/.hash-$(sane "$w")"
  printf '1\n' > "$d/state/.count-$(sane "$w")"
}

W=firstmate:fm-parked
K=$(sane "$W")
export FM_FAKE_WINDOWS="$W"

echo "watcher under test: $REPO/bin/fm-watch.sh"
echo "every case below keeps the SAME standing 'paused: awaiting the captain merge' on the status log"
echo

echo "(a) the wait turned into a real blocker - 'blocked:' must never be absorbed"
d=$(new_case blocked)
setup "$d" parked "$W" 'paused: awaiting the captain merge on PR #21\nblocked: the merge needs a branch-protection override I do not have\n' \
  'idle after the merge turned into a blocker'
run_watch "$d" FM_FAKE_CREW_STATE='state: blocked · source: status-log · needs an override' FM_FAKE_CMD=grok \
  FM_PAUSE_RESURFACE_SECS=999999 FM_STALE_ESCALATE_SECS=240
drain "$d"
echo

echo "(b) the worker's declared-wait verdict is gone while its endpoint is a bare shell - it actually died"
d=$(new_case verdict-lost)
setup "$d" parked "$W" 'paused: awaiting the captain merge on PR #21\n' \
  'a bare shell prompt where the agent used to be'
run_watch "$d" FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown: bare shell)' FM_FAKE_CMD=grok \
  FM_PAUSE_RESURFACE_SECS=999999 FM_STALE_ESCALATE_SECS=240
drain "$d"
echo

echo "(c) the worker resumed real work under the same declared pause, then froze - the wedge timer still fires"
d=$(new_case frozen-run)
setup "$d" parked "$W" 'paused: awaiting the captain merge on PR #21\n' \
  'a static pane while the pipeline runs CI'
run_watch "$d" FM_FAKE_CREW_STATE='state: working · source: run-step · ci' FM_FAKE_CMD=grok \
  FM_PAUSE_RESURFACE_SECS=999999 FM_STALE_ESCALATE_SECS=240
printf '    (wedge timer armed: %s)\n' "$([ -e "$d/state/.stale-since-$K" ] && echo yes || echo no)"
drain "$d" >/dev/null 2>&1
printf '%s\n' $(( $(date +%s) - 500 )) > "$d/state/.stale-since-$K"
echo "    ...the run then makes no progress for 500s (> FM_STALE_ESCALATE_SECS=240)"
run_watch "$d" FM_FAKE_CREW_STATE='state: working · source: run-step · ci' FM_FAKE_CMD=grok \
  FM_PAUSE_RESURFACE_SECS=999999 FM_STALE_ESCALATE_SECS=240
drain "$d"
echo

echo "(d) nobody ever merges - the declared wait itself ages past FM_PAUSE_RESURFACE_SECS and comes back for a recheck"
d=$(new_case aged-wait)
setup "$d" parked "$W" 'paused: awaiting the captain merge on PR #21\n' \
  'idle at the prompt, still awaiting the captain merge'
touch -m -d "@$(( $(date +%s) - 500 ))" "$d/state/parked.status"
printf '%s' "$(seen_sig "$d/state/parked.status")" > "$d/state/.seen-parked_status"
run_watch "$d" FM_FAKE_CREW_STATE='state: done · source: run-step · checks-passed: PR #21 ready for review' FM_FAKE_CMD=grok \
  FM_PAUSE_RESURFACE_SECS=240 FM_STALE_ESCALATE_SECS=240
drain "$d"
