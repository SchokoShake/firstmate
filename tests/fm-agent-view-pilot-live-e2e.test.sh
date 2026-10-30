#!/usr/bin/env bash
# tests/fm-agent-view-pilot-live-e2e.test.sh - opt-in live guard for the
# agent-view pilot (bin/fm-agent-view-lib.sh) against the REAL Claude Code.
#
# Why this file exists: the pilot's typing guard reads surfaces Claude Code
# owns and can change without notice - the viewer's process arguments, the name
# in its composer border, and the agent view's footer - and its lifecycle rides
# `claude --bg`, `claude attach`, `claude stop`, `claude rm`, and
# `claude agents --json --all`. The agent view is a research preview, so any
# Claude Code update can move any of them. The portable regression
# (tests/fm-agent-view-pilot.test.sh) pins the logic against a stand-in; only
# this guard can see a vendor change.
#
# It drives firstmate's own scripts end to end on a private tmux socket and a
# scratch firstmate home: launch, both halves of the typing guard on the real
# screens, a steer with delivery confirmation, the left-arrow detach and its
# refusal, the /exit and double Ctrl+C detaches, re-attach, interrupt, liveness
# with and without a viewer, exit, resume by attach with the session's own
# environment intact, and cleanup.
# Every session it starts is stopped and removed on any exit.
#
# The worker needs a workspace Claude Code already trusts, because a background
# session refuses an untrusted one without showing a dialog, so the guard
# borrows a detached worktree of FM_AGENT_VIEW_PILOT_LIVE_REPO (default: the
# repository holding this checkout) and removes it on exit. A fresh spawn
# refreshes that worktree from the repository's origin, as it does for every
# pooled worktree, so the run fetches that origin.
#
# Cost: four short turns on a small model (FM_AGENT_VIEW_PILOT_LIVE_MODEL,
# default haiku), plus the one small summary request the agent view itself
# makes per turn.
#
# Opt in with FM_AGENT_VIEW_PILOT_LIVE=1. Run it after every Claude Code update
# and before refreshing docs/verification/runtime-backends.md "Agent-view pilot".
set -u

