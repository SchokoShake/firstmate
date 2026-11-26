#!/usr/bin/env bash
# tests/fm-restart-recovery-herdr-live-e2e.test.sh - opt-in live guard for
# restart recovery on the Herdr backend against the REAL Claude Code and the
# REAL Herdr, the Herdr counterpart of tests/fm-restart-recovery-live-e2e.test.sh.
#
# Why this file exists: Herdr restores its whole layout across a server restart
# and, with its default [session] resume_agents_on_restore, relaunches every
# agent whose session id its Claude integration reported as a bare
# `claude --resume <id>` that loses firstmate's launch line and restart note.
# Firstmate keeps that from happening to its workers by starting a Claude
# crewmate without HERDR_ENV, which the integration's hook needs before it
# reports anything, and then brings the agent-free restored pane back itself.
# Every link in that chain is vendor behavior - the hook's own HERDR_ENV guard,
# Herdr's resume rule, its restore of an agent-free pane, its native agent
# detection - so only a real worker on a real Herdr shows a drift.
#
# A real Claude worker is spawned through bin/fm-spawn.sh onto an isolated
# Herdr lab session, in a scratch firstmate home and a scratch repository, and
# given a random token. Then one case runs:
#
#   restart  the lab server is stopped and started again (bin/fm-herdr-lab.sh
#            stop, then provision), as the captain starting Herdr again after
#            a machine restart does.
#   stopped  the lab server is stopped and left stopped, as a reboot leaves it
#            until something starts it.
#
# Both cases are machine restarts: restart detection reads the kernel boot id
# alone, as on tmux. A Herdr-only restart without a reboot leaves the worker
# stopped until `bin/fm-control.sh revive <id>`, exactly like a tmux server
# crash.
#
# FM_HERDR_RR_CASE picks one; unset, both run, each with its own worker and lab.
# The boot id file is flipped to simulate a machine restart, and every case must
# show all of the following, or it fails naming both versions:
#   - the worker's Claude process carries no HERDR_ENV (Linux /proc only);
#   - Herdr relaunches no agent into the restored pane, which reads agent-free;
#   - session start prints the bring-back command, and in the stopped case it
#     starts no server;
#   - that command, run as printed, reports a resume under the original session
#     id, starting the stopped server when it has to, with firstmate's full
#     launch line in the pane;
#   - the revived worker answers with the token in a form its conversation
#     never contained: lowercase, with its random digits exact, within two
#     asks.
#
# Every Herdr call firstmate makes goes through a PATH wrapper that routes it
# through bin/fm-herdr-lab.sh run against the lab session and refuses any other
# session. A bare `herdr server` start (fm_backend_herdr_server_ensure) is
# mapped to the helper's guarded `provision`, the only allowed way to start a
# stopped lab server, and logged with its caller chain. Crew state is read only
# while the lab server is up, because reading a pane starts a stopped server.
# The captain's `default` session is never touched; the helper's teardown
# tripwire fails the run if it changed.
#
# Cost: three short turns per case on a small model
# (FM_RESTART_RECOVERY_LIVE_MODEL, default haiku).
#
# Opt in with FM_RESTART_RECOVERY_HERDR_LIVE=1. Run it after every Claude Code
# or Herdr update and before refreshing docs/verification/runtime-backends.md
# "Restart recovery on Herdr". FM_HERDR_RR_LOG_DIR keeps the step log.
set -u

if [ "${FM_RESTART_RECOVERY_HERDR_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_RESTART_RECOVERY_HERDR_LIVE=1 to run the Herdr restart-recovery live guard against the installed Claude Code and Herdr"
  exit 0
fi

if [ -z "${FM_HERDR_RR_CASE:-}" ]; then
  rc=0
  for c in restart stopped; do
    FM_HERDR_RR_CASE=$c bash "${BASH_SOURCE[0]}" || rc=1
  done
  [ "$rc" -eq 0 ] && echo "# all fm-restart-recovery herdr live cases passed"
  exit "$rc"
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

CASE=$FM_HERDR_RR_CASE
case "$CASE" in restart|stopped) ;; *) fail "FM_HERDR_RR_CASE must be restart or stopped" ;; esac

