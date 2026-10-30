#!/usr/bin/env bash
# tests/fm-agent-view-pilot.test.sh - portable regression for the opt-in
# agent-view pilot (bin/fm-agent-view-lib.sh), the mode where a claude crewmate
# runs as a Claude Code background session and its tmux window only views it.
#
# It runs REAL processes in a REAL tmux server on a private socket, with a
# stand-in `claude` CLI backed by one JSON session list, so it needs no harness
# and no credentials and runs everywhere CI runs tmux. The live counterpart,
# which drives the real Claude Code, is
# tests/fm-agent-view-pilot-live-e2e.test.sh.
#
# What it pins:
#   1. The typing guard is a conjunction of three independent signals - the
#      window's foreground job is `claude attach <id>` for this exact session,
#      the screen shows the session's own name in its composer border, and no
#      agent-view footer is on screen. Each case drives the signals apart and
#      asserts the other two still agree, so losing any ONE signal is proven to
#      refuse, and no case can go quietly vacuous.
#   2. The inputs that would take a viewer off its session are refused even
#      while it shows the session, and a refusal types nothing.
#   3. Liveness and the "no agent owns this task" proof come from the session
#      list by id, never from the window.
#   4. The scripts: fm-spawn launches, records, gates hooks, and attaches, and a
#      launch Claude Code refuses leaves no session id; fm-send refuses a
#      detached viewer; fm-control re-attaches, interrupts, stops, and relaunches
#      by every plan (resume, restart, fresh); fm-teardown stops and removes the
#      session; and with the switch absent or off the launch is byte-identical
#      to an ordinary one.
#
# The stand-in's viewer is a /bin/bash whose argv is `claude attach <id>`, so its
# argv names claude while `ps -o comm=` names bash: the tmux classifier's
# sources diverge here, and the cases below assert only verdicts, never which
# source carried them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
[ -x /bin/bash ] || { echo "skip: /bin/bash not found"; exit 0; }
command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
LAB=$(fm_test_tmproot fm-agent-view-pilot)
mkdir -p "$LAB"
LAB=$(cd "$LAB" && pwd -P)
SOCKET="fm-agent-view-$$"
TASK_TMPS=()

cleanup_lab() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  local d
  for d in "${TASK_TMPS[@]+"${TASK_TMPS[@]}"}"; do
    case "$d" in /tmp/fm-*) rm -rf -- "$d" ;; esac
  done
  fm_test_cleanup
}
trap cleanup_lab EXIT

# Hermetic shells: a scratch HOME (no rc files), no outer tmux client, no
# ambient Claude Code store, and the stand-in first on PATH - so nothing here
# can ever reach a real Claude Code or the host's tmux sessions.
mkdir -p "$LAB/home" "$LAB/shim" "$LAB/bin" "$LAB/claude"
export HOME="$LAB/home"
unset TMUX TMUX_PANE CLAUDE_CONFIG_DIR CLAUDECODE FM_TRACE_CONTEXT GOTMPDIR TRACEPARENT FM_AGENT_VIEW_TASK
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" -f /dev/null "\$@"
SH
chmod +x "$LAB/shim/tmux"
fm_fake_treehouse "$LAB/bin"
cat > "$LAB/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$LAB/bin/no-mistakes"
cp -p "$LAB/bin/no-mistakes" "$LAB/bin/agent-presence"
export FAKE_CLAUDE_DIR="$LAB/claude"
printf '[]\n' > "$FAKE_CLAUDE_DIR/sessions.json"

# The stand-in Claude Code CLI. Every row lives in sessions.json in the shape
# `claude agents --json --all` prints; a row with a numeric pid is running.
#   --bg ...        records a background session named --name in $PWD and
#                   prints the `backgrounded · <id> · <name>` line.
#   agents --json   prints the list; agents alone paints the agent view.
#   attach <id>     resumes a stopped session, then paints it until it stops.
#   stop / rm       stop or remove one session by id.
# A viewer and the agent view repaint from a bash re-executed with exactly the
# argv the real CLI's process carries, `claude attach <id>` or `claude agents`.
cat > "$LAB/bin/claude" <<'SH'
#!/bin/bash
set -u
D=$FAKE_CLAUDE_DIR
LIST="$D/sessions.json"
put() { jq -c "$@" "$LIST" > "$LIST.tmp" && mv -f "$LIST.tmp" "$LIST"; }
row() { jq -c --arg id "$1" '.[] | select(.id == $id)' "$LIST"; }
running() { [ "$(jq -r --arg id "$1" '.[] | select(.id == $id) | .pid | type' "$LIST")" = number ]; }
paint_loop() {  # <screen-file-or-default> <id-or-empty>
  local last= sum
  while :; do
    if [ -n "$2" ] && ! running "$2"; then
      printf '\nSession %s has exited\n' "$2"
      exit 0
    fi
    sum=$(cksum < "$1")
    if [ "$sum" != "$last" ]; then
      printf '\033[H\033[2J'
      cat "$1"
      last=$sum
    fi
    sleep 0.2
  done
}
paint_as() {  # <argv> <screen-file> <id-or-empty>
  FAKE_CLAUDE_SCREEN=$2 FAKE_CLAUDE_ID=$3 exec -a "$1" /bin/bash < "$0"
}
[ -z "${FAKE_CLAUDE_SCREEN:-}" ] || paint_loop "$FAKE_CLAUDE_SCREEN" "$FAKE_CLAUDE_ID"
printf '%s\n' "$*" >> "$D/calls.log"
case "${1:-}" in
  --bg)
    shift
    name= settings= prompt=
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) name=$2; shift 2 ;;
        --settings) settings=$2; shift 2 ;;
        --model|--effort) shift 2 ;;
        --*) shift ;;
        *) prompt=$1; shift ;;
      esac
    done
    if [ -e "$D/refuse-launch" ]; then
      echo "Workspace not trusted: run claude here once and accept the trust dialog"
      exit 1
    fi
    id=$(cat "$D/next-id")
    printf '%s' "$settings" > "$D/$id.settings"
    printf '%s' "$prompt" > "$D/$id.prompt"
    env > "$D/$id.launch-env"
    put --arg id "$id" --arg name "$name" --arg cwd "$PWD" \
      '. + [{id: $id, name: $name, cwd: $cwd, kind: "background", pid: 4242, state: "working"}]'
    printf 'backgrounded · %s · %s\n  claude attach %s   open it here\n' "$id" "$name" "$id"
    ;;
  agents)
    if [ "${2:-}" = --json ]; then
      [ ! -e "$D/list-fails" ] || exit 1
      cat "$LIST"
      exit 0
    fi
    paint_as "claude agents" "$D/agents-screen" ''
    ;;
  attach)
    id=${2:-}
    [ -n "$(row "$id")" ] || { echo "No job matching '$id'."; exit 1; }
    env > "$D/$id.attach-env"
    running "$id" || put --arg id "$id" 'map(if .id == $id then .pid = 4343 else . end)'
    screen="$D/screen-$id"
    if [ ! -f "$screen" ]; then
      name=$(row "$id" | jq -r .name)
      printf ' * Claude Code (stand-in)\n\n> working on the brief\n\n───────────────────────────── %s ─\n> \n────────────────────────────────────────\n  bypass permissions on · ← for agents\n' "$name" > "$screen"
    fi
    paint_as "claude attach $id" "$screen" "$id"
    ;;
  stop)
    [ -n "$(row "${2:-}")" ] || { echo "No job matching '${2:-}'."; exit 1; }
    put --arg id "$2" 'map(if .id == $id then del(.pid) | .state = "done" else . end)'
    echo "stopped $2"
    ;;
  rm)
    [ -n "$(row "${2:-}")" ] || { echo "No job matching '${2:-}'."; exit 1; }
    put --arg id "$2" 'map(select(.id != $id))'
    echo "removed $2"
    ;;
  *)
    echo "stand-in claude: unexpected call: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$LAB/bin/claude"
