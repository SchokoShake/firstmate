#!/usr/bin/env bash
# Live validation harness for fm-status-note.sh + the four-hour pause cadence.
# Drives the REAL bin/ scripts (fm-status-note.sh, fm-watch.sh, fm-crew-state.sh,
# fm-wake-drain.sh, fm-supervise-daemon.sh, fm-afk-return.sh) against a throwaway
# FM_HOME and a private tmux server (TMUX_TMPDIR) whose worker panes are real
# tmux windows. No fake tmux, no fake crew-state. Time passing is simulated only
# by backdating a status-file mtime or a daemon pause marker.
set -u
ROOT=${ROOT:?worktree root}
EV=${EV:?evidence dir}
PHASES=${PHASES:-"1 2 3 4 5 6 7"}
LIVE=$(mktemp -d /tmp/fm-live-XXXXXX)
T="$EV/${TNAME:-live-transcript.txt}"
: > "$T"
export TMUX_TMPDIR="$LIVE/tmux"; mkdir -p "$TMUX_TMPDIR"
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID FM_PAUSE_RESURFACE_SECS FM_CREW_STATE_BIN
export FM_HOME="$LIVE/home"; export FM_STATE_OVERRIDE="$FM_HOME/state"
STATE=$FM_STATE_OVERRIDE; mkdir -p "$STATE"
export FM_WEDGE_ALARM_EXEC=discard
B="$ROOT/bin"
S=fmlive

log() { printf '%s\n' "$*" >> "$T"; }
hdr() { log ""; log "=================================================================="; log "== $*"; log "=================================================================="; }
run() {  # print the command, its combined output and exit code
  local rc
  log "\$ $*"
  "$@" >> "$T" 2>&1; rc=$?
  log "[exit $rc]"
  return "$rc"
}
show_status() { log "--- $1.status ($(wc -l < "$STATE/$1.status" | tr -d ' ') lines) ---"; sed 's/^/  | /' "$STATE/$1.status" >> "$T"; }
crew() { log "\$ bin/fm-crew-state.sh $1"; "$B/fm-crew-state.sh" "$1" >> "$T" 2>&1; }
pane_snap() { log "--- tmux capture-pane $1 ---"; tmux capture-pane -p -t "$1" | sed '/^$/d; s/^/  # /' >> "$T"; }
wkey() { printf '%s' "$1" | tr ':/.' '___'; }
qlen() { awk 'END{print NR}' "$STATE/.wake-queue" 2>/dev/null || echo 0; }

mkworker() {  # <id> <first status line>
  local id=$1 line=$2
  mkdir -p "$LIVE/wt-$id"
  printf 'grok 1.2  model: grok-code  (ctx 91%%)\n> idle at the prompt\n' > "$LIVE/$id.pane"
  if tmux has-session -t "$S" 2>/dev/null; then
    tmux new-window -d -t "$S" -n "fm-$id" "tail -n +1 -F $LIVE/$id.pane"
  else
    tmux new-session -d -s "$S" -n "fm-$id" -x 140 -y 30 "tail -n +1 -F $LIVE/$id.pane"
  fi
  printf 'window=%s:fm-%s\nworktree=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$S" "$id" "$LIVE/wt-$id" > "$STATE/$id.meta"
  printf '%s\n' "$line" > "$STATE/$id.status"
}
redraw() { printf '%s\n' "$2" >> "$LIVE/$1.pane"; }
backdate_seen() {  # <id> <secs-ago>: time travel - the line was written <secs> ago AND already announced
  touch -d "@$(( $(date +%s) - $2 ))" "$STATE/$1.status"
  printf '%s' "$(stat -c '%s:%Y' "$STATE/$1.status")" > "$STATE/.seen-$1_status"
}