for tool in claude herdr jq git perl; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed, so nothing was checked"
done
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
HERDR_VERSION=$(herdr --version 2>/dev/null | head -1)
VERSIONS="claude ${CLAUDE_VERSION:-unknown} on ${HERDR_VERSION:-herdr unknown}"
echo "# case $CASE: $VERSIONS"
die() { fail "$VERSIONS: case $CASE: $1${STEP_LOG:+ (step log $STEP_LOG)}"; }

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
ORIGINAL_PATH=$PATH
REAL_PS=$(command -v ps)
# The helper must reach the real herdr, never the wrapper below.
lab() { PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" "$@"; }
SESSION=$(lab name fm-rr-herdr-live) || fail "could not name a lab session"
LAB=$(fm_test_tmproot fm-rr-herdr-live) || fail "could not create a scratch directory"
LAB=$(cd "$LAB" && pwd -P)
ID="rrherdr$$"
MODEL=${FM_RESTART_RECOVERY_LIVE_MODEL:-haiku}
DIGITS=$(( (RANDOM << 15 | RANDOM) % 900000 + 100000 ))
TOKEN="OSPREY-$DIGITS"
HOME_DIR="$LAB/fmhome"
STATE_DIR="$HOME_DIR/state"
PROJ_DIR="$LAB/proj"
WT="$LAB/pool/1/wt"
META="$STATE_DIR/$ID.meta"
RECORD="$STATE_DIR/$ID.harness-session"
BOOT_FILE="$LAB/boot-id"
SS_ROOT="$LAB/ssroot"
LOG_DIR=${FM_HERDR_RR_LOG_DIR:-$LAB/logs}
mkdir -p "$LOG_DIR"
STEP_LOG="$LOG_DIR/$CASE-steps.log"
SERVER_LOG="$LOG_DIR/$CASE-server-starts.log"
: > "$STEP_LOG"; : > "$SERVER_LOG"

log() { printf '%s\n' "$*" >> "$STEP_LOG"; }
log_block() {  # <title> <text>
  { printf '===== %s =====\n' "$1"; printf '%s\n' "$2"; printf '===== end %s =====\n' "$1"; } >> "$STEP_LOG"
}

cleanup_live() {
  local rc=$? p
  trap - EXIT
  lab teardown "$SESSION" || { echo "not ok - lab teardown or its default-session tripwire failed" >&2; rc=1; }
  # Claude Code keeps a directory per path it ran in; remove only the ones
  # named after this run's scratch root.
  for p in "$WT" "$PROJ_DIR"; do
    case "$p" in */fm-rr-herdr-live.*/*)
      rm -rf -- "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$p" | sed 's/[^A-Za-z0-9]/-/g')" ;;
    esac
  done
  case "/tmp/fm-$ID" in /tmp/fm-rrherdr*) rm -rf -- "/tmp/fm-$ID" ;; esac
  [ -n "${FM_HERDR_RR_LOG_DIR:-}" ] || [ "$rc" -eq 0 ] || cat "$STEP_LOG" >&2
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_live EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Lab shells look like a fleet window's, not like this run's caller.
herdr_forget_inherited_pane
unset HERDR_BIN_PATH TMUX TMUX_PANE GOTMPDIR TRACEPARENT FM_AGENT_VIEW_TASK FM_TRACE_CONTEXT \
  CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH CLAUDE_CODE_SESSION_ID \
  CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_MESSAGING_SOCKET \
  CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION CLAUDE_EFFORT CLAUDE_PID AI_AGENT \
  CLAUDE_CODE_CHILD_NOTES_DIR CLAUDE_CODE_DISABLE_AGENT_VIEW
mkdir -p "$LAB/bin" "$LAB/ssbin" "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$STATE_DIR" "$HOME_DIR/config"

# Route every production Herdr call through the guarded helper, scoped to the
# lab: strip the adapter's trailing --session, refuse any other session, and
# map a bare server start to the helper's guarded provision.
cat > "$LAB/bin/herdr" <<EOF
#!/usr/bin/env bash
set -uo pipefail
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = '$SESSION' ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
fi
if [ "\${#args[@]}" -eq 1 ] && [ "\${args[0]}" = server ]; then
  {
    printf '%s server start requested; caller chain:\n' "\$(date +%T.%N)"
    p=\$PPID
    for _ in 1 2 3 4 5 6 7 8; do
      [ -n "\$p" ] && [ "\$p" -gt 1 ] 2>/dev/null || break
      printf '  %s: %s\n' "\$p" "\$("$REAL_PS" -o args= -p "\$p" 2>/dev/null | cut -c1-240)"
      p=\$("$REAL_PS" -o ppid= -p "\$p" 2>/dev/null | tr -d ' ')
    done
  } >> '$SERVER_LOG'
  PATH='$ORIGINAL_PATH' exec '$HERDR_LAB_HELPER' provision '$SESSION'
fi
PATH='$ORIGINAL_PATH' exec '$HERDR_LAB_HELPER' run '$SESSION' "\${args[@]}"
EOF
chmod +x "$LAB/bin/herdr"
fm_fake_treehouse "$LAB/bin"
cat > "$LAB/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "no-mistakes version v1.79.0 (fake)" ;;
  axi) printf 'runs_on_current_branch: 0\n' ;;
esac
exit 0
SH
chmod +x "$LAB/bin/no-mistakes"
fm_fake_exit0 "$LAB/bin" agent-presence gh gh-axi
# Session start's lock reads the harness that owns the session from the process
# ancestry; this ps answers "claude" for this run's own process only.
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
export PATH="$LAB/bin:$PATH" HERDR_SESSION="$SESSION"
[ "$(command -v herdr)" = "$LAB/bin/herdr" ] || fail "the lab herdr wrapper must shadow the real herdr"

fm_git_worktree "$PROJ_DIR" "$WT" "task-$ID" || fail "could not create the scratch repository"
git init -q -b main "$SS_ROOT" || fail "could not create the scratch firstmate root"
git -C "$SS_ROOT" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q --allow-empty -m init
printf 'claude\n' > "$HOME_DIR/config/crew-harness"
printf 'herdr\n' > "$HOME_DIR/config/backend"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
printf '%s\n' "$$" > "$STATE_DIR/.lock"
printf '%s off\n' "$$" > "$STATE_DIR/.trace-context-effective"
touch "$STATE_DIR/.last-watcher-beat"
printf 'live-boot-a\n' > "$BOOT_FILE"
cat > "$HOME_DIR/data/$ID/brief.md" <<EOF
# Live guard worker

This is an automated check of whether firstmate can bring you back after a restart.
Remember this token exactly: $TOKEN
Do not read, run, or change anything, and use no tool unless a later message asks for one.
Reply with the single word noted.
EOF

fm_env() {  # <command...>
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$STATE_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" FM_CONTROL_LAUNCH_WAIT=90 FM_CONTROL_NM_TIMEOUT=5 \
    "$@"
}

run_session_start() {
  env -u FM_ROOT_OVERRIDE FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$SS_ROOT" \
    FM_BOOT_ID_FILE="$BOOT_FILE" FM_FAKE_HARNESS_PID=$$ FM_STARTUP_NETWORK_TIMEOUT=10 \
    FM_RESTART_NM_TIMEOUT=5 PATH="$LAB/ssbin:$PATH" \
    "$ROOT/bin/fm-session-start.sh" 2>&1
}

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "the herdr adapter did not load"

wait_for() {  # <seconds> <command...>
  local limit=$(($1 * 2)) i=0
  shift
  until "$@"; do
    i=$((i + 1))
    [ "$i" -lt "$limit" ] || return 1
    sleep 0.5
  done
}

record_get() { sed -n "s/^$1=//p" "$RECORD" 2>/dev/null | tail -n 1; }
current_gen() { cat "$STATE_DIR/$ID.busy-gen" 2>/dev/null; }
target() { fm_backend_target_of_meta "$META"; }
pane() { local t; t=$(target); printf '%s' "${t#*:}"; }
screen() { lab run "$SESSION" pane read "$(pane)" --lines 200 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 15; }
turn_ended_now() {
  [ -n "$(current_gen)" ] && [ "$(record_get gen)" = "$(current_gen)" ] && [ "$(record_get event)" = Stop ]
}
replies() {
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' \
    "$(record_get transcript)" 2>/dev/null
}
# The answer counts when it is the token in lowercase, a form the conversation
# never contained, with its random digits exact: a small model sometimes slips a
# letter of the word (osprey -> opsrey) while recalling the digits right.
answered() { replies | grep -E -- "(^|[^A-Za-z])[a-z]+-$DIGITS([^0-9]|\$)" >/dev/null; }
noted() { replies | grep -qi noted; }
lab_running() {
  lab run "$SESSION" session list --json 2>/dev/null \
    | jq -r --arg s "$SESSION" '.sessions[]? | select(.name == $s) | .running' 2>/dev/null
}
server_stopped() { [ "$(lab_running)" = false ]; }
server_starts() { grep -c 'server start requested' "$SERVER_LOG"; }
agent_state() { fm_backend_agent_state herdr "$(target)"; }
# The pane's foreground processes, one argv per line with its pid first.
foreground() {
  lab run "$SESSION" pane process-info --pane "$(pane)" 2>/dev/null \
    | jq -r '.result.process_info.foreground_processes[]? | "\(.pid) \(.argv | join(" "))"' 2>/dev/null
}
claude_in_pane() { foreground | grep -E '^[0-9]+ ([^ ]*/)?claude( |$)'; }

# snapshot <label>: what firstmate and Herdr say about the worker's endpoint.
# Crew state is read only while the server is up: reading a pane starts it.
snapshot() {
  local label=$1 running crew='(not read: the lab server is down)'
  running=$(lab_running)
  [ "$running" != true ] || crew=$(fm_env "$ROOT/bin/fm-crew-state.sh" "$ID" 2>&1 | head -n 1)
  log "SNAPSHOT [$label] server_running=$running target=$(target) agent_state=$(agent_state) crew_state=[$crew]"
  log "  record: $(grep -E '^(gen|event|session_id|recorded)=' "$RECORD" 2>/dev/null | tr '\n' ' ')"
  [ "$running" != true ] || log_block "foreground [$label]" "$(foreground)"
  [ "$running" != true ] || log_block "screen [$label]" "$(screen)"
}

trust_prompt_shown() { screen | grep -F "Yes, I trust this folder" >/dev/null; }
trust_yes_selected() { screen | grep -E '(❯|>) *(2\. *)?Yes, I trust this folder' >/dev/null; }
first_turn_or_trust() { turn_ended_now || trust_prompt_shown; }
accept_trust_prompt() {
  trust_yes_selected || lab run "$SESSION" pane send-keys "$(pane)" down >/dev/null
  wait_for 5 trust_yes_selected || die "the workspace trust prompt did not move to its trusting option"$'\n'"$(screen)"
  lab run "$SESSION" pane send-keys "$(pane)" enter >/dev/null
  log "accepted Claude Code's workspace trust prompt for the fresh worktree"
}

# --- 1. a real worker on the lab session, started without HERDR_ENV ---------------------

lab provision "$SESSION" >/dev/null || fail "could not provision the isolated Herdr lab session"
log "provisioned lab session $SESSION"
out=$(fm_env "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ_DIR" --mode no-mistakes --yolo off --model "$MODEL" --backend herdr 2>&1) \
  || die "spawn failed:"$'\n'"$out"
log_block "spawn output" "$out"
case "$(target)" in "$SESSION":*) : ;; *) die "spawn recorded an unexpected Herdr target: $(target)" ;; esac
: > "$LAB/pool/treehouse-state.lock"
printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"%s"}]}\n' \
  "$WT" "$(sed -n 's/^lease_holder=//p' "$META")" > "$LAB/pool/treehouse-state.json"