printf ' Agents\n\n  * fm-other   working\n\n enter to return · space to reply · ctrl+x to delete · ? for shortcuts\n' \
  > "$FAKE_CLAUDE_DIR/agents-screen"

export PATH="$LAB/shim:$LAB/bin:$PATH"
[ "$(command -v claude)" = "$LAB/bin/claude" ] || fail "the stand-in claude must shadow every real one"

tmux new-session -d -s lab -n w0 "bash --norc --noprofile"
tmux set-option -g default-command "bash --norc --noprofile"
tmux set-option -g remain-on-exit off

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "tmux adapter did not load"
fm_agent_view_source || fail "pilot library did not load"
export FM_AGENT_VIEW_CLAUDE_TIMEOUT=10

# --- helpers ------------------------------------------------------------------

wait_for() {  # <seconds> <command...>
  local limit=$1 i=0
  shift
  until "$@"; do
    i=$((i + 1))
    [ "$i" -lt $((limit * 10)) ] || return 1
    sleep 0.1
  done
}

screen_has() {  # <target> <text>
  tmux capture-pane -p -t "$1" 2>/dev/null | grep -F -- "$2" >/dev/null
}

window_at_shell() {  # <target>
  [ "$(fm_backend_tmux_agent_state "$1")" = dead ]
}

# end_foreground: Ctrl+C the window's foreground job until the window is back at
# its shell, resending it each second so a loaded machine that loses or delays
# one does not fail the case.
end_foreground() {  # <target> <what>
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    tmux send-keys -t "$1" C-c
    wait_for 1 window_at_shell "$1" && return 0
  done
  fail "$2 did not exit on Ctrl+C"
}

new_window() {  # <name> [dir]
  tmux new-window -d -t lab: -n "$1" -c "${2:-$LAB}"
  wait_for 15 window_at_shell "lab:$1" || fail "window $1 did not reach its shell"
}

type_line() {  # <target> <line>
  tmux send-keys -t "$1" -l "$2"
  tmux send-keys -t "$1" Enter
}

leader_kind() {  # <target>
  local leader
  leader=$(fm_agent_view_foreground "$1")
  fm_agent_view_client_kind "${leader#* }"
}

add_session() {  # <id> <name> <cwd> [pid|stopped] [kind]
  local pid=${4:-4242} kind=${5:-background}
  if [ "$pid" = stopped ]; then
    jq -c --arg id "$1" --arg name "$2" --arg cwd "$3" --arg kind "$kind" \
      '. + [{id: $id, name: $name, cwd: $cwd, kind: $kind, state: "done"}]' \
      "$FAKE_CLAUDE_DIR/sessions.json" > "$FAKE_CLAUDE_DIR/s.tmp"
  else
    jq -c --arg id "$1" --arg name "$2" --arg cwd "$3" --arg kind "$kind" --argjson pid "$pid" \
      '. + [{id: $id, name: $name, cwd: $cwd, kind: $kind, pid: $pid, state: "working"}]' \
      "$FAKE_CLAUDE_DIR/sessions.json" > "$FAKE_CLAUDE_DIR/s.tmp"
  fi
  mv -f "$FAKE_CLAUDE_DIR/s.tmp" "$FAKE_CLAUDE_DIR/sessions.json"
}

reset_sessions() {
  printf '[]\n' > "$FAKE_CLAUDE_DIR/sessions.json"
}

session_running() {  # <id>
  [ "$(jq -r --arg id "$1" '.[] | select(.id == $id) | .pid | type' "$FAKE_CLAUDE_DIR/sessions.json")" = number ]
}

# --- 1. the typing guard: three signals, each one alone refuses ------------------