WPID=""
start_watch() {  # <out> [env...]
  local out=$1; shift
  env FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT="${HB:-999999}" "$@" \
    "$B/fm-watch.sh" > "$out" 2> "$out.err" &
  WPID=$!
}
stop_watch() { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; WPID=""; }
# observe <label> <secs> [env...] : run the real watcher; 0 = it WOKE (exited with a reason), 1 = stayed QUIET
observe() {
  local label=$1 secs=$2 out="$LIVE/watch-$1.out" i=0 q0
  shift 2
  q0=$(qlen)
  start_watch "$out" "$@"
  while [ "$i" -lt $((secs * 5)) ]; do
    kill -0 "$WPID" 2>/dev/null || break
    sleep 0.2; i=$((i + 1))
  done
  if kill -0 "$WPID" 2>/dev/null; then
    stop_watch
    log "[watcher $label] QUIET for ${secs}s - no wake printed, wake-queue rows $q0 -> $(qlen)"
    log "  (harness stopped the quiet watcher; draining + acking its downtime-recovery record so the next arm starts clean)"
    ack
    return 1
  fi
  wait "$WPID" 2>/dev/null; WPID=""
  log "[watcher $label] WOKE after ~$((i / 5))s, wake-queue rows $q0 -> $(qlen); printed reason:"
  sed 's/^/  > /' "$out" >> "$T"
  return 0
}
ack() {  # drain (what firstmate reads) then acknowledge
  local err="$LIVE/drain.err" seq gen
  log "\$ bin/fm-wake-drain.sh   (firstmate reads the wake)"
  "$B/fm-wake-drain.sh" 2> "$err" | sed 's/^/  d| /' >> "$T"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err" | tail -1)
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err" | tail -1)
  [ -n "$seq" ] && [ -n "$gen" ] && "$B/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 \
    && log "  (acknowledged through $seq)"
}
settle() {  # run watcher cycles, reading+acking every wake, until it stays quiet
  local label=$1 i=0
  while [ "$i" -lt 8 ]; do
    observe "$label-settle$i" 6 || return 0
    ack; i=$((i + 1))
  done
  log "!! $label never settled"; return 1
}
check() {  # <description> <command...>
  local d=$1; shift
  if "$@"; then log "CHECK PASS: $d"; else log "CHECK FAIL: $d"; FAILS=$((FAILS + 1)); fi
}
FAILS=0
cleanup() {
  [ -n "${DPID:-}" ] && kill "$DPID" 2>/dev/null
  [ -n "$WPID" ] && stop_watch
  tmux kill-server 2>/dev/null
  log ""; log "TOTAL CHECK FAILURES: $FAILS"
}
trap cleanup EXIT

hdr "SETUP: private tmux server ($TMUX_TMPDIR), throwaway FM_HOME=$FM_HOME, FM_PAUSE_RESURFACE_SECS unset"
log "code under test: ${REV:-$(git -C "$ROOT" rev-parse HEAD)}"
mkworker held 'paused: waiting on the upstream release v2 before bumping the pin'
mkworker blk 'blocked [key=cred]: need the staging credential to run the migration check'
tmux new-window -d -t "$S" -n sup "cat"
run tmux list-windows -t "$S" -F '#{window_name} pid=#{pane_pid} cmd=#{pane_current_command}'
crew held; crew blk
hdr "SETTLE: let the watcher surface the workers' own first lines once, read + ack each wake"
settle initial
show_status held; show_status blk

case " $PHASES " in *" 1 "*)
hdr "S1: firstmate memo on a PAUSED worker (captain tokens in prose) does not wake firstmate, does not mask the pause; the worker's next line still wakes"
run "$B/fm-status-note.sh" held 'captain merged PR 12 by hand; keep holding until upstream v2 ships'
show_status held
crew held
check "memo did not change crew-state: still paused from the worker's own line" \
  bash -c "'$B/fm-crew-state.sh' held | grep -q '^state: paused · source: status-log · waiting on the upstream release v2'"