if [ "${FM_AGENT_VIEW_PILOT_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_AGENT_VIEW_PILOT_LIVE=1 to run the agent-view pilot live guard against the installed Claude Code"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERSION=unknown
die() { fail "claude $VERSION: $1"; }

command -v claude >/dev/null 2>&1 || die "claude is not installed, so nothing was checked"
command -v tmux >/dev/null 2>&1 || die "tmux is not installed, so nothing was checked"
command -v jq >/dev/null 2>&1 || die "jq is not installed, so nothing was checked"
command -v lsof >/dev/null 2>&1 || die "lsof is not installed, so cleanup cannot be checked and nothing was checked"
VERSION=$(claude --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || VERSION=unknown
[ "${CLAUDE_CODE_DISABLE_AGENT_VIEW:-}" != 1 ] \
  || die "CLAUDE_CODE_DISABLE_AGENT_VIEW=1 turns the agent view off, so nothing was checked"
echo "# harness claude $VERSION"

REAL_TMUX=$(command -v tmux)
SOCKET="fm-agent-view-live-$$"
LAB=$(fm_test_tmproot fm-agent-view-live) || die "could not create a scratch directory"
LAB=$(cd "$LAB" && pwd -P)
ID="avlive$$"
TRUSTED=$(git -C "${FM_AGENT_VIEW_PILOT_LIVE_REPO:-$ROOT}" rev-parse --show-toplevel 2>/dev/null) \
  || die "FM_AGENT_VIEW_PILOT_LIVE_REPO is not a git checkout"
# A pool slot path, so the pool record a real lease leaves can sit two levels up.
WT="$LAB/pool/1/wt"
HOME_DIR="$LAB/fmhome"
META="$HOME_DIR/state/$ID.meta"
SESSION_ID=
T=

# Every background session this run started, by its exact name and worktree.
lab_sessions() {
  claude agents --json --all 2>/dev/null | jq -r --arg name "fm-$ID" --arg wt "$WT" \
    '.[] | objects | select(.kind == "background" and .name == $name and .cwd == $wt) | .id // empty' 2>/dev/null
}

cleanup_live() {
  local id
  for id in $(lab_sessions); do
    claude stop "$id" >/dev/null 2>&1 || true
    claude rm "$id" >/dev/null 2>&1 || true
  done
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  git -C "$TRUSTED" worktree remove --force "$WT" >/dev/null 2>&1 || true
  git -C "$TRUSTED" worktree prune >/dev/null 2>&1 || true
  rm -rf "/tmp/fm-$ID"
  fm_test_cleanup
}
# An interrupted run still stops its sessions before its scratch files go.
trap cleanup_live EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Lab shells look like a fleet window's, not like this test's caller: no outer
# tmux client, no rc files, and none of a calling Claude Code session's own
# runtime variables. The real HOME stays, because it holds the credentials.
unset TMUX TMUX_PANE GOTMPDIR TRACEPARENT FM_AGENT_VIEW_TASK FM_TRACE_CONTEXT \
  CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH CLAUDE_CODE_SESSION_ID \
  CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_MESSAGING_SOCKET \
  CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION CLAUDE_EFFORT CLAUDE_PID AI_AGENT
mkdir -p "$LAB/shim" "$LAB/bin" "$LAB/pool/1" "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" -f /dev/null "\$@"
SH
chmod +x "$LAB/shim/tmux"
fm_fake_treehouse "$LAB/bin"
# The shared no-mistakes daemon is never asked anything about this lab.
cat > "$LAB/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$LAB/bin/no-mistakes"
export PATH="$LAB/shim:$LAB/bin:$PATH"

git -C "$TRUSTED" worktree add --quiet --detach "$WT" HEAD || die "could not borrow a worktree from $TRUSTED"
printf 'claude\n' > "$HOME_DIR/config/crew-harness"
printf 'on\n' > "$HOME_DIR/config/agent-view-workers"
printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
printf '%s off\n' "$$" > "$HOME_DIR/state/.trace-context-effective"
touch "$HOME_DIR/state/.last-watcher-beat"
cat > "$HOME_DIR/data/$ID/brief.md" <<'EOF'
# Live guard worker

This is an automated check of how firstmate supervises you.
Do not read, run, or change anything, and do not use any tools.
Reply with the single word ready.
EOF
tmux new-session -d -s lab -n w0 "bash --norc --noprofile" || die "could not start the private tmux server"
tmux set-option -g default-command "bash --norc --noprofile"

fm_env() {  # <command...>
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" "$@"
}

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || die "the tmux adapter did not load"
fm_agent_view_source || die "the pilot library did not load"

wait_for() {  # <seconds> <command...>
  local limit=$(($1 * 2)) i=0
  shift
  until "$@"; do
    i=$((i + 1))
    [ "$i" -lt "$limit" ] || return 1
    sleep 0.5
  done
}

viewer_reads() { [ "$(fm_agent_view_viewer_state "$T" "$ID" "$SESSION_ID")" = "$1" ]; }
session_reads() { [ "$(fm_agent_view_session_state "$SESSION_ID" "$WT")" = "$1" ]; }
leader_kind() { local l; l=$(fm_agent_view_foreground "$T" | head -1); fm_agent_view_client_kind "${l#* }"; }
leader_is() { [ "$(leader_kind)" = "$1" ]; }
turn_ended() { [ -e "$HOME_DIR/state/$ID.turn-ended" ]; }
window_at_shell() { [ "$(fm_backend_tmux_agent_state "$T")" = dead ]; }
session_busy() {
  claude agents --json --all 2>/dev/null \
    | jq -e --arg id "$SESSION_ID" '.[] | objects | select(.id == $id) | (.status // "") != "idle"' >/dev/null 2>&1
}
screen() { tmux capture-pane -p -t "$T"; }
history_has() { tmux capture-pane -p -S -2000 -t "$T" | grep -F "$1" >/dev/null; }
conversation() {
  claude agents --json --all 2>/dev/null \
    | jq -r --arg id "$SESSION_ID" '.[] | objects | select(.id == $id) | .sessionId // empty' 2>/dev/null
}
steer() {  # <text>
  local out
  rm -f "$HOME_DIR/state/$ID.turn-ended"
  out=$(fm_env "$ROOT/bin/fm-send.sh" "$ID" "$1" 2>&1) || die "a steer was not confirmed delivered: $out"
}

# 1. Launch: a named background session, its id read back and recorded.
out=$(fm_env "$ROOT/bin/fm-spawn.sh" "$ID" "$TRUSTED" --mode local-only --yolo off \
  --model "${FM_AGENT_VIEW_PILOT_LIVE_MODEL:-haiku}" 2>&1) || die "the pilot launch failed: $out"
SESSION_ID=$(fm_meta_get "$META" agent_view_id)
fm_agent_view_id_valid "$SESSION_ID" || die "the launch recorded '$SESSION_ID' instead of a session id: $out"
case "$out" in *"agent_view=$SESSION_ID"*) ;; *) die "the launch line does not name session $SESSION_ID: $out" ;; esac
T=$(fm_meta_get "$META" window)
row=$(claude agents --json --all | jq -c --arg id "$SESSION_ID" '.[] | objects | select(.id == $id)')
[ "$(printf '%s' "$row" | jq -r '.kind + " " + .name + " " + .cwd')" = "background fm-$ID $WT" ] \
  || die "the session list does not show background session fm-$ID working in the worktree: $row"