test_viewer_guard_signals() {
  local t=lab:guard id=0a1b2c3d other=9f8e7d6c leader
  reset_sessions
  add_session "$id" fm-g1 "$LAB"
  add_session "$other" fm-g2 "$LAB"
  new_window guard
  type_line "$t" "claude attach $id"
  wait_for 15 screen_has "$t" " fm-g1 ─" || fail "the stand-in viewer did not paint its session"
  [ "$(fm_agent_view_viewer_state "$t" g1 "$id")" = session ] \
    || fail "a viewer showing the worker's own session must read session"
  leader=$(fm_agent_view_foreground "$t")
  [ "$(ps -o comm= -p "${leader%% *}" | tr -d ' ')" != claude ] \
    || echo "note: the kernel names the stand-in claude here, so the source divergence is not exercised on this platform"

  # Signal 1 lost: the screen turns into the agent view while the process is
  # still `claude attach <id>`.
  cp "$FAKE_CLAUDE_DIR/agents-screen" "$FAKE_CLAUDE_DIR/screen-$id"
  printf '───────────────────────────── fm-g1 ─\n' >> "$FAKE_CLAUDE_DIR/screen-$id"
  printf ' enter to return · space to reply\n' >> "$FAKE_CLAUDE_DIR/screen-$id"
  wait_for 15 screen_has "$t" "space to reply" || fail "the agent-view footer did not paint"
  [ "$(leader_kind "$t")" = "viewer:$id" ] || fail "divergence: the foreground must still be the viewer of $id"
  screen_has "$t" " fm-g1 ─" || fail "divergence: the name border must still be on screen"
  [ "$(fm_agent_view_viewer_state "$t" g1 "$id")" = detached ] \
    || fail "an agent-view footer alone must make the guard refuse"

  # Signal 2 lost: the session screen carries another session's name.
  printf ' * Claude Code (stand-in)\n\n───────────────────────────── fm-g2 ─\n> \n────\n' > "$FAKE_CLAUDE_DIR/screen-$id"
  wait_for 15 screen_has "$t" " fm-g2 ─" || fail "the other name did not paint"
  [ "$(leader_kind "$t")" = "viewer:$id" ] || fail "divergence: the foreground must still be the viewer of $id"
  tmux capture-pane -p -t "$t" | fm_agent_view_screen_shows_session g2 \
    || fail "divergence: the screen itself must be a clean session screen"
  [ "$(fm_agent_view_viewer_state "$t" g1 "$id")" = detached ] \
    || fail "a session screen without the worker's own name alone must make the guard refuse"

  # Signal 3 lost: the screen shows the worker's name, but the process is a
  # viewer of a different session.
  end_foreground "$t" "the stand-in viewer"
  printf ' * Claude Code (stand-in)\n\n───────────────────────────── fm-g1 ─\n> \n────\n' > "$FAKE_CLAUDE_DIR/screen-$other"
  type_line "$t" "clear; claude attach $other"
  wait_for 15 screen_has "$t" " fm-g1 ─" || fail "the other viewer did not paint"
  tmux capture-pane -p -t "$t" | fm_agent_view_screen_shows_session g1 \
    || fail "divergence: the screen must show the worker's own name"
  [ "$(leader_kind "$t")" = "viewer:$other" ] || fail "divergence: the foreground must be the other session's viewer"
  [ "$(fm_agent_view_viewer_state "$t" g1 "$id")" = detached ] \
    || fail "a viewer of another session alone must make the guard refuse"

  # The agent view itself, a shell, and a missing window.
  end_foreground "$t" "the other viewer"
  [ "$(fm_agent_view_viewer_state "$t" g1 "$id")" = detached ] || fail "a shell must read detached"
  type_line "$t" "claude agents"
  wait_for 15 screen_has "$t" "enter to return" || fail "the agent view did not paint"
  [ "$(leader_kind "$t")" = agents ] || fail "the agent view's process must classify as the agent view"
  [ "$(fm_agent_view_viewer_state "$t" g1 "$id")" = detached ] || fail "the agent view must read detached"
  [ "$(fm_agent_view_viewer_state lab:no-such-window g1 "$id")" = missing ] || fail "a missing window must read missing"
  tmux kill-window -t "$t"
  rm -f "$FAKE_CLAUDE_DIR/screen-$id" "$FAKE_CLAUDE_DIR/screen-$other"
  pass "typing guard: each of the three signals alone refuses, and only all three together read session"
}

# --- 2. input that would leave the session, and refusals that type nothing ------

test_input_guard() {
  local t=lab:input id=1a2b3c4d out rc
  reset_sessions
  add_session "$id" fm-i1 "$LAB"
  new_window input
  type_line "$t" "claude attach $id"
  wait_for 15 screen_has "$t" " fm-i1 ─" || fail "the stand-in viewer did not paint"
  fm_agent_view_input_guard i1 "$id" "$t" key Escape 2>/dev/null || fail "Escape to a shown session must pass"
  fm_agent_view_input_guard i1 "$id" "$t" key Enter 2>/dev/null || fail "Enter to a shown session must pass"
  fm_agent_view_input_guard i1 "$id" "$t" text "please continue" 2>/dev/null || fail "a message to a shown session must pass"
  for key in Left C-c C-z BTab; do
    out=$(fm_agent_view_input_guard i1 "$id" "$t" key "$key" 2>&1) && fail "key $key must be refused"
    assert_contains "$out" "nothing was sent" "the $key refusal should say nothing was sent"
  done
  for cmd in /exit /quit "/bg now" /background; do
    out=$(fm_agent_view_input_guard i1 "$id" "$t" text "$cmd" 2>&1) && fail "'$cmd' must be refused"
    assert_contains "$out" "bin/fm-control.sh i1 exit" "the '$cmd' refusal should name the control plane"
  done
  out=$(fm_agent_view_input_guard i1 pending "$t" text hi 2>&1) && fail "a pending id must be refused"
  assert_contains "$out" "in flight" "the pending refusal should say the launch may be in flight"
  end_foreground "$t" "the viewer"
  out=$(fm_agent_view_input_guard i1 "$id" "$t" text hi 2>&1)
  rc=$?
  expect_code 1 "$rc" "a message to a detached window"
  assert_contains "$out" "relaunch" "the detached refusal should name the re-attach path"
  tmux kill-window -t "$t"
  pass "input guard: keys and commands that leave the session are refused, and so is any input to a detached window"
}

# --- 3. release and attach -------------------------------------------------------

