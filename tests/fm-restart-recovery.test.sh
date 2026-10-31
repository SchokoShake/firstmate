#!/usr/bin/env bash
# tests/fm-restart-recovery.test.sh - portable regression for surviving a
# machine restart: the conversation record a worker keeps continuously
# (bin/fm-harness-session.sh), restart detection and the stopped list
# (bin/fm-restart-lib.sh) as the session-start digest reports them, and the one
# supported bring-back step, bin/fm-control.sh revive.
#
# It runs REAL processes in a REAL tmux server on a private socket, with a
# stand-in `claude` that fires the worker's own turn-boundary hooks with a hook
# payload shaped like Claude Code's, so it needs no harness and no credentials.
# Killing that private server is the simulated restart, and FM_BOOT_ID_FILE
# stands in for the kernel's boot id. The live counterpart, which resumes a
# real Claude Code conversation, is tests/fm-restart-recovery-live-e2e.test.sh.
#
# What it pins:
#   1. The record is written by the worker's own hooks while it runs, bound to
#      its busy generation, and only by a process carrying the task's GOTMPDIR.
#   2. Session start records the boot id, and after the simulated restart lists
#      the stopped worker with its conversation, its validation state, and the
#      exact revive commands; a later start retires the list once nothing in it
#      is still stopped. A worker deliberately stopped before the restart is
#      listed apart, and revive --stopped-by-restart leaves it stopped.
#   3. relaunch refuses a gone endpoint before writing anything, and revive
#      refuses a working copy whose lease it cannot prove before creating
#      anything.
#   4. revive reopens the endpoint in the recorded worktree and resumes the
#      recorded conversation with a restart note that tells the worker exactly
#      what no-mistakes says to run first; it is idempotent; it falls back to a
#      fresh agent when no conversation is recorded or --fresh is passed; a
#      failed resume leaves a record a second revive completes; and a reopened
#      shell whose typed cd a startup program swallowed is moved into the
#      worktree by the next revive.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
[ -x /bin/bash ] || { echo "skip: /bin/bash not found"; exit 0; }
perl -MJSON::PP -e1 >/dev/null 2>&1 || { echo "skip: perl JSON::PP not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
REAL_PS=$(command -v ps)
LAB=$(fm_test_tmproot fm-restart-recovery)
mkdir -p "$LAB"
LAB=$(cd "$LAB" && pwd -P)
SOCKET="fm-restart-$$"
ID="rr$$"

cleanup_lab() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -f -- "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET"
  case "/tmp/fm-$ID" in /tmp/fm-rr*) rm -rf -- "/tmp/fm-$ID" ;; esac
  fm_test_cleanup
}
trap cleanup_lab EXIT

# Hermetic shells: a scratch HOME, no outer tmux client, no ambient Claude Code
# identity, and the stand-ins first on PATH, so nothing here can reach a real
# Claude Code, the host's tmux sessions, or the real no-mistakes daemon.
mkdir -p "$LAB/home" "$LAB/shim" "$LAB/bin" "$LAB/ssbin" "$LAB/claude"
export HOME="$LAB/home" SHELL=/bin/bash
# The login profile a reopened window's shell reads. Only while one case asks
# for it (test_revive_waits_for_a_reopened_shell_to_finish_starting), it holds
# the shell's startup in a read until that case releases it, then runs a
# program. The read waits on a FIFO rather than the terminal, so the shell is
# the only process meanwhile and a line typed into it is left for the shell.
# Only while another case asks for it
# (test_a_swallowed_move_is_completed_by_a_later_revive), a startup program
# reads one line from the terminal, which swallows the typed cd.
cat > "$LAB/home/.bash_profile" <<'SH'
if [ -e "$HOME/slow-start" ]; then
  echo held >> "$HOME/slow-start.log"
  read -r -t 30 _ <> "$HOME/slow-start.fifo" || true
  echo program >> "$HOME/slow-start.log"
  sleep 1
  echo done >> "$HOME/slow-start.log"
fi
if [ -e "$HOME/swallow-line" ]; then
  read -r -t 30 _ || true
fi
SH
unset TMUX TMUX_PANE CLAUDE_CONFIG_DIR CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_PID \
  FM_TRACE_CONTEXT GOTMPDIR TRACEPARENT FM_AGENT_VIEW_TASK PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" -f /dev/null "\$@"
