#!/usr/bin/env bash
# Live adversarial check: `bin/fm-control.sh <id> revive` for a Herdr task whose
# lab server is STOPPED (as after a reboot) and CANNOT be started must refuse,
# name the server, and change nothing. A real lab session is provisioned and
# stopped through bin/fm-herdr-lab.sh; the lab-scoped herdr wrapper refuses the
# bare `herdr server` start (exit 1) to simulate a server that will not start,
# while every other call reaches the real (stopped) lab session via the helper.
# Usage: herdr-revive-cannot-start-driver.sh <worktree-root>
set -u
WT_ROOT=$1
# shellcheck source=/dev/null
. "$WT_ROOT/tests/lib.sh"
. "$ROOT/tests/herdr-test-safety.sh"
ORIGINAL_PATH=$PATH
HELPER=$ROOT/bin/fm-herdr-lab.sh
lab() { PATH="$ORIGINAL_PATH" "$HELPER" "$@"; }
SESSION=$(lab name fm-rv-nostart) || fail "could not name a lab session"
LAB=$(fm_test_tmproot fm-rv-nostart) || fail "no scratch dir"
LAB=$(cd "$LAB" && pwd -P)
ID="rvns$$"
HOME_DIR="$LAB/fmhome"; STATE_DIR="$HOME_DIR/state"
PROJ_DIR="$LAB/proj"; WT="$LAB/pool/1/wt"
STARTS="$LAB/server-start-attempts.log"; : > "$STARTS"
cleanup() { local rc=$?; trap - EXIT; lab teardown "$SESSION" || { echo "not ok - lab teardown/tripwire failed" >&2; rc=1; }; fm_test_cleanup; exit "$rc"; }
trap cleanup EXIT
herdr_forget_inherited_pane
unset TMUX TMUX_PANE GOTMPDIR TRACEPARENT CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_PID
mkdir -p "$LAB/bin" "$HOME_DIR/data/$ID" "$STATE_DIR" "$HOME_DIR/config" "$HOME_DIR/projects"
cat > "$LAB/bin/herdr" <<EOF
#!/usr/bin/env bash
set -uo pipefail
args=("\$@"); n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = '$SESSION' ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
fi
if [ "\${#args[@]}" -eq 1 ] && [ "\${args[0]}" = server ]; then
  echo "server start attempted (refused by the wrapper: simulated server that will not start)" >> '$STARTS'
  exit 1
fi
PATH='$ORIGINAL_PATH' exec '$HELPER' run '$SESSION' "\${args[@]}"
EOF
chmod +x "$LAB/bin/herdr"
fm_fake_treehouse "$LAB/bin"
fm_fake_exit0 "$LAB/bin" agent-presence gh gh-axi no-mistakes
export PATH="$LAB/bin:$PATH" HERDR_SESSION="$SESSION"
fm_git_worktree "$PROJ_DIR" "$WT" "task-$ID" || fail "scratch repo"
printf 'herdr\n' > "$HOME_DIR/config/backend"
printf '# brief\n' > "$HOME_DIR/data/$ID/brief.md"

lab provision "$SESSION" >/dev/null || fail "could not provision lab"
PANE=$(lab run "$SESSION" pane list 2>/dev/null | jq -r '.result.panes[0].pane_id // empty')
WS=$(lab run "$SESSION" pane list 2>/dev/null | jq -r '.result.panes[0].workspace_id // empty')
TAB=$(lab run "$SESSION" pane list 2>/dev/null | jq -r '.result.panes[0].tab_id // empty')
[ -n "$PANE" ] || PANE=w1:p1; [ -n "$WS" ] || WS=w1; [ -n "$TAB" ] || TAB=w1:t1
cat > "$STATE_DIR/$ID.meta" <<EOF
window=$SESSION:$PANE
endpoint_task_id=$ID
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WS
herdr_tab_id=$TAB
herdr_pane_id=$PANE
worktree=$WT
project=$PROJ_DIR
harness=claude
kind=ship
mode=no-mistakes
yolo=off
busy_gen=g1
EOF
printf 'g1\n' > "$STATE_DIR/$ID.busy-gen"
lab stop "$SESSION" >/dev/null 2>&1 || fail "lab stop failed"
running() { lab run "$SESSION" session list --json 2>/dev/null | jq -r --arg s "$SESSION" '.sessions[]? | select(.name == $s) | .running'; }
echo "# lab session $SESSION stopped: running=$(running); task $ID endpoint $SESSION:$PANE"
before=$(cd "$HOME_DIR" && find . -type f -exec sha256sum {} + | sort)
rc=0
out=$(env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_CONTROL_HERDR_RESTORE_WAIT=3 FM_CONTROL_NM_TIMEOUT=5 \
  "$ROOT/bin/fm-control.sh" "$ID" revive 2>&1) || rc=$?
after=$(cd "$HOME_DIR" && find . -type f -exec sha256sum {} + | sort)
echo "# revive rc=$rc output:"; printf '#   %s\n' "$out"
echo "# server start attempts: $(wc -l < "$STARTS")"; sed 's/^/#   /' "$STARTS"
echo "# lab running after revive: $(running)"
ok=1
[ "$rc" -ne 0 ] || { echo "not ok - revive succeeded although the server could not start"; ok=0; }
case "$out" in *"could not start the Herdr server that task $ID's endpoint $SESSION:$PANE lives in; nothing was changed"*) ;; *) echo "not ok - refusal does not name the server"; ok=0 ;; esac
[ -s "$STARTS" ] || { echo "not ok - revive never tried to start the server"; ok=0; }
[ "$before" = "$after" ] || { echo "not ok - revive changed the firstmate home:"; diff <(echo "$before") <(echo "$after"); ok=0; }
[ "$(running)" = false ] || { echo "not ok - lab session is not stopped"; ok=0; }
[ "$ok" = 1 ] && echo "ok - revive into a stopped Herdr server that cannot start refuses by name, tried the start, and left the home byte-identical"
[ "$ok" = 1 ]