test_release_and_attach() {
  local t=lab:rel id=2a3b4c5d rc
  reset_sessions
  add_session "$id" fm-r1 "$LAB"
  new_window rel
  fm_agent_view_release_window "$t" || fail "a window at its shell needs no release"
  type_line "$t" "claude attach $id"
  wait_for 15 screen_has "$t" " fm-r1 ─" || fail "the viewer did not paint"
  fm_agent_view_release_window "$t" || fail "a viewer must be released"
  window_at_shell "$t" || fail "the released window must be back at its shell"
  session_running "$id" || fail "releasing a viewer must never stop its session"
  type_line "$t" "claude agents"
  wait_for 15 screen_has "$t" "enter to return" || fail "the agent view did not paint"
  fm_agent_view_release_window "$t" || fail "the agent view must be released"
  window_at_shell "$t" || fail "the window must be back at its shell after the agent view"
  type_line "$t" "(exec -a claude bash -c 'sleep 30; :')"
  wait_for 15 test "$(fm_backend_tmux_agent_state "$t")" = alive || fail "the decoy did not start"
  fm_agent_view_release_window "$t" && fail "a non-viewer foreground must not be released"
  [ "$(fm_backend_tmux_agent_state "$t")" = alive ] || fail "a refused release must signal nothing"
  end_foreground "$t" "the decoy"

  # attach: a line left half-typed in the shell is cleared, never run.
  tmux send-keys -t "$t" -l "touch $LAB/half-typed"
  fm_agent_view_attach_window "$t" r1 "$id" 10 || fail "attach from the shell must reach session"
  [ "$(fm_agent_view_viewer_state "$t" r1 "$id")" = session ] || fail "the attached viewer must read session"
  [ ! -e "$LAB/half-typed" ] || fail "attach must clear a half-typed shell line instead of running it"
  rc=0
  fm_agent_view_attach_window "$t" r1 "$id" 1 || rc=$?
  expect_code 1 "$rc" "attach into a window that is not at its shell"
  [ "$(pgrep -fc "claude attach $id")" = 1 ] || fail "a refused attach must type nothing"
  tmux kill-window -t "$t"
  pass "release ends only viewer clients and never the session; attach clears the shell line and refuses a busy window"
}

# --- 4. session state from the list, by id ----------------------------------------

test_session_state() {
  local wt="$LAB/wt-state" link="$LAB/wt-link" id=3a4b5c6d other=4a5b6c7d
  mkdir -p "$wt"
  ln -sfn "$wt" "$link"
  reset_sessions
  [ "$(fm_agent_view_session_state "$id" "$wt")" = missing ] || fail "an absent session must read missing"
  add_session "$id" fm-s1 "$wt"
  [ "$(fm_agent_view_session_state "$id" "$wt")" = alive ] || fail "a running session must read alive"
  [ "$(fm_agent_view_session_state "$id" "$link")" = alive ] || fail "a worktree recorded through a symlink must still match"
  reset_sessions
  add_session "$id" fm-s1 "$wt" stopped
  [ "$(fm_agent_view_session_state "$id" "$wt")" = dead ] || fail "a stopped session must read dead"
  add_session "$other" stray "$wt"
  [ "$(fm_agent_view_session_state "$id" "$wt")" = ambiguous ] \
    || fail "another running session in the same copy must make a stopped worker ambiguous"
  [ "$(fm_agent_view_session_state "$id" "$wt" own)" = dead ] \
    || fail "the own scope must judge the session alone"
  reset_sessions
  add_session "$other" stray "$wt"
  [ "$(fm_agent_view_session_state "$id" "$wt")" = ambiguous ] \
    || fail "a vanished worker with another session in its copy must be ambiguous, never missing"
  [ "$(fm_agent_view_session_state "$id" "$wt" own)" = missing ] || fail "the own scope ignores other sessions"
  reset_sessions
  add_session "$id" fm-s1 "$wt" 4242 interactive
  [ "$(fm_agent_view_session_state "$id" "$wt")" = ambiguous ] || fail "an interactive row is not a pilot session"
  reset_sessions
  add_session "$id" fm-s1 "$LAB/elsewhere"
  [ "$(fm_agent_view_session_state "$id" "$wt")" = ambiguous ] || fail "a session in another copy is not this worker"
  reset_sessions
  add_session "$id" fm-s1 "$wt"
  add_session "$id" fm-s1 "$wt"
  [ "$(fm_agent_view_session_state "$id" "$wt")" = unreadable ] || fail "a duplicated id must read unreadable"
  reset_sessions
  add_session "$id" fm-s1 "$wt"
  : > "$FAKE_CLAUDE_DIR/list-fails"
  [ "$(fm_agent_view_session_state "$id" "$wt")" = unreadable ] || fail "an unreadable list must read unreadable"
  fm_agent_view_named_ids fm-s1 "$wt" >/dev/null && fail "named ids must fail on an unreadable list"
  rm -f "$FAKE_CLAUDE_DIR/list-fails"
  printf 'not json\n' > "$FAKE_CLAUDE_DIR/sessions.json"
  [ "$(fm_agent_view_session_state "$id" "$wt")" = unreadable ] || fail "a malformed list must read unreadable"
  [ "$(fm_agent_view_session_state pending "$wt")" = unreadable ] || fail "a pending id must read unreadable"
  reset_sessions
  add_session "$id" fm-s1 "$wt"
  add_session "$other" fm-s1 "$LAB/elsewhere"
  add_session 5a6b7c8d fm-s1 "$wt" 4242 interactive
  [ "$(fm_agent_view_named_ids fm-s1 "$wt")" = "$id" ] || fail "named ids must keep only background sessions in this copy"
  pass "session state: alive, dead, missing, ambiguous, and unreadable come from the list by id, with the own scope for re-leased copies"
}

# --- 5. the small contracts -------------------------------------------------------