SH
chmod +x "$LAB/shim/tmux"
fm_fake_treehouse "$LAB/bin"
cat > "$LAB/bin/agent-presence" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$LAB/bin/agent-presence"
fm_fake_exit0 "$LAB/bin" gh gh-axi node chrome-devtools-axi lavish-axi

# The no-mistakes stand-in answers `axi status` from $FAKE_NM_STATUS when that
# file exists, and otherwise reports no run on the branch.
export FAKE_NM_STATUS="$LAB/nm-status"
cat > "$LAB/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "no-mistakes version v1.79.0 (fake)"; exit 0 ;;
  axi)
    if [ "${2:-}" = status ] && [ -f "$FAKE_NM_STATUS" ]; then
      cat "$FAKE_NM_STATUS"
    else
      printf 'runs_on_current_branch: 0\n'
    fi
    exit 0
    ;;
esac
exit 0
SH
chmod +x "$LAB/bin/no-mistakes"

# The stand-in Claude Code. A fresh start takes the session id in next-sid; a
# `--resume <id>` continues that id's conversation file and refuses an id with
# none, as Claude Code does. Either way it appends its prompt to the
# conversation, fires the worktree's UserPromptSubmit and Stop hooks with a
# payload carrying session_id, transcript_path, cwd, and hook_event_name, and
# then stays in the foreground under the argv0 `claude`, so the tmux classifier
# reads it as a running agent on every platform, until it reads `/exit`.
export FAKE_CLAUDE_DIR="$LAB/claude"
cat > "$LAB/bin/claude" <<'SH'
#!/bin/bash
set -u
D=$FAKE_CLAUDE_DIR
# One line per launch: the prompt's own newlines are folded into spaces.
printf '%s\n' "$(printf '%s ' "$@" | tr '\n' ' ')" >> "$D/calls.log"
resume= prompt=
while [ $# -gt 0 ]; do
  case "$1" in
    --resume) resume=${2-}; shift 2 ;;
    --name|--model|--effort|--settings) shift 2 ;;
    --*) shift ;;
    *) prompt=$1; shift ;;
  esac
done
if [ -n "$resume" ]; then
  if [ -e "$D/fail-resume" ] || [ ! -s "$D/transcripts/$resume.jsonl" ]; then
    echo "No conversation found with session ID: $resume"
    exit 1
  fi
  sid=$resume
else
  sid=$(cat "$D/next-sid")
fi
mkdir -p "$D/transcripts"
transcript="$D/transcripts/$sid.jsonl"
jq -nc --arg p "$prompt" '{type: "user", prompt: $p}' >> "$transcript"
fire() {  # <event>
  local payload cmd
  [ -f .claude/settings.local.json ] || return 0
  payload=$(jq -nc --arg s "$sid" --arg t "$transcript" --arg c "$PWD" --arg e "$1" \
    '{session_id: $s, transcript_path: $t, cwd: $c, hook_event_name: $e, permission_mode: "bypassPermissions"}')
  while IFS= read -r cmd; do
    printf '%s' "$payload" | sh -c "$cmd" >/dev/null 2>&1 || true
  done < <(jq -r --arg e "$1" '.hooks[$e][]?.hooks[]?.command' .claude/settings.local.json)
}
fire UserPromptSubmit
fire Stop
echo "stand-in claude: conversation $sid"
exec -a claude /bin/bash -c 'while IFS= read -r l; do [ "$l" != /exit ] || exit 0; done; while :; do sleep 1; done'
SH
chmod +x "$LAB/bin/claude"

# Session start's lock reads the harness that owns the session from the
# process ancestry. This ps answers "claude" for this test's own process only
# and asks the real ps everything else, so the digest below runs as the lock
# holder here and in CI alike.
cat > "$LAB/ssbin/ps" <<SH
#!/usr/bin/env bash
pid= prev=
for a in "\$@"; do [ "\$prev" = -p ] && pid=\$a; prev=\$a; done
if [ -n "\$pid" ] && [ "\$pid" = "\${FM_FAKE_HARNESS_PID:-}" ]; then
  case "\$*" in *comm=*|*args=*) echo claude; exit 0 ;; esac
fi
exec "$REAL_PS" "\$@"
SH
chmod +x "$LAB/ssbin/ps"