redraw held '> idle at the prompt (ctx 90%)'
pane_snap "$S:fm-held"
HB=2 observe s1-memo 12; rc=$?
check "watcher stayed quiet after the memo, pane redraw and two heartbeat scans" test "$rc" -eq 1
k=$(wkey "$S:fm-held")
check "watcher absorbed the redrawn pane on the declared-pause path (.paused-$k kept)" test -e "$STATE/.paused-$k"
log "--- triage log tail ---"; tail -4 "$STATE/.watch-triage.log" 2>/dev/null | sed 's/^/  t| /' >> "$T"
check "heartbeat scan ran while the memo was the newest line and absorbed it" grep -q "absorbed heartbeat" "$STATE/.watch-triage.log"
log "-- now the WORKER appends its own line while the watcher runs --"
start_watch "$LIVE/watch-s1-worker.out"; sleep 3
log "\$ echo 'working: upstream v2 released, bumping the pin' >> state/held.status   (worker)"
printf 'working: upstream v2 released, bumping the pin\n' >> "$STATE/held.status"
i=0; while kill -0 "$WPID" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done
if kill -0 "$WPID" 2>/dev/null; then stop_watch; log "[watcher s1-worker] QUIET (worker line swallowed!)"; FAILS=$((FAILS+1))
else wait "$WPID"; WPID=""; log "[watcher s1-worker] WOKE:"; sed 's/^/  > /' "$LIVE/watch-s1-worker.out" >> "$T"; fi
check "worker line woke firstmate (its line ended the pause: stale on the pane or signal on held.status)" \
  grep -Eq "signal: .*held.status|stale: $S:fm-held" "$LIVE/watch-s1-worker.out"
ack
log "-- settle every follow-up wake the worker's line causes (its pause ended while the pane stays idle) --"
settle s1-after-worker
check "the worker's line surfaced as signal: held.status on the first or a follow-up arm" \
  bash -c "cat '$LIVE'/watch-s1-worker.out '$LIVE'/watch-s1-after-worker-settle*.out 2>/dev/null | grep -q 'signal: .*held.status'"
;; esac

case " $PHASES " in *" 2 "*)
hdr "S2: firstmate closes an open blocker by hand with --resolve: no wake, key closed, a repeat close is refused"
log "-- OPEN DECISIONS as the drain shows them before the close --"
"$B/fm-wake-drain.sh" 2>/dev/null | sed 's/^/  d| /' >> "$T"
run "$B/fm-status-note.sh" --resolve cred blk 'captain provided the staging credential out of band'
show_status blk
observe s2-resolve 8; rc=$?
check "watcher stayed quiet after the by-hand close" test "$rc" -eq 1
log "-- drain after the close (no OPEN DECISIONS row for cred expected) --"
"$B/fm-wake-drain.sh" 2>/dev/null | sed 's/^/  d| /' >> "$T"
check "drain lists no open decision for key cred" bash -c "! '$B/fm-wake-drain.sh' 2>/dev/null | grep -q 'cred'"
n0=$(wc -l < "$STATE/blk.status")
run "$B/fm-status-note.sh" --resolve cred blk 'second close'; rc=$?
check "repeat close of an already-closed key is refused with exit 1" test "$rc" -eq 1
check "refused close wrote nothing" test "$(wc -l < "$STATE/blk.status")" -eq "$n0"
crew blk
;; esac

case " $PHASES " in *" 3 "*)
hdr "S3 (adversarial): a memo written while a WORKER line is still unannounced must not swallow it"
log "\$ echo 'done: PR https://example.test/pr/7 opened, checks green' >> state/blk.status   (worker, nobody has seen it yet)"
printf 'done: PR https://example.test/pr/7 opened, checks green\n' >> "$STATE/blk.status"
run "$B/fm-status-note.sh" blk 'will review PR 7 after lunch'; rc=$?
check "memo over a pending worker line still exits 0 (caller never retries)" test "$rc" -eq 0
show_status blk
observe s3-pending 10; rc=$?
check "watcher woke for the worker's done: line despite the memo" test "$rc" -eq 0
check "the wake names blk.status" grep -q "blk.status" "$LIVE/watch-s3-pending.out"
ack
;; esac