test_small_contracts() {
  local cfg="$LAB/cfg" out settings
  mkdir -p "$cfg"
  [ "$(fm_agent_view_switch "$cfg")" = off ] || fail "an absent switch is off"
  printf 'on\n' > "$cfg/agent-view-workers"
  [ "$(fm_agent_view_switch "$cfg")" = on ] || fail "on is on"
  printf '  off \n' > "$cfg/agent-view-workers"
  [ "$(fm_agent_view_switch "$cfg")" = off ] || fail "surrounding whitespace is ignored"
  : > "$cfg/agent-view-workers"
  [ "$(fm_agent_view_switch "$cfg")" = invalid ] || fail "an empty switch file is invalid"
  printf 'yes\n' > "$cfg/agent-view-workers"
  [ "$(fm_agent_view_switch "$cfg")" = invalid ] || fail "anything but on or off is invalid"

  printf 'backgrounded · 0123abcd · fm-p1\n  claude attach 0123abcd\n' > "$LAB/launch.out"
  [ "$(fm_agent_view_parse_launch "$LAB/launch.out" p1)" = 0123abcd ] || fail "the launch line must yield its id"
  fm_agent_view_parse_launch "$LAB/launch.out" p2 >/dev/null && fail "a launch naming another task must not yield an id"
  printf 'backgrounded · 0123ABCD · fm-p1\n' > "$LAB/launch.out"
  fm_agent_view_parse_launch "$LAB/launch.out" p1 >/dev/null && fail "a malformed id must not be accepted"

  settings=$(fm_agent_view_settings_json p1 /tmp/fm-p1/gotmp '')
  [ "$(printf '%s' "$settings" | jq -r '.env | [.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION, .GOTMPDIR, .FM_AGENT_VIEW_TASK] | join(" ")')" = "false /tmp/fm-p1/gotmp p1" ] \
    || fail "the settings must carry the prompt-suggestion switch, GOTMPDIR, and the hook marker"
  [ "$(printf '%s' "$settings" | jq -r '.env | has("TRACEPARENT") and .TRACEPARENT == ""')" = true ] \
    || fail "with trace context off the settings must blank TRACEPARENT rather than inherit one"

  out=$(env -u FM_AGENT_VIEW_TASK sh -c "$(fm_agent_view_hook_gate p1)echo ran")
  [ -z "$out" ] || fail "a gated hook must do nothing outside the worker's session"
  out=$(FM_AGENT_VIEW_TASK=p2 sh -c "$(fm_agent_view_hook_gate p1)echo ran")
  [ -z "$out" ] || fail "a gated hook must do nothing in another worker's session"
  out=$(FM_AGENT_VIEW_TASK=p1 sh -c "$(fm_agent_view_hook_gate p1)echo ran")
  [ "$out" = ran ] || fail "a gated hook must run in the worker's own session"

  [ "$(fm_agent_view_client_kind "claude attach 0123abcd")" = viewer:0123abcd ] || fail "claude attach <id> is a viewer"
  [ "$(fm_agent_view_client_kind "/opt/bin/claude attach 0123abcd")" = viewer:0123abcd ] \
    || fail "an installed path whose basename is claude is still the CLI"
  [ "$(fm_agent_view_client_kind "claude agents")" = agents ] || fail "claude agents is the agent view"
  for args in "less claude attach 0123abcd" "/bin/bash /lab/bin/claude attach 0123abcd" \
      "node /lib/claude-code/cli.js attach 0123abcd" "claude-code attach 0123abcd" \
      "claude attach 0123abcd --verbose" "claude attach pending" "claude agents --json" "claude" ""; do
    [ "$(fm_agent_view_client_kind "$args")" = other ] || fail "'$args' must not classify as a Claude Code viewer"
  done
  pass "switch, launch-line parsing, settings environment, hook gate, and client kinds"
}

# --- 6. the scripts, end to end ---------------------------------------------------

HOME_DIR="$LAB/fmhome"
PROJ_DIR="$LAB/proj"
WT_DIR="$LAB/pool/1/wt"
PID_TAG=$$
ID="avp$PID_TAG"

fm_env() {  # <command...>
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=10 FM_CONTROL_LAUNCH_WAIT=20 \
    FM_AGENT_VIEW_LAUNCH_WAIT=20 FM_AGENT_VIEW_VIEWER_WAIT=10 \
    "$@"
}

write_pool_lease() {  # <label>
  : > "$LAB/pool/treehouse-state.lock"
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"%s"}]}\n' "$WT_DIR" "$1" \
    > "$LAB/pool/treehouse-state.json"
}

setup_home() {
  mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  printf '%s off\n' "$$" > "$HOME_DIR/state/.trace-context-effective"
  touch "$HOME_DIR/state/.last-watcher-beat"
  printf '# brief for %s\n\nDo the thing.\n' "$ID" > "$HOME_DIR/data/$ID/brief.md"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "task-$ID"
  TASK_TMPS+=("/tmp/fm-$ID")
}

# The pilot's session id; the fresh relaunch case replaces it.
SID=5e6f7a8b

# hooks_answer_only_the_worker: run every claude hook in the worktree's settings
# as Claude Code runs it. Without the marker, as the agent view's own processes
# fire them, none may touch the task's busy record or end its turn; with the
# worker's marker, each one writes the busy record.
hooks_answer_only_the_worker() {
  local busy="$HOME_DIR/state/$ID.busy-state" turnend="$HOME_DIR/state/$ID.turn-ended" cmd before
  local cmds=()
  while IFS= read -r cmd; do cmds+=("$cmd"); done \
    < <(jq -r '.hooks[][].hooks[].command' "$WT_DIR/.claude/settings.local.json")
  [ "${#cmds[@]}" = 4 ] || fail "expected the four claude hooks, found ${#cmds[@]}"
  [ -s "$busy" ] || fail "the spawn must arm the task's busy record"
  before=$(cat "$busy")
  for cmd in "${cmds[@]}"; do
    env -u FM_AGENT_VIEW_TASK sh -c "$cmd" </dev/null
  done
  [ "$(cat "$busy")" = "$before" ] || fail "a hook wrote the busy record without the worker's marker"
  [ ! -e "$turnend" ] || fail "a hook ended the turn without the worker's marker"
  for cmd in "${cmds[@]}"; do
    before=$(cat "$busy")
    FM_AGENT_VIEW_TASK=$ID sh -c "$cmd" </dev/null
    [ "$(cat "$busy")" != "$before" ] || fail "a hook did not write the busy record with the worker's marker: $cmd"
  done
  [ -e "$turnend" ] || fail "the Stop hook must end the turn with the worker's marker"
  rm -f "$turnend"
}