wait_for 120 first_turn_or_trust || die "the worker's first turn never ended"$'\n'"$(screen)"
if ! turn_ended_now; then
  accept_trust_prompt
  wait_for 120 turn_ended_now || die "the worker's first turn never ended once trusted"$'\n'"$(screen)"
fi
SID=$(record_get session_id)
fm_env "$ROOT/bin/fm-harness-session.sh" resumable "$STATE_DIR" "$ID" >/dev/null \
  || die "no resumable record: $(cat "$RECORD")"
# The transcript can trail the turn-end hook, so the first reply is waited for.
wait_for 20 noted || die "the worker did not acknowledge its brief: [$(replies)]"$'\n'"$(screen)"
answered && die "the answer leaked into the conversation before the restart"
[ "$(agent_state)" = alive ] || die "Herdr does not detect the worker's agent natively (reads '$(agent_state)')"
pid=$(claude_in_pane | head -n 1 | cut -d' ' -f1)
[ -n "$pid" ] || die "no claude process runs in the worker's pane:"$'\n'"$(foreground)"
if [ -r "/proc/$pid/environ" ]; then
  tr '\0' '\n' < "/proc/$pid/environ" | grep -q '^HERDR_ENV=' \
    && die "the worker's claude process carries HERDR_ENV, so Herdr's integration would report its session for relaunch"
  log "worker claude pid $pid carries no HERDR_ENV"