export PATH="$LAB/shim:$LAB/bin:$PATH"
# Every tmux call below must reach the private server, never the host's.
[ "$(command -v tmux)" = "$LAB/shim/tmux" ] || fail "the private-socket tmux shim must shadow the real tmux"
[ "$(command -v claude)" = "$LAB/bin/claude" ] || fail "the stand-in claude must shadow every real one"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "tmux adapter did not load"

HOME_DIR="$LAB/fmhome"
PROJ_DIR="$LAB/proj"
WT_DIR="$LAB/pool/1/wt"
SS_ROOT="$LAB/ssroot"
BOOT_FILE="$LAB/boot-id"
SID1=6f1c2a7e-0b3d-4c5e-9a8f-1b2c3d4e5f60
SID2=7a2d3b8f-1c4e-4d6f-8b9a-2c3d4e5f6071
BRING_BACK=
STATE_DIR="$HOME_DIR/state"
META="$STATE_DIR/$ID.meta"
BRIEF="$HOME_DIR/data/$ID/brief.md"
RECORD="$STATE_DIR/$ID.harness-session"

fm_env() {  # <command...>
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$STATE_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=10 FM_CONTROL_LAUNCH_WAIT="${LAUNCH_WAIT:-20}" \
    FM_CONTROL_NM_TIMEOUT=5 \
    "$@"
}

run_session_start() {
  env -u FM_ROOT_OVERRIDE FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$SS_ROOT" \
    FM_BOOT_ID_FILE="$BOOT_FILE" FM_FAKE_HARNESS_PID=$$ FM_STARTUP_NETWORK_TIMEOUT=10 \
    FM_RESTART_NM_TIMEOUT=5 PATH="$LAB/ssbin:$PATH" \
    "$ROOT/bin/fm-session-start.sh" 2>&1
}

wait_for() {  # <seconds> <command...>
  local limit=$1 i=0
  shift
  until "$@"; do
    i=$((i + 1))
    [ "$i" -lt $((limit * 10)) ] || return 1
    sleep 0.1
  done
}

record_get() {  # <key>
  grep "^$1=" "$RECORD" 2>/dev/null | tail -1 | cut -d= -f2-
}

current_gen() {
  cat "$STATE_DIR/$ID.busy-gen" 2>/dev/null
}

record_names() {  # <session-id>
  [ "$(record_get session_id)" = "$1" ] && [ -n "$(current_gen)" ] \
    && [ "$(record_get gen)" = "$(current_gen)" ]
}

window_target() {
  sed -n 's/^window=//p' "$META" | tail -1
}

agent_running() {
  [ "$(fm_backend_tmux_agent_state "$(window_target)")" = alive ]
}

server_running() {
  "$REAL_TMUX" -L "$SOCKET" list-sessions >/dev/null 2>&1
}

server_gone() {
  ! server_running
}

note_count() {
  grep -c '^## Restart note (' "$BRIEF"
}

launches() {
  wc -l < "$FAKE_CLAUDE_DIR/calls.log" | tr -d ' '
}

write_pool_lease() {  # <label>
  : > "$LAB/pool/treehouse-state.lock"
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"%s"}]}\n' "$WT_DIR" "$1" \
    > "$LAB/pool/treehouse-state.json"
}

# A validation run that the stop ended while it held the branch, in the shape
# `no-mistakes axi status` prints it.
write_killed_run() {
  local head
  head=$(git -C "$WT_DIR" rev-parse --short=8 HEAD)
  cat > "$FAKE_NM_STATUS" <<EOF
current_branch: task-$ID
run:
  id: "01RESTARTTEST"
  branch: task-$ID
  status: failed
  head: $head
branch_sync:
  state: pipeline_owned
  next_action:
    code: recover_custody
    command: "no-mistakes axi sync --recover"
EOF
}

# The simulated restart: the private server dies with every process in it, as
# a machine stop ends them, and the boot id changes.
simulate_restart() {  # <new-boot-id>
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  wait_for 10 server_gone || fail "the private tmux server did not stop"
  printf '%s\n' "$1" > "$BOOT_FILE"
}

setup_world() {
  mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$STATE_DIR" "$HOME_DIR/config"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  printf '%s\n' "$$" > "$STATE_DIR/.lock"
  printf '%s off\n' "$$" > "$STATE_DIR/.trace-context-effective"
  touch "$STATE_DIR/.last-watcher-beat"
  printf '# brief for %s\n\nDo the thing.\n' "$ID" > "$BRIEF"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "task-$ID"
  git init -q -b main "$SS_ROOT"
  git -C "$SS_ROOT" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q --allow-empty -m init
  printf 'boot-a\n' > "$BOOT_FILE"
  tmux new-session -d -s firstmate -n w0 "bash --norc --noprofile"
  tmux set-option -g default-command "bash --norc --noprofile"
}