test_spawn_launches_a_pilot() {
  local out rc meta settings t f
  setup_home
  printf 'on\n' > "$HOME_DIR/config/agent-view-workers"
  printf '%s' "$SID" > "$FAKE_CLAUDE_DIR/next-id"
  reset_sessions
  out=$(fm_env "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  rc=$?
  expect_code 0 "$rc" "pilot spawn"$'\n'"$out"
  assert_contains "$out" "agent_view=$SID" "the success line should name the session"
  meta="$HOME_DIR/state/$ID.meta"
  assert_grep "agent_view_id=$SID" "$meta" "the record must carry the session id"
  t=$(sed -n 's/^window=//p' "$meta")
  settings=$(cat "$FAKE_CLAUDE_DIR/$SID.settings")
  [ "$(printf '%s' "$settings" | jq -r .env.GOTMPDIR)" = "/tmp/fm-$ID/gotmp" ] || fail "GOTMPDIR must ride the settings"
  [ "$(printf '%s' "$settings" | jq -r .env.FM_AGENT_VIEW_TASK)" = "$ID" ] || fail "the hook marker must ride the settings"
  assert_no_grep "GOTMPDIR=/tmp/fm-$ID" "$FAKE_CLAUDE_DIR/$SID.launch-env" "nothing may be exported into the window's shell for a pilot launch"
  # The window's shell carries its tmux identity (test_watch_liveness_reads_the_session
  # shows it), but neither the launch nor the viewer may pass it on: either may
  # be the client that starts the shared background service.
  for f in launch attach; do
    ! grep -q '^TMUX=' "$FAKE_CLAUDE_DIR/$SID.$f-env" || fail "the $f must not hand the background service the window's tmux server"
    ! grep -q '^TMUX_PANE=' "$FAKE_CLAUDE_DIR/$SID.$f-env" || fail "the $f must not hand the background service the window's pane"
  done
  assert_grep "--name fm-$ID" "$FAKE_CLAUDE_DIR/calls.log" "the launch must name the session after the task"
  assert_grep "--dangerously-skip-permissions" "$FAKE_CLAUDE_DIR/calls.log" "the launch must keep the permission posture"
  assert_contains "$(cat "$FAKE_CLAUDE_DIR/$SID.prompt")" "brief for $ID" "the session must start from the brief"
  hooks_answer_only_the_worker
  [ "$(fm_agent_view_viewer_state "$t" "$ID" "$SID")" = session ] || fail "the window must be left showing the session"
  write_pool_lease "$(sed -n 's/^lease_holder=//p' "$meta")"
  pass "fm-spawn: a pilot launches as a named background session, records its id, gates its hooks, and attaches its window"
}

test_send_refuses_a_detached_viewer() {
  local t out rc
  t=$(sed -n 's/^window=//p' "$HOME_DIR/state/$ID.meta")
  out=$(fm_env "$ROOT/bin/fm-send.sh" "$ID" --key Left 2>&1)
  rc=$?
  expect_code 1 "$rc" "a Left key to a pilot"
  [ "$(fm_agent_view_viewer_state "$t" "$ID" "$SID")" = session ] || fail "a refused key must leave the viewer on its session"
  end_foreground "$t" "the viewer"
  type_line "$t" "claude agents"
  wait_for 15 screen_has "$t" "enter to return" || fail "the agent view did not paint"
  out=$(fm_env "$ROOT/bin/fm-send.sh" "$ID" "touch $LAB/steer-typed" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a steer to a window showing the agent view"
  assert_contains "$out" "nothing was sent" "the refusal should say nothing was sent"
  sleep 0.5
  [ ! -e "$LAB/steer-typed" ] || fail "the refused steer must not have been typed"
  pass "fm-send: a key that leaves the session and any steer to a detached viewer are refused before typing"
}

test_control_reattach_interrupt_exit() {
  local t out rc before
  t=$(sed -n 's/^window=//p' "$HOME_DIR/state/$ID.meta")
  before=$(cat "$HOME_DIR/state/$ID.meta")
  out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" relaunch --note "keep going" 2>&1)
  expect_code 1 "$?" "relaunch with a note while the session holds its conversation"
  assert_contains "$out" "steer it with bin/fm-send.sh" "the refusal should name the steer path"
  out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" relaunch --harness codex 2>&1)
  expect_code 1 "$?" "relaunch onto another harness"
  out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" relaunch 2>&1)
  rc=$?
  expect_code 0 "$rc" "re-attach"$'\n'"$out"
  assert_contains "$out" "via=reattach" "a running session with a detached window should only be re-attached"
  [ "$(fm_agent_view_viewer_state "$t" "$ID" "$SID")" = session ] || fail "re-attach must leave the window showing the session"
  [ "$(cat "$HOME_DIR/state/$ID.meta")" = "$before" ] || fail "re-attach must leave the record untouched"
  out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" interrupt 2>&1)
  expect_code 0 "$?" "interrupt"$'\n'"$out"
  assert_contains "$out" "verified=agent-alive" "an interrupt must leave the session running"
  out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" exit 2>&1)
  expect_code 0 "$?" "exit"$'\n'"$out"
  assert_contains "$out" "stopped $ID" "exit should report the session stopped"
  assert_grep "stop $SID" "$FAKE_CLAUDE_DIR/calls.log" "exit must be claude stop"
  session_running "$SID" && fail "exit must stop the session"
  wait_for 15 window_at_shell "$t" || fail "exit must leave the window at its shell"
  out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" exit 2>&1)
  assert_contains "$out" "already-stopped" "a second exit is idempotent"
  pass "fm-control: re-attach keeps the record, interrupt keeps the session, exit is claude stop and idempotent"
}

test_control_resumes() {
  local t out rc
  t=$(sed -n 's/^window=//p' "$HOME_DIR/state/$ID.meta")
  out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" relaunch 2>&1)
  rc=$?
  expect_code 0 "$rc" "resume"$'\n'"$out"
  assert_contains "$out" "agent_view=$SID via=resume" "a stopped session must be resumed, not replaced"
  session_running "$SID" || fail "resume must bring the same session back"
  assert_grep "agent_view_id=$SID" "$HOME_DIR/state/$ID.meta" "the record must keep the same session"
  [ "$(fm_agent_view_viewer_state "$t" "$ID" "$SID")" = session ] || fail "resume must leave the window showing the session"
  [ "$(jq length "$FAKE_CLAUDE_DIR/sessions.json")" = 1 ] || fail "resume must not start a second session"
  pass "fm-control: relaunch of a stopped pilot resumes its own conversation"
}

test_control_restarts() {
  local t out rc stops
  t=$(sed -n 's/^window=//p' "$HOME_DIR/state/$ID.meta")
  [ "$(fm_agent_view_viewer_state "$t" "$ID" "$SID")" = session ] || fail "divergence lost: the window must show the running session"
  stops=$(grep -cx "stop $SID" "$FAKE_CLAUDE_DIR/calls.log")
  out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" relaunch 2>&1)
  rc=$?
  expect_code 0 "$rc" "restart"$'\n'"$out"
  assert_contains "$out" "agent_view=$SID via=restart" "a running session its window shows must be restarted, not replaced"
  [ "$(grep -cx "stop $SID" "$FAKE_CLAUDE_DIR/calls.log")" = $((stops + 1)) ] || fail "restart must stop the session once"
  session_running "$SID" || fail "restart must bring the same session back"
  assert_grep "agent_view_id=$SID" "$HOME_DIR/state/$ID.meta" "the record must keep the same session"
  [ "$(jq length "$FAKE_CLAUDE_DIR/sessions.json")" = 1 ] || fail "restart must not start a second session"
  [ "$(fm_agent_view_viewer_state "$t" "$ID" "$SID")" = session ] || fail "restart must leave the window showing the session"
  pass "fm-control: relaunch of a running, shown pilot stops and resumes its own conversation"
}

test_watch_liveness_reads_the_session() {
  local t
  t=$(sed -n 's/^window=//p' "$HOME_DIR/state/$ID.meta")
  end_foreground "$t" "the viewer"
  [ "$(fm_backend_agent_alive tmux "$t")" = dead ] || fail "divergence: the window alone must read dead"
  [ "$(fm_task_agent_alive "$HOME_DIR/state/$ID.meta" tmux "$t")" = alive ] \
    || fail "a running pilot with no viewer must read alive"
  type_line "$t" "env > $LAB/window-shell.env"
  wait_for 15 grep -qs '^TMUX_PANE=%' "$LAB/window-shell.env" \
    || fail "divergence lost: the window's shell must carry its tmux pane"
  wait_for 15 window_at_shell "$t" || fail "the window did not return to its shell"
  fm_agent_view_attach_window "$t" "$ID" "$SID" 10 || fail "re-attach for the next case"
  pass "liveness: a pilot's liveness follows its session, not its window"
}

test_control_starts_fresh() {
  local t out rc fresh=6f7a8b9c
  t=$(sed -n 's/^window=//p' "$HOME_DIR/state/$ID.meta")
  jq -c --arg id "$SID" 'map(select(.id != $id))' "$FAKE_CLAUDE_DIR/sessions.json" > "$FAKE_CLAUDE_DIR/s.tmp"
  mv -f "$FAKE_CLAUDE_DIR/s.tmp" "$FAKE_CLAUDE_DIR/sessions.json"
  wait_for 15 window_at_shell "$t" || fail "the viewer of a removed session must exit"
  out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" relaunch 2>&1)
  expect_code 1 "$?" "a fresh relaunch without a note"
  assert_contains "$out" "requires --note" "a fresh worker must be told what happened"
  printf '%s' "$fresh" > "$FAKE_CLAUDE_DIR/next-id"
  out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" relaunch --note "the previous session is gone" 2>&1)
  rc=$?
  expect_code 0 "$rc" "fresh relaunch"$'\n'"$out"
  assert_contains "$out" "agent_view=$fresh via=fresh" "a removed session must be replaced by a fresh one"
  assert_grep "agent_view_id=$fresh" "$HOME_DIR/state/$ID.meta" "the record must name the fresh session"
  assert_contains "$(cat "$FAKE_CLAUDE_DIR/$fresh.prompt")" "the previous session is gone" \
    "the fresh session must start from the instructions and the note"
  [ "$(jq -r .env.FM_AGENT_VIEW_TASK "$FAKE_CLAUDE_DIR/$fresh.settings")" = "$ID" ] \
    || fail "the fresh session must carry the hook marker"
  [ "$(fm_agent_view_viewer_state "$t" "$ID" "$fresh")" = session ] || fail "the window must show the fresh session"
  SID=$fresh
  pass "fm-control: relaunch of a removed pilot starts a fresh session from the instructions and the note"
}

test_control_exit_without_window() {
  local t out rc
  t=$(sed -n 's/^window=//p' "$HOME_DIR/state/$ID.meta")
  tmux kill-window -t "$t"
  [ "$(fm_backend_tmux_agent_state "$t")" = missing ] || fail "divergence lost: the window must be gone"
  session_running "$SID" || fail "the session must outlive its window"
  out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" exit 2>&1)
  rc=$?
  expect_code 0 "$rc" "exit with the window gone"$'\n'"$out"
  printf '%s\n' "$out" | grep -q "^stopped $ID " || fail "exit must report the session stopped: $out"
  ! session_running "$SID" || fail "exit must stop the session by its id with no window left"
  pass "fm-control: exit stops a pilot's session by id even after its window is gone"
}
test_teardown_removes_the_session() {
  local out rc
  out=$(fm_env "$ROOT/bin/fm-teardown.sh" "$ID" --force 2>&1)
  rc=$?
  expect_code 0 "$rc" "teardown"$'\n'"$out"
  assert_grep "rm $SID" "$FAKE_CLAUDE_DIR/calls.log" "cleanup must remove the session"
  [ "$(jq length "$FAKE_CLAUDE_DIR/sessions.json")" = 0 ] || fail "cleanup must leave no session behind"
  pass "fm-teardown: cleanup stops and removes the pilot's session"
}

test_spawn_refused_launch() {
  local id="avr$PID_TAG" wt="$LAB/pool/2/wt" out rc
  mkdir -p "$HOME_DIR/data/$id" "$LAB/pool/2"
  printf '# brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  git -C "$PROJ_DIR" worktree add --quiet -b "task-$id" "$wt"
  TASK_TMPS+=("/tmp/fm-$id")
  : > "$FAKE_CLAUDE_DIR/refuse-launch"
  out=$(fm_env env FM_FAKE_PANE_PATH="$wt" "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  rc=$?
  rm -f "$FAKE_CLAUDE_DIR/refuse-launch"
  expect_code 1 "$rc" "a pilot launch Claude Code refuses"
  assert_contains "$out" "refused the agent-view launch" "the refusal should say Claude Code refused the launch"
  assert_contains "$out" "Workspace not trusted" "the refusal should carry Claude Code's own reason"
  assert_no_grep "agent_view_id" "$HOME_DIR/state/$id.meta" "a launch that created no session must leave no session id, not even pending"
  [ "$(jq length "$FAKE_CLAUDE_DIR/sessions.json")" = 0 ] || fail "a refused launch must leave no session"
  pass "fm-spawn: a launch Claude Code refuses leaves a record that names no session"
}

# --- 7. switch off is today's launch, byte for byte --------------------------------

# A logging tmux that never runs anything, so the exact typed launch is
# observable, exactly as tests/fm-trace-context-spawn.test.sh records it.
make_logging_tmux() {  # <dir>
  mkdir -p "$1"
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    shift
    skip=
    for a in "$@"; do
      if [ -n "$skip" ]; then skip=; continue; fi
      case "$a" in
        -t) skip=1 ;;
        -l|Enter|C-m) ;;
        *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
      esac
    done
    ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
}

spawn_logged() {  # <home> <id> <wt> <launch-log> [extra...]
  local home=$1 id=$2 wt=$3 log=$4
  shift 4
  : > "$log"
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_LOG="$log" TMUX="fake,1,0" \
    PATH="$LAB/logtmux:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$wt.proj" "$@" 2>&1
}

normalized_record() {  # <home> <id> <wt>
  sed -e '/^lease_holder=/d' -e '/^busy_gen=/d' -e '/^spawn_gen=/d' "$1/state/$2.meta"
  sed -e 's/--gen [^ ]*/--gen N/g' "$3/.claude/settings.local.json"
}

reset_record() {  # <home> <id>
  rm -f "$1/state/$2".* "$1/state/.$2".* 2>/dev/null || true
}

test_switch_off_is_byte_identical() {
  local home="$LAB/offhome" id="avo$PID_TAG" wt="$LAB/offwt" log="$LAB/off.log" out rc
  local base_launch base_record case_launch case_record
  make_logging_tmux "$LAB/logtmux"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s off\n' "$$" > "$home/state/.trace-context-effective"
  touch "$home/state/.last-watcher-beat"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$wt.proj" "$wt" "wt-$id"
  TASK_TMPS+=("/tmp/fm-$id")

  out=$(spawn_logged "$home" "$id" "$wt" "$log" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "baseline spawn with no switch"$'\n'"$out"
  base_launch=$(cat "$log")
  base_record=$(normalized_record "$home" "$id" "$wt")
  assert_contains "$base_launch" "export GOTMPDIR=" "the ordinary launch exports GOTMPDIR"
  assert_not_contains "$base_launch" "--bg" "the ordinary launch is not a background session"

  for value in off ' off '; do
    reset_record "$home" "$id"
    printf '%s\n' "$value" > "$home/config/agent-view-workers"
    out=$(spawn_logged "$home" "$id" "$wt" "$log" --mode no-mistakes --yolo off)
    expect_code 0 "$?" "spawn with the switch '$value'"$'\n'"$out"
    assert_not_contains "$out" "agent-view pilot" "an off switch prints nothing about the pilot"
    assert_not_contains "$out" "agent_view=" "an off switch launches no pilot"
    case_launch=$(cat "$log")
    case_record=$(normalized_record "$home" "$id" "$wt")
    [ "$case_launch" = "$base_launch" ] || fail "switch '$value': the typed launch must be byte-identical to today's"
    [ "$case_record" = "$base_record" ] || fail "switch '$value': the record and hooks must be byte-identical to today's"
  done

  # On, but for an ordinary harness: untouched, and silent.
  reset_record "$home" "$id"
  printf 'on\n' > "$home/config/agent-view-workers"
  printf 'codex\n' > "$home/config/crew-harness"
  out=$(spawn_logged "$home" "$id" "$wt" "$log" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "codex spawn with the switch on"$'\n'"$out"
  assert_not_contains "$(cat "$log")" "--bg" "the pilot never touches another harness"
  printf 'claude\n' > "$home/config/crew-harness"

  # An unreadable switch refuses an eligible spawn before anything is created.
  reset_record "$home" "$id"
  printf 'maybe\n' > "$home/config/agent-view-workers"
  out=$(spawn_logged "$home" "$id" "$wt" "$log" --mode no-mistakes --yolo off)
  rc=$?
  expect_code 1 "$rc" "spawn with an invalid switch"
  assert_contains "$out" "must say on or off" "the refusal should name the switch's values"
  assert_absent "$home/state/$id.meta" "a refused spawn must leave no record"
  [ ! -s "$log" ] || fail "a refused spawn must type nothing"
  pass "switch off: absent or off launches byte-identically to today, other harnesses are untouched, and an unreadable switch refuses first"
}

test_viewer_guard_signals
test_input_guard
test_release_and_attach
test_session_state
test_small_contracts
test_spawn_launches_a_pilot
test_send_refuses_a_detached_viewer
test_control_reattach_interrupt_exit
test_control_resumes
test_control_restarts
test_watch_liveness_reads_the_session
test_control_starts_fresh
test_control_exit_without_window
test_teardown_removes_the_session
test_spawn_refused_launch
test_switch_off_is_byte_identical