else
  echo "# note: /proc/$pid/environ is not readable here, so the worker's environment was not checked"
fi
pass "$VERSIONS: case $CASE: a real worker on the Herdr lab runs without HERDR_ENV, detected natively, under conversation $SID"
snapshot "worker running"
out=$(run_session_start)
log_block "session start 0 (before restart, boot a)" "$out"

# --- 2. the restart ---------------------------------------------------------------

out=$(lab stop "$SESSION" 2>&1) || die "lab stop failed: $out"
wait_for 30 server_stopped || die "the lab server did not stop"
snapshot "server stopped"

no_herdr_relaunch() {  # <label>
  sleep 5
  if claude_in_pane >/dev/null; then
    die "Herdr relaunched an agent into the restored pane ($1):"$'\n'"$(foreground)"
  fi
  [ "$(agent_state)" = dead ] || die "the restored pane reads '$(agent_state)', not agent-free ($1)"
}

if [ "$CASE" = restart ]; then
  lab provision "$SESSION" >/dev/null 2>&1 || die "the lab server could not be started again"
  log "lab server started again through the helper's provision"
  no_herdr_relaunch "server restarted"
  snapshot "server restarted"
fi

printf 'live-boot-b\n' > "$BOOT_FILE"
starts_before=$(server_starts)
out=$(run_session_start)
log_block "session start (boot id changed)" "$out"
if [ "$CASE" = stopped ]; then
  [ "$(server_starts)" = "$starts_before" ] || die "session start started the stopped Herdr server"
  server_stopped || die "the lab server is running after session start, which must not start it"
