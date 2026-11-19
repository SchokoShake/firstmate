#!/usr/bin/env bash
# Live typed-draft guard scenarios against the real installed Herdr, in a
# named fm-lab- session created and torn down only through bin/fm-herdr-lab.sh.
# The worker is a small Claude-shaped composer loop registered as a Herdr agent
# with `herdr pane report-agent`, so Herdr's native agent state is real and the
# composer is read by the product's own classifier.
# Usage: typed-draft-lab-scenarios.sh <worktree-root> <base-tree-root>
set -u
ROOT=$1
BASE=$2
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION=$(fm_herdr_lab_name draftguard)
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-draft-lab.XXXXXX")
RESULTS=0
cleanup() { herdr_safe_stop_and_delete "$SESSION"; echo "teardown rc=$? (tripwire verified on 0)"; rm -rf "$SCRATCH"; }
trap cleanup EXIT
ok() { printf 'PASS - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; RESULTS=1; }
lab() { "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" "$@"; }

fm_herdr_lab_prepare "$SESSION" || { echo "lab prepare failed"; exit 2; }
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || exit 2
echo "herdr: $(herdr --version)  lab session: $SESSION"

HOME_DIR="$SCRATCH/home"; mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/draft"
printf '# brief\n' > "$HOME_DIR/data/draft/brief.md"
PROJ="$SCRATCH/proj"; WT="$SCRATCH/wt"; mkdir -p "$PROJ"
git -C "$PROJ" init -q; printf '# p\n' > "$PROJ/README.md"; git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm init
git -C "$PROJ" worktree add --quiet -b draft "$WT"
LOG="$SCRATCH/submitted.log"; : > "$LOG"
RAW=$(fm_backend_herdr_container_ensure "$WT") || { echo "container_ensure failed"; exit 2; }
CONTAINER=${RAW%%$'\t'*}; SEEDED=${RAW#*$'\t'}; WS=${CONTAINER#*:}
read -r TAB PANE <<EOF
$(fm_backend_herdr_create_task "$CONTAINER" fm-draft "$WT" "$SEEDED")
EOF
T="$SESSION:$PANE"
cat > "$HOME_DIR/state/draft.meta" <<META
window=$T
endpoint_task_id=draft
worktree=$WT
project=$PROJ
harness=claude
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WS
herdr_tab_id=$TAB
herdr_pane_id=$PANE
META

# Wait for the pane shell, then start the Claude-shaped composer loop.
for _ in $(seq 1 100); do
  lab pane process-info --pane "$PANE" 2>/dev/null | jq -e '.result.process_info as $p | ($p.foreground_processes|length==1) and ($p.foreground_processes[0].pid==$p.shell_pid)' >/dev/null 2>&1 && break
  sleep 0.1
done
cat > "$SCRATCH/agent.sh" <<'LOOP'
#!/usr/bin/env bash
LOG=$1
rep() { herdr pane report-agent "$HERDR_PANE_ID" --source fm-draft-lab --agent claude --state "$1" --session "$HERDR_SESSION" >/dev/null 2>&1; }
stty -echo -icanon min 1 time 0 2>/dev/null
RULE='────────────────────────────────────────'
draw() { printf '\033[H\033[2Jlab worker (Claude-shaped composer)\n\n%s\n\xe2\x9d\xaf\xc2\xa0%s\n%s\n' "$RULE" "$buf" "$RULE"; }
buf=; rep idle; draw
while IFS= read -r -n 1 c; do
  case "$c" in
    ''|$'\r'|$'\n') printf '%s\n' "$buf" >> "$LOG"; buf=; draw; rep working; sleep 0.6; rep idle ;;
    $'\x15') buf=; draw ;;
    $'\177') buf=${buf%?}; draw ;;
    *) buf="$buf$c"; draw ;;
  esac
done
LOOP
fm_backend_herdr_send_text_line "$T" "bash '$SCRATCH/agent.sh' '$LOG'" || { echo "could not start agent loop"; exit 2; }
sleep 1.5