case " $PHASES " in *" 4 "*)
hdr "S4 (adversarial): refusals and one-line folding at the CLI"
run "$B/fm-status-note.sh" --help
mkdir -p "$LIVE/s4"
run "$B/fm-status-note.sh" nosuch 'typo task'; rc=$?
check "no status log -> exit 1" test "$rc" -eq 1
check "no stray status log created" test ! -e "$STATE/nosuch.status"
run "$B/fm-status-note.sh" '../escape' 'x'; rc=$?; check "path-like id -> exit 1" test "$rc" -eq 1
run "$B/fm-status-note.sh" '-held' 'x'; rc=$?; check "dash id -> exit 1" test "$rc" -eq 1
run "$B/fm-status-note.sh" held $' \t \n '; rc=$?; check "blank text -> exit 1" test "$rc" -eq 1
run "$B/fm-status-note.sh" --resolve nokey held 'x'; rc=$?; check "unopened key -> exit 1" test "$rc" -eq 1
run "$B/fm-status-note.sh" --resolve 'bad key' held 'x'; rc=$?; check "non-slug key -> exit 1" test "$rc" -eq 1
printf 'blocked [key=pending-reply-0123456789abcdef]: pending-reply-opened: waiting on the mate\n' > "$STATE/rsv.status"
log "(fixture: state/rsv.status holds an open library-owned pending-reply-* blocker)"
run "$B/fm-status-note.sh" --resolve pending-reply-0123456789abcdef rsv 'by hand'; rc=$?
check "reserved pending-reply key -> exit 1" test "$rc" -eq 1
check "refused reserved close wrote nothing" test "$(wc -l < "$STATE/rsv.status")" -eq 1
rm -f "$STATE/rsv.status"
n0=$(wc -l < "$STATE/held.status")
run "$B/fm-status-note.sh" held "$(printf 'line one\nblocked: fake second line\tend\033[31m')"; rc=$?
check "multi-line/tab/escape text accepted" test "$rc" -eq 0
check "exactly one line appended" test "$(wc -l < "$STATE/held.status")" -eq $((n0 + 1))
check "folded to one firstmate note" grep -qx 'note: firstmate: line one blocked: fake second line end\[31m' "$STATE/held.status"
show_status held
observe s4-quiet 6; rc=$?
check "the folded memo did not wake firstmate" test "$rc" -eq 1
;; esac

case " $PHASES " in *" 5 "*)
hdr "S5: watcher default pause cadence is four hours (FM_PAUSE_RESURFACE_SECS unset)"
mkworker wait 'paused: waiting on the upstream tool release'
settle s5
k=$(wkey "$S:fm-wait")
log "-- simulate: the worker declared the pause 2h ago (status mtime backdated 7200s) --"
backdate_seen wait 7200
rm -f "$STATE/.paused-resurfaced-$k"
redraw wait '> idle at the prompt (ctx 90%)'
observe s5-2h 10; rc=$?
check "two-hour-old declared pause stays QUIET under the default" test "$rc" -eq 1
check "two-hour pause is tracked as paused (.paused-$k)" test -e "$STATE/.paused-$k"
check "no re-surface recorded at two hours" test ! -e "$STATE/.paused-resurfaced-$k"
log "-- contrast: the explicit old value FM_PAUSE_RESURFACE_SECS=3600 still honored --"
observe s5-2h-override3600 10 FM_PAUSE_RESURFACE_SECS=3600; rc=$?
check "explicit 3600 override re-surfaces the same two-hour pause" test "$rc" -eq 0
check "override re-surface is an awaiting-external recheck" grep -q "awaiting external" "$LIVE/watch-s5-2h-override3600.out"
ack; rm -f "$STATE/.paused-resurfaced-$k"
log "-- simulate: the pause was declared 4h02m ago (status mtime backdated 14520s), default again --"
backdate_seen wait 14520
redraw wait '> idle at the prompt (ctx 89%)'
observe s5-4h 10; rc=$?
check "pause idle past four hours re-surfaces under the default" test "$rc" -eq 0
check "re-surface is an awaiting-external recheck" grep -q "awaiting external" "$LIVE/watch-s5-4h.out"
ack
;; esac

case " $PHASES " in *" 6 "*)
hdr "S6: away-mode daemon default pause cadence is four hours; a firstmate memo keeps the pause marker"
printf 'paused: waiting on the upstream tool release (redeclared)\n' >> "$STATE/wait.status"
settle s6-pre
: > "$STATE/.afk"
env FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET="$S:sup" FM_HOUSEKEEPING_TICK=1 \
  FM_ESCALATE_BATCH_SECS=3600 FM_MAX_DEFER_SECS=0 FM_HEARTBEAT_SCAN_SECS=999999 \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$B/fm-supervise-daemon.sh" > "$LIVE/daemon.out" 2>&1 &