session_reads alive || die "a freshly launched session must read alive"
# The record a real treehouse lease leaves, which a relaunch proves ownership by.
: > "$LAB/pool/treehouse-state.lock"
printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"%s"}]}\n' \
  "$WT" "$(fm_meta_get "$META" lease_holder)" > "$LAB/pool/treehouse-state.json"
echo "ok - launch: claude --bg named the session after its task, and its id was read back, recorded, and listed in the worktree"

# 2. The typing guard reads the real viewer as this worker's session, and the
#    session's hooks fire with the pilot's marker.
wait_for 60 viewer_reads session || die "the attached viewer never read session; screen:"$'\n'"$(screen)"
leader_is "viewer:$SESSION_ID" || die "the viewer's process does not read as 'claude attach $SESSION_ID'"
screen | fm_agent_view_screen_shows_session "$ID" || die "the viewer's screen does not show the fm-$ID composer border"
[ "$(fm_task_agent_alive "$META" tmux "$T")" = alive ] || die "a running session with its viewer attached must read alive"
wait_for 180 turn_ended || die "the first turn never ended through the gated Stop hook; screen:"$'\n'"$(screen)"
echo "ok - guard: the viewer's process, its name border, and a clean footer read session, and the gated hooks fire"

# 3. A steer: fm-send confirms the submit, the session shows it as a user turn,
#    and the session's gated Stop hook proves a turn ran on it. What the model
#    answers is never checked, because that is the model's, not the pilot's.
steer "Reply with the single word steered (live-guard steer one)."
wait_for 180 turn_ended || die "the steered turn never ended; screen:"$'\n'"$(screen)"
history_has "(live-guard steer one)" || die "the steer is not in the session's conversation; screen:"$'\n'"$(screen)"
echo "ok - steer: fm-send's verified submit reached the session and a turn ran on it"

# 4. The left arrow turns the viewer into the agent view; both guard halves
#    must refuse it, and nothing may be typed there.
tmux send-keys -t "$T" Left
wait_for 20 leader_is agents || die "the left arrow did not turn the viewer into the agent view (leader: $(leader_kind))"
viewer_reads detached || die "the agent view must read detached"
if screen | fm_agent_view_screen_shows_session "$ID"; then
  die "the agent view's screen must fail the screen half of the guard; screen:"$'\n'"$(screen)"
fi
if out=$(fm_env "$ROOT/bin/fm-send.sh" "$ID" "this must never be typed" 2>&1); then
  die "a steer into the agent view was not refused: $out"
fi
case "$out" in *"nothing was sent"*) ;; *) die "the refusal does not say nothing was sent: $out" ;; esac
[ "$(lab_sessions | wc -l | tr -d ' ')" = 1 ] || die "the agent view must not have started another session"
echo "ok - detach: the left arrow re-executes the viewer as the agent view, and the guard refuses to type there"

# 5. Re-attach: the running session is shown again, and nothing durable changes.
out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" relaunch 2>&1) || die "re-attach failed: $out"
case "$out" in *"agent_view=$SESSION_ID via=reattach"*) ;; *) die "a running session was not simply re-attached: $out" ;; esac
viewer_reads session || die "re-attach did not leave the window showing the session"
echo "ok - re-attach: the window shows the same session again"