send() { env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SEND_SETTLE=0 "$1/bin/fm-send.sh" draft "$2"; }
peek() { env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" "$ROOT/bin/fm-peek.sh" draft 8; }
status() { fm_backend_herdr_agent_status_raw "$SESSION" "$PANE"; }
DRAFT='please also list three fruits'
STEER='Reply with exactly the word PONG.'

echo; echo "== self-check: the product classifier reads this composer"
s=$(fm_backend_herdr_composer_state "$T"); echo "empty composer -> $s (agent: $(status))"
[ "$s" = empty ] && ok "empty composer classifies empty" || bad "empty composer classified $s"

echo; echo "== Scenario 1: hand-typed draft while Claude is idle, then fm-send"
lab pane send-text "$PANE" "$DRAFT" >/dev/null; sleep 0.5
echo "composer -> $(fm_backend_herdr_composer_state "$T"), agent -> $(status)"
start=$(date +%s.%N); out=$(send "$ROOT" "$STEER" 2>&1); rc=$?; end=$(date +%s.%N)
printf 'fm-send rc=%s (%.2fs)\n%s\n' "$rc" "$(awk -v a="$start" -v b="$end" 'BEGIN{print b-a}')" "$out"
echo "-- fm-peek draft:"; peek
[ "$rc" -ne 0 ] && grep -q 'already holds unsent text' <<<"$out" && ok "fm-send refused with the occupied error" || bad "fm-send did not refuse"
[ ! -s "$LOG" ] && ok "nothing was submitted" || bad "a turn was submitted: $(cat "$LOG")"
peek | grep -q "$DRAFT\$" && ! peek | grep -q PONG && ok "draft intact and alone in the composer" || bad "draft was changed"

echo; echo "== Scenario 2: hand-typed draft while Herdr reports the worker working, then fm-send"
herdr pane report-agent "$PANE" --source fm-draft-lab --agent claude --state working --session "$SESSION" >/dev/null 2>&1
sleep 0.3; echo "agent -> $(status)"
out=$(send "$ROOT" "$STEER" 2>&1); rc=$?
printf 'fm-send rc=%s\n%s\n' "$rc" "$out"
[ "$rc" -ne 0 ] && grep -q 'already holds unsent text' <<<"$out" && ok "fm-send refused mid-turn" || bad "fm-send did not refuse mid-turn"
[ ! -s "$LOG" ] && ok "nothing was submitted" || bad "a turn was submitted: $(cat "$LOG")"
herdr pane report-agent "$PANE" --source fm-draft-lab --agent claude --state idle --session "$SESSION" >/dev/null 2>&1; sleep 0.3

echo; echo "== Scenario 3: fm-control exit with the draft still held"
out=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 "$ROOT/bin/fm-control.sh" draft exit 2>&1); rc=$?
printf 'fm-control rc=%s\n%s\n' "$rc" "$out"
echo "agent after -> $(status)"; echo "-- fm-peek:"; peek
[ "$rc" -ne 0 ] && grep -q 'already holds unsent text' <<<"$out" && ok "exit refused with the occupied error" || bad "exit did not refuse"
grep -q 'exit-command=delivered' <<<"$out" && bad "exit claimed delivery" || ok "exit did not claim the command was delivered"
[ "$(status)" = idle ] && ok "worker still running" || bad "worker state $(status)"
[ ! -s "$LOG" ] && peek | grep -q "$DRAFT\$" && ok "nothing submitted and draft intact" || bad "log/draft changed: $(cat "$LOG")"

echo; echo "== Scenario 4: captain clears the draft (Ctrl+U), the same steer now delivers"
lab pane send-text "$PANE" $'\x15' >/dev/null; sleep 0.5
echo "composer -> $(fm_backend_herdr_composer_state "$T")"
out=$(send "$ROOT" "$STEER" 2>&1); rc=$?
printf 'fm-send rc=%s\n%s\n' "$rc" "$out"; echo "-- submitted turns:"; cat "$LOG"
[ "$rc" -eq 0 ] && ok "fm-send confirmed delivery" || bad "fm-send failed on an empty composer"
[ "$(cat "$LOG")" = "$STEER" ] && ok "exactly the steer was submitted, no draft text" || bad "submitted: $(cat "$LOG")"
sleep 1; : > "$LOG"

echo; echo "== Scenario 5 (before the fix): the base commit's fm-send against the same draft"
lab pane send-text "$PANE" "$DRAFT" >/dev/null; sleep 0.5
out=$(send "$BASE" "$STEER" 2>&1); rc=$?
printf 'base fm-send rc=%s\n%s\n' "$rc" "$out"; echo "-- submitted turns:"; cat "$LOG"
if grep -qF "$DRAFT$STEER" "$LOG"; then echo "REPRODUCED: base merged the draft and the steer into one submitted turn (rc=$rc)"; else echo "base did not merge (log above)"; fi
sleep 1

echo; [ "$RESULTS" -eq 0 ] && echo "ALL GUARD SCENARIOS PASSED" || echo "SOME GUARD SCENARIOS FAILED"
exit "$RESULTS"