DPID=$!
sleep 6
m="$STATE/.subsuper-paused-wait"
check "daemon seeded the pause marker for the paused worker" test -e "$m"
log "-- simulate: daemon first saw the pause 2h ago --"
echo $(( $(date +%s) - 7200 )) > "$m"
run "$B/fm-status-note.sh" wait 'captain says keep holding; upstream PR merged is not enough'
sleep 6
check "daemon kept the pause marker after the memo (memo did not mask the pause)" test -e "$m"
check "the daemon's watcher child took no wake for the memo" bash -c "! grep -q 'wake:' '$STATE/.supervise-daemon.log'"
check "no recheck escalation at two hours under the default" bash -c "! grep -q 'paused' '$STATE/.subsuper-escalations' 2>/dev/null"
log "-- simulate: daemon first saw the pause 4h02m ago --"
echo $(( $(date +%s) - 14520 )) > "$m"
sleep 6
log "--- state/.subsuper-escalations ---"; sed 's/^/  e| /' "$STATE/.subsuper-escalations" >> "$T" 2>/dev/null
check "daemon escalated one awaiting-external recheck past four hours" grep -Eq 'paused 14[4-9][0-9]{2}s \(awaiting external' "$STATE/.subsuper-escalations"
check "daemon reset the pause window after the recheck" test "$(( $(date +%s) - $(cat "$m") ))" -lt 60
log "--- daemon log (tail) ---"; tail -8 "$STATE/.supervise-daemon.log" | sed 's/^/  L| /' >> "$T"
;; esac

case " $PHASES " in *" 7 "*)
hdr "S7: /afk return gate names the helper; following it closes the blocker and clears the gate"
printf 'blocked [key=db]: the staging database refuses connections\n' >> "$STATE/held.status"
sleep 4
log "\$ bin/fm-afk-return.sh   (captain is back)"
"$B/fm-afk-return.sh" >> "$T" 2>&1; rc=$?; log "[exit $rc]"; DPID=""
check "return gate refused with exit 3 while the blocker is open" test "$rc" -eq 3
check "gate message points at bin/fm-status-note.sh --resolve" grep -q 'close it with bin/fm-status-note.sh --resolve <key> <task-id>' "$T"
run "$B/fm-status-note.sh" --resolve db held 'reclassified: the captain is fixing staging DB access directly; no crew action'
run "$B/fm-afk-return.sh" check; rc=$?
check "afk-return check now clears" test "$rc" -eq 0
show_status held
pane_snap "$S:sup"
;; esac

case " $PHASES " in *" 8 "*)
hdr "S8: a captain-held crew whose agent has exited (bare shell pane) shares the four-hour default"
mkdir -p "$LIVE/wt-hold"
tmux new-window -d -t "$S" -n fm-hold "bash --noprofile --norc"
printf 'window=%s:fm-hold\nworktree=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$S" "$LIVE/wt-hold" > "$STATE/hold.meta"
printf 'captain-held [key=route]: tracked in the backlog until the captain picks a route\n' > "$STATE/hold.status"
sleep 1
run tmux display-message -p -t "$S:fm-hold" 'fm-hold pane_current_command=#{pane_current_command}'
crew hold
settle s8
k=$(wkey "$S:fm-hold")
backdate_seen hold 7200; rm -f "$STATE/.paused-resurfaced-$k"
observe s8-2h 10; rc=$?
check "two-hour dead-agent captain-held stays QUIET under the default" test "$rc" -eq 1
check "dead-agent captain-held is tracked on the pause cadence (.paused-$k)" test -e "$STATE/.paused-$k"
backdate_seen hold 14520
observe s8-4h 10; rc=$?
check "dead-agent captain-held past four hours re-surfaces under the default" test "$rc" -eq 0
check "its re-surface is the awaiting-external recheck" grep -q "stale: $S:fm-hold (paused 14[4-9][0-9][0-9]s, awaiting external" "$LIVE/watch-s8-4h.out"
ack
;; esac