# 6. /exit and a double Ctrl+C detach the viewer the same way while the session
#    keeps running, and Escape then leaves the agent view for the shell.
tmux send-keys -t "$T" -l /exit
sleep 0.5
tmux send-keys -t "$T" Enter
wait_for 20 leader_is agents || die "/exit did not turn the viewer into the agent view (leader: $(leader_kind))"
session_reads alive || die "/exit in a viewer must leave the session running"
out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" relaunch 2>&1) || die "re-attach after /exit failed: $out"
tmux send-keys -t "$T" C-c
sleep 0.3
tmux send-keys -t "$T" C-c
wait_for 20 leader_is agents || die "a double Ctrl+C did not turn the viewer into the agent view (leader: $(leader_kind))"
session_reads alive || die "a double Ctrl+C in a viewer must leave the session running"
tmux send-keys -t "$T" Escape
wait_for 20 window_at_shell || die "Escape did not leave the agent view for the shell (leader: $(leader_kind))"
out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" relaunch 2>&1) || die "re-attach from the shell failed: $out"
case "$out" in *"via=reattach"*) ;; *) die "a detached running session was not re-attached: $out" ;; esac
echo "ok - detach paths: /exit and a double Ctrl+C also leave the session running in the agent view, and Escape leaves that for the shell"

# 7. Interrupt a busy turn through the viewer.
steer "Count from 1 to 400, one number per line, then stop."
wait_for 20 session_busy || echo "# note: the session never read busy before the interrupt; interrupting it idle"
out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" interrupt 2>&1) || die "interrupt failed: $out"
case "$out" in *verified=agent-alive*) ;; *) die "interrupt did not prove the session still running: $out" ;; esac
wait_for 20 viewer_reads session || die "the viewer left its session after an interrupt; screen:"$'\n'"$(screen)"
echo "ok - interrupt: Escape through the viewer leaves the session running and shown"

# 8. Liveness without a viewer comes from the session list, not the window.
fm_agent_view_release_window "$T" || die "the viewer could not be released"
[ "$(fm_backend_agent_alive tmux "$T")" = dead ] || die "divergence lost: the bare window must read dead"
[ "$(fm_task_agent_alive "$META" tmux "$T")" = alive ] || die "a running session with no viewer must read alive"
out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" relaunch 2>&1) || die "re-attach from the shell failed: $out"
case "$out" in *"via=reattach"*) ;; *) die "a viewer-less running session was not re-attached: $out" ;; esac
echo "ok - liveness: the session reads alive with no viewer, and a relaunch re-attaches it"

# 9. Exit stops the session by id and leaves it resumable; relaunch resumes the
#    same conversation, and its settings environment still gates its hooks.
before=$(conversation)
[ -n "$before" ] || die "the session list does not name session $SESSION_ID's conversation"
out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" exit 2>&1) || die "exit failed: $out"
printf '%s\n' "$out" | grep -q "^stopped $ID " || die "exit did not report the session stopped: $out"
session_reads dead || die "exit must leave the session stopped and resumable"
[ "$(fm_backend_tmux_agent_state "$T")" = dead ] || die "exit must leave the window at its shell"
out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" relaunch 2>&1) || die "resume failed: $out"
case "$out" in *"agent_view=$SESSION_ID via=resume"*) ;; *) die "the stopped session was not resumed by attach: $out" ;; esac
session_reads alive || die "resume must bring the same session back"
wait_for 60 viewer_reads session || die "the resumed viewer never read session; screen:"$'\n'"$(screen)"
[ "$(conversation)" = "$before" ] || die "resume started conversation '$(conversation)' instead of continuing '$before'"
steer "Reply with the single word resumed (live-guard steer two)."
wait_for 180 turn_ended || die "the resumed session's gated hooks did not fire, so its settings environment did not survive the stop"
history_has "(live-guard steer two)" || die "the steer after resume is not in the session's conversation; screen:"$'\n'"$(screen)"
echo "ok - exit and resume: claude stop, then claude attach resumes the same conversation with its environment intact"

# 10. Cleanup stops and removes the session, so the agent view lists only live work.
out=$(fm_env "$ROOT/bin/fm-teardown.sh" "$ID" --force 2>&1) || die "cleanup failed: $out"
session_reads missing || die "cleanup must remove the session from the session list"
[ -z "$(lab_sessions)" ] || die "cleanup left a session named fm-$ID behind"
echo "ok - cleanup: the session is stopped and removed"