fi
assert_contains "$out" "MACHINE RESTART" "$VERSIONS: case $CASE: session start printed no restart section"$'\n'"$out"
assert_contains "$out" "- $ID: ship no-mistakes; resumes its conversation" \
  "$VERSIONS: case $CASE: session start did not list the stopped worker"
BRING_BACK=$(printf '%s\n' "$out" | sed -n 's/^bring every one back: //p')
[ -n "$BRING_BACK" ] || die "session start printed no bring-back command"$'\n'"$out"
pass "$VERSIONS: case $CASE: session start lists the stopped Herdr worker and prints the bring-back command"
snapshot "after session start"

# --- 3. bring it back, with the command as printed --------------------------------------

starts_before=$(server_starts)
rc=0
out=$(fm_env bash -c "$BRING_BACK" 2>&1) || rc=$?
log_block "revive (rc=$rc)" "$out"
[ "$rc" -eq 0 ] || die "the printed bring-back command failed (rc=$rc):"$'\n'"$out"
assert_contains "$out" "revived $ID via=resume" "$VERSIONS: case $CASE: revive did not resume the conversation"
assert_contains "$out" "session=$SID" "$VERSIONS: case $CASE: revive did not resume the original session $SID"
if [ "$CASE" = stopped ]; then
  [ "$(server_starts)" -gt "$starts_before" ] || die "revive brought the worker back without starting the server it needs"
fi
launch=$(claude_in_pane | head -n 1)
for want in --dangerously-skip-permissions "--name fm-$ID" "--resume $SID"; do
  case "$launch" in *"$want"*) ;; *) die "the revived worker does not run firstmate's launch line (missing $want): $launch" ;; esac
done
pass "$VERSIONS: case $CASE: the printed command resumes session $SID with firstmate's full launch line"
snapshot "after revive"

wait_for 120 turn_ended_now || die "the resumed worker never finished the turn its restart note started"
[ "$(record_get session_id)" = "$SID" ] || die "the resumed worker runs conversation $(record_get session_id), not $SID"
# A small model now and then answers the question with a garbled word although
# its conversation holds the token, so the question is asked at most twice.
QUESTION="Reply with only the token you were asked to remember, written entirely in lowercase letters."
for attempt in 1 2; do
  replies_before=$(replies | wc -l)
  out=$(fm_env "$ROOT/bin/fm-send.sh" "$ID" "$QUESTION" 2>&1) || die "the question could not be sent: $out"
  wait_for 90 answered && break
  log "attempt $attempt: no recall; replies since the question: $(replies | tail -n +"$((replies_before + 1))" | tr '\n' ' ')"
  [ "$attempt" = 1 ] || die "the revived worker did not recall the token in two asks; replies: $(replies | tail -n 5)"
  wait_for 60 turn_ended_now || die "the revived worker never finished answering the first ask"
done
snapshot "end"
pass "$VERSIONS: case $CASE: the revived worker answers from its original conversation $SID"