# --- 1. the record is kept continuously, by the worker's own hooks ------------------

test_spawn_records_the_conversation() {
  local out rc
  setup_world
  printf '%s\n' "$SID1" > "$FAKE_CLAUDE_DIR/next-sid"
  out=$(fm_env "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  rc=$?
  expect_code 0 "$rc" "spawn"$'\n'"$out"
  write_pool_lease "$(sed -n 's/^lease_holder=//p' "$META")"
  wait_for 20 record_names "$SID1" \
    || fail "the worker's hooks did not record its conversation under its generation: $(cat "$RECORD" 2>/dev/null)"
  [ "$(record_get harness)" = claude ] || fail "the record must name the claude adapter"
  [ "$(cd "$(record_get cwd)" && pwd -P)" = "$(cd "$WT_DIR" && pwd -P)" ] || fail "the record must carry the worktree as cwd"
  [ "$(record_get transcript)" = "$FAKE_CLAUDE_DIR/transcripts/$SID1.jsonl" ] || fail "the record must carry the conversation file"
  [ "$(fm_env "$ROOT/bin/fm-harness-session.sh" resumable "$STATE_DIR" "$ID")" = "$SID1" ] \
    || fail "a recorded conversation with its file present must be resumable"
  pass "fm-spawn: the worker's own hooks keep its conversation record under its busy generation"
}

test_only_the_worker_and_its_generation_record() {
  local before cmds=() cmd payload
  before=$(cat "$RECORD")
  while IFS= read -r cmd; do cmds+=("$cmd"); done \
    < <(jq -r '.hooks.Stop[].hooks[].command' "$WT_DIR/.claude/settings.local.json")
  payload=$(jq -nc --arg c "$WT_DIR" '{session_id: "11111111-2222-4333-8444-555555555555", transcript_path: "/x", cwd: $c, hook_event_name: "Stop"}')
  for cmd in "${cmds[@]}"; do
    printf '%s' "$payload" | (cd "$WT_DIR" && env -u GOTMPDIR sh -c "$cmd") >/dev/null 2>&1 || true
    printf '%s' "$payload" | (cd "$WT_DIR" && GOTMPDIR=/tmp/fm-other/gotmp sh -c "$cmd") >/dev/null 2>&1 || true
  done
  [ "$(cat "$RECORD")" = "$before" ] || fail "a session without the task's GOTMPDIR replaced the recorded conversation"
  printf '%s' "$payload" | fm_env "$ROOT/bin/fm-harness-session.sh" record "$STATE_DIR" "$ID" --gen stale-gen --harness claude
  [ "$(cat "$RECORD")" = "$before" ] || fail "a superseded generation replaced the recorded conversation"
  printf 'not json' | fm_env "$ROOT/bin/fm-harness-session.sh" record "$STATE_DIR" "$ID" --gen "$(current_gen)" --harness claude
  [ "$(cat "$RECORD")" = "$before" ] || fail "an unreadable payload replaced the recorded conversation"
  pass "fm-harness-session: only the worker's own agent, under its current generation, rewrites the record"
}

# --- 2. session start: record the boot, then report the restart ------------------

test_first_start_records_the_boot() {
  local out
  out=$(run_session_start)
  assert_not_contains "$out" "MACHINE RESTART" "a first start must not claim a restart"
  [ "$(cat "$STATE_DIR/.boot-id")" = boot-a ] || fail "a locked start must record the boot id"
  pass "fm-session-start: a locked start records the boot id and claims nothing on first sight"
}

test_restart_is_reported_with_the_stopped_worker() {
  local out
  write_killed_run
  simulate_restart boot-b
  out=$(run_session_start)
  assert_contains "$out" "MACHINE RESTART" "the restart section is missing"$'\n'"$out"
  assert_contains "$out" "- $ID: ship no-mistakes; resumes its conversation" "the stopped worker is not listed with its conversation"
  assert_contains "$out" "validation: run failed, next action recover_custody" "the killed validation run is not reported"
  BRING_BACK=$(printf '%s\n' "$out" | sed -n 's/^bring every one back: //p')
  assert_contains "$BRING_BACK" "fm-control.sh revive --stopped-by-restart" "the bring-back-all command is missing"
  assert_contains "$out" "revive <id> [<id>...]" "the bring-back-chosen command is missing"
  grep -qx "task=$ID" "$STATE_DIR/.restart-stopped" || fail "the stopped list must name the worker"
  [ "$(cat "$STATE_DIR/.boot-id")" = boot-b ] || fail "the new boot id must be recorded"
  server_running && fail "session start must never bring a worker back"
  pass "fm-session-start: after a restart it lists the stopped worker, its conversation and validation, and the revive commands"
}

# --- 3. refusals that change nothing ------------------------------------------------

test_relaunch_refuses_a_gone_endpoint_before_writing() {
  local out rc brief_before meta_before
  brief_before=$(cat "$BRIEF")
  meta_before=$(cat "$META")
  out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" relaunch --note "progress" 2>&1)
  rc=$?
  expect_code 1 "$rc" "relaunch of a gone endpoint"
  assert_contains "$out" "bin/fm-control.sh revive $ID" "the refusal should name revive"
  [ "$(cat "$BRIEF")" = "$brief_before" ] || fail "a refused relaunch changed the instructions"
  [ "$(cat "$META")" = "$meta_before" ] || fail "a refused relaunch changed the record"
  [ ! -e "$STATE_DIR/$ID.control-relaunch" ] || fail "a refused relaunch wrote a journal"
  pass "fm-control relaunch: a gone endpoint is refused before anything is written, naming revive"
}

test_revive_refuses_an_unproven_lease_before_creating_anything() {
  local out rc holder brief_before
  holder=$(sed -n 's/^lease_holder=//p' "$META")
  brief_before=$(cat "$BRIEF")
  write_pool_lease "someone-else"
  out=$(fm_env "$ROOT/bin/fm-control.sh" revive "$ID" 2>&1)
  rc=$?
  write_pool_lease "$holder"
  expect_code 1 "$rc" "revive into an unproven working copy"
  assert_contains "$out" "cannot prove task $ID still owns" "the refusal should name the unproven lease"
  [ "$(cat "$BRIEF")" = "$brief_before" ] || fail "a refused revive changed the instructions"
  [ ! -e "$STATE_DIR/$ID.control-relaunch" ] || fail "a refused revive wrote a journal"
  server_running && fail "a refused revive must not reopen the endpoint"
  pass "fm-control revive: an unproven lease is refused before any endpoint, note, or journal exists"
}

# --- 4. bring back -------------------------------------------------------------------

# The bring-back command is run exactly as session start printed it.
test_revive_resumes_the_recorded_conversation() {
  local out rc prompt
  out=$(fm_env bash -c "$BRING_BACK" 2>&1)
  rc=$?
  expect_code 0 "$rc" "the printed bring-back command"$'\n'"$out"
  assert_contains "$out" "revived $ID via=resume" "the worker should come back into its conversation"
  assert_contains "$out" "session=$SID1" "the report should name the resumed conversation"
  assert_contains "$out" "reopened=yes" "the report should say the endpoint was reopened"
  agent_running || fail "the revived worker is not running"
  [ "$(cd "$(fm_backend_tmux_current_path "$(window_target)")" && pwd -P)" = "$(cd "$WT_DIR" && pwd -P)" ] \
    || fail "the reopened endpoint is not in the recorded worktree"
  tail -n 1 "$FAKE_CLAUDE_DIR/calls.log" | grep -F -- "--resume $SID1" >/dev/null \
    || fail "the launch did not resume the recorded conversation: $(tail -n 1 "$FAKE_CLAUDE_DIR/calls.log")"
  prompt=$(jq -r .prompt "$FAKE_CLAUDE_DIR/transcripts/$SID1.jsonl" | tail -n +2)
  assert_contains "$prompt" "Restart note from firstmate" "the resumed conversation did not receive the restart note"
  assert_contains "$prompt" "run exactly \`no-mistakes axi sync --recover\`" "the note must quote no-mistakes' own recovery command"
  assert_contains "$prompt" "validate once more from the recovered head" "the note must say the stopped validation run has to be repeated"
  [ "$(wc -l < "$FAKE_CLAUDE_DIR/transcripts/$SID1.jsonl" | tr -d ' ')" = 2 ] \
    || fail "the resumed conversation must continue the recorded one"
  record_names "$SID1" || fail "the resumed conversation must be recorded again under the new generation"
  [ "$(note_count)" = 1 ] || fail "the restart note must be in the instructions exactly once"
  assert_grep "no-mistakes axi sync --recover" "$BRIEF" "the instructions must carry the recovery step"
  [ "$(sed -n 's/^phase=//p' "$STATE_DIR/$ID.control-relaunch" | tail -n 1)" = complete ] \
    || fail "the journal must end complete"
  grep -qx "action=revive" "$STATE_DIR/$ID.control-relaunch" || fail "the journal must name revive"
  [ "$(sed -n 's/^worktree=//p' "$META")" = "$WT_DIR" ] || fail "the record must keep its worktree"
  pass "fm-control revive: reopens the endpoint in its worktree and resumes the recorded conversation with the restart note"
}

test_revive_is_idempotent() {
  local out rc before
  before=$(launches)
  out=$(fm_env "$ROOT/bin/fm-control.sh" revive "$ID" 2>&1)
  rc=$?
  expect_code 0 "$rc" "a second revive"
  assert_contains "$out" "already-running $ID" "a running worker must be reported, not relaunched"
  [ "$(launches)" = "$before" ] || fail "a second revive started a second agent"
  [ "$(note_count)" = 1 ] || fail "a second revive appended the note again"
  out=$(fm_env "$ROOT/bin/fm-control.sh" revive --stopped-by-restart 2>&1)
  assert_contains "$out" "nothing to revive" "the restart list must be empty once its worker runs"
  pass "fm-control revive: running it again starts nothing and appends nothing"
}

test_a_later_start_retires_the_list() {
  local out
  out=$(run_session_start)
  assert_not_contains "$out" "MACHINE RESTART" "a start with nothing still stopped must stay quiet"
  [ ! -e "$STATE_DIR/.restart-stopped" ] || fail "the stopped list must be retired once nothing in it is stopped"
  pass "fm-session-start: the stopped list retires once every worker in it is back"
}

test_a_failed_resume_is_completed_by_a_later_revive() {
  local out rc
  simulate_restart boot-c
  run_session_start >/dev/null
  touch "$FAKE_CLAUDE_DIR/fail-resume"
  out=$(LAUNCH_WAIT=4 fm_env "$ROOT/bin/fm-control.sh" revive "$ID" 2>&1)
  rc=$?
  rm -f "$FAKE_CLAUDE_DIR/fail-resume"
  expect_code 1 "$rc" "a resume the harness refuses"
  assert_contains "$out" "with --fresh" "a failed resume should name the fresh start as the way forward"
  agent_running && fail "a failed resume must not report a running worker"
  [ "$(note_count)" = 1 ] || fail "the same restart note must not be appended twice in a row"
  printf '%s\n' "$SID2" > "$FAKE_CLAUDE_DIR/next-sid"
  out=$(fm_env "$ROOT/bin/fm-control.sh" revive "$ID" --fresh 2>&1)
  rc=$?
  expect_code 0 "$rc" "revive --fresh after a failed resume"$'\n'"$out"
  assert_contains "$out" "revived $ID via=fresh" "--fresh must start a fresh agent"
  assert_contains "$out" "fresh_because=\"--fresh was passed\"" "the report should say why it is fresh"
  tail -n 1 "$FAKE_CLAUDE_DIR/calls.log" | grep -F -- "--resume" >/dev/null \
    && fail "a fresh revive must not resume"
  assert_contains "$(jq -r .prompt "$FAKE_CLAUDE_DIR/transcripts/$SID2.jsonl")" "Restart note" \
    "a fresh agent must read the restart note in its instructions"
  wait_for 10 record_names "$SID2" || fail "the fresh agent's conversation must replace the record"
  [ "$(note_count)" = 1 ] || fail "the restart note must still be there exactly once"
  pass "fm-control revive: a failed resume leaves a record a later revive completes, and --fresh starts afresh"
}

test_revive_without_a_recorded_conversation_starts_fresh() {
  local out rc
  simulate_restart boot-d
  rm -f "$FAKE_NM_STATUS"
  rm -f "$RECORD"
  out=$(fm_env "$ROOT/bin/fm-control.sh" revive "$ID" 2>&1)
  rc=$?
  expect_code 0 "$rc" "revive with no recorded conversation"$'\n'"$out"
  assert_contains "$out" "via=fresh" "with no recorded conversation the worker must start fresh"
  assert_contains "$out" "no conversation was recorded for its current agent" "the report should say why"
  agent_running || fail "the fresh worker is not running"
  [ "$(note_count)" = 2 ] || fail "a note with new content must be appended once"
  pass "fm-control revive: with no recorded conversation it starts a fresh agent from the instructions and the note"
}

# A server started after a restart runs login shells, whose startup files can
# leave a new shell looking idle before they run a program. Here the lab's
# login profile holds the reopened shell's startup until the case releases it,
# so a single idle read is guaranteed to come while the shell is still starting.
test_revive_waits_for_a_reopened_shell_to_finish_starting() {
  local out rc pid before held_state held_phase held_launches
  simulate_restart boot-e
  before=$(launches)
  mkfifo "$HOME/slow-start.fifo"
  : > "$HOME/slow-start.log"
  touch "$HOME/slow-start"
  fm_env "$ROOT/bin/fm-control.sh" revive "$ID" > "$LAB/slow-start.out" 2>&1 &
  pid=$!
  if ! wait_for 20 grep -qx held "$HOME/slow-start.log"; then
    kill "$pid" 2>/dev/null
    fail "the reopened shell never read its login profile"
  fi
  sleep 1
  held_state=$(fm_backend_tmux_agent_state "$(window_target)")
  held_phase=$(sed -n 's/^phase=//p' "$STATE_DIR/$ID.control-relaunch" | tail -n 1)
  held_launches=$(launches)
  printf 'go\n' > "$HOME/slow-start.fifo"
  wait "$pid"
  rc=$?
  rm -f "$HOME/slow-start" "$HOME/slow-start.fifo"
  out=$(cat "$LAB/slow-start.out")
  [ "$held_state" = dead ] \
    || fail "while its startup is held the reopened shell must read as idle, or this case proves nothing (it reads '$held_state')"
  [ "$held_phase" = reopening ] \
    || fail "revive must not move on while the reopened shell is still starting (journal phase: $held_phase)"$'\n'"$out"
  [ "$held_launches" = "$before" ] || fail "an agent was launched while the reopened shell was still starting"
  [ "$(cat "$HOME/slow-start.log")" = "$(printf 'held\nprogram\ndone')" ] \
    || fail "the reopened shell must have run its whole login profile: $(cat "$HOME/slow-start.log")"
  expect_code 0 "$rc" "revive into a shell still running its startup files"$'\n'"$out"
  assert_contains "$out" "reopened=yes" "the endpoint must have been reopened"
  agent_running || fail "the worker is not running after its shell finished starting"
  [ "$(cd "$(fm_backend_tmux_current_path "$(window_target)")" && pwd -P)" = "$(cd "$WT_DIR" && pwd -P)" ] \
    || fail "the reopened endpoint is not in the recorded worktree"
  pass "fm-control revive: nothing launches until a reopened shell has finished its startup files"
}

# A startup program that reads the terminal swallows the cd a reopen types, so
# the shell finishes starting beside the worktree. The failed revive leaves that
# window where it is, and the next one moves its shell in before launching.
test_a_swallowed_move_is_completed_by_a_later_revive() {
  local out rc before notes
  simulate_restart boot-f
  before=$(launches)
  notes=$(note_count)
  touch "$HOME/swallow-line"
  out=$(LAUNCH_WAIT=4 fm_env "$ROOT/bin/fm-control.sh" revive "$ID" 2>&1)
  rc=$?
  rm -f "$HOME/swallow-line"
  expect_code 1 "$rc" "a reopen whose cd was swallowed"
  assert_contains "$out" "run bin/fm-control.sh revive $ID again" "the failure should name the retry"
  [ "$(sed -n 's/^phase=//p' "$STATE_DIR/$ID.control-relaunch" | tail -n 1)" = failed:reopening ] \
    || fail "the journal must record the failed reopen"
  [ "$(launches)" = "$before" ] || fail "nothing may launch into a shell outside the worktree"
  [ "$(fm_backend_tmux_agent_state "$(window_target)")" = dead ] || fail "the reopened window must be left at its shell"
  [ "$(cd "$(fm_backend_tmux_current_path "$(window_target)")" && pwd -P)" != "$(cd "$WT_DIR" && pwd -P)" ] \
    || fail "divergence lost: the swallowed cd must leave the shell outside the worktree"
  out=$(fm_env "$ROOT/bin/fm-control.sh" revive "$ID" 2>&1)
  rc=$?
  expect_code 0 "$rc" "revive after a swallowed cd"$'\n'"$out"
  assert_contains "$out" "revived $ID via=resume" "the worker should come back into its conversation"
  agent_running || fail "the worker is not running after the second revive"
  [ "$(cd "$(fm_backend_tmux_current_path "$(window_target)")" && pwd -P)" = "$(cd "$WT_DIR" && pwd -P)" ] \
    || fail "the second revive must move the shell into the recorded worktree"
  [ "$(launches)" = $((before + 1)) ] || fail "the second revive must launch exactly one agent"
  [ "$(note_count)" = "$notes" ] || fail "the same restart note must not be appended again"
  pass "fm-control revive: a reopened shell whose cd was swallowed is moved into the worktree by the next revive"
}

# A deliberate stop retires the worker's busy generation; a restart leaves it.
test_a_worker_stopped_before_the_restart_stays_stopped() {
  local out rc before
  out=$(fm_env "$ROOT/bin/fm-control.sh" "$ID" exit 2>&1)
  rc=$?
  expect_code 0 "$rc" "a deliberate stop"$'\n'"$out"
  assert_contains "$out" "stopped $ID" "exit should report the worker stopped"
  [ ! -e "$STATE_DIR/$ID.busy-gen" ] || fail "a deliberate stop must retire the busy generation"
  simulate_restart boot-g
  before=$(launches)
  out=$(run_session_start)
  assert_contains "$out" "Already stopped before the restart" "a deliberately stopped worker must be listed apart"$'\n'"$out"
  assert_contains "$out" "- $ID: ship no-mistakes" "the deliberately stopped worker must still be named"
  assert_not_contains "$out" "bring every one back" "nothing the restart stopped is left to bring back"
  grep -qx "stopped_before=$ID" "$STATE_DIR/.restart-stopped" || fail "the stopped list must record it as stopped before"
  grep -qx "task=$ID" "$STATE_DIR/.restart-stopped" && fail "a deliberately stopped worker must not be listed as stopped by the restart"
  out=$(fm_env "$ROOT/bin/fm-control.sh" revive --stopped-by-restart 2>&1)
  rc=$?
  expect_code 0 "$rc" "revive --stopped-by-restart"
  assert_contains "$out" "nothing to revive" "a deliberately stopped worker must not be brought back by the restart command"
  [ "$(launches)" = "$before" ] || fail "revive --stopped-by-restart started a deliberately stopped worker"
  server_running && fail "revive --stopped-by-restart must not reopen a deliberately stopped worker's endpoint"
  out=$(run_session_start)
  assert_not_contains "$out" "MACHINE RESTART" "a list with nothing the restart stopped must retire"
  [ ! -e "$STATE_DIR/.restart-stopped" ] || fail "the stopped list must be retired"
  pass "fm-session-start: a worker stopped deliberately before a restart is listed apart and never brought back by it"
}

test_other_backends_cannot_reopen_an_endpoint() {
  local out rc
  out=$(fm_backend_recreate_task herdr "s:fm-x" "$WT_DIR" 2>&1)
  rc=$?
  expect_code 2 "$rc" "herdr endpoint recreation"
  assert_contains "$out" "herdr backend cannot recreate a gone endpoint" "the refusal should name the backend"
  pass "fm-backend: reopening a gone endpoint is tmux-only, and every other backend is refused by name"
}

test_spawn_records_the_conversation
test_only_the_worker_and_its_generation_record
test_first_start_records_the_boot
test_restart_is_reported_with_the_stopped_worker
test_relaunch_refuses_a_gone_endpoint_before_writing
test_revive_refuses_an_unproven_lease_before_creating_anything
test_revive_resumes_the_recorded_conversation
test_revive_is_idempotent
test_a_later_start_retires_the_list
test_a_failed_resume_is_completed_by_a_later_revive
test_revive_without_a_recorded_conversation_starts_fresh
test_revive_waits_for_a_reopened_shell_to_finish_starting
test_a_swallowed_move_is_completed_by_a_later_revive
test_a_worker_stopped_before_the_restart_stays_stopped
test_other_backends_cannot_reopen_an_endpoint
echo "# all fm-restart-recovery tests passed"
