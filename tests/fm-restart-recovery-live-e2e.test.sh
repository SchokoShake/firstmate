#!/usr/bin/env bash
# tests/fm-restart-recovery-live-e2e.test.sh - opt-in live guard for restart
# recovery (bin/fm-harness-session.sh, bin/fm-restart-lib.sh, and
# bin/fm-control.sh revive) against the REAL Claude Code.
#
# Why this file exists: the record revive resumes from is built from Claude
# Code's own hook payload (session_id, transcript_path, cwd), and the resume is
# Claude Code's own `claude --resume <session-id> "<prompt>"`, which must keep
# the session id and submit the prompt. The portable regression
# (tests/fm-restart-recovery.test.sh) pins firstmate's logic against a stand-in
# that fires hooks shaped like Claude Code's; only this guard can see a vendor
# change to the payload, the flag, or what a resumed session keeps.
#
# It drives firstmate's own scripts end to end on a private tmux socket, in a
# scratch firstmate home and a scratch repository: a real worker is spawned and
# given a random token, the private tmux server is killed as the simulated
# restart, session start must list the worker and print the bring-back
# command, that printed command is run as printed, and the revived worker must
# answer, under its original session id, with the token in a form its
# conversation never contained. Any other answer fails.
# The private server is killed on any exit, and the run removes the
# conversation files Claude Code wrote for the scratch worktree.
#
# Cost: three short turns on a small model (FM_RESTART_RECOVERY_LIVE_MODEL,
# default haiku).
#
# Opt in with FM_RESTART_RECOVERY_LIVE=1. Run it after every Claude Code update
# and before refreshing docs/verification/runtime-backends.md "Restart recovery".
set -u

if [ "${FM_RESTART_RECOVERY_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_RESTART_RECOVERY_LIVE=1 to run the restart-recovery live guard against the installed Claude Code"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERSION=unknown
die() { fail "claude $VERSION: $1"; }

command -v claude >/dev/null 2>&1 || die "claude is not installed, so nothing was checked"
command -v tmux >/dev/null 2>&1 || die "tmux is not installed, so nothing was checked"
command -v jq >/dev/null 2>&1 || die "jq is not installed, so nothing was checked"
command -v git >/dev/null 2>&1 || die "git is not installed, so nothing was checked"
perl -MJSON::PP -e1 >/dev/null 2>&1 || die "perl JSON::PP is not installed, so nothing was checked"
VERSION=$(claude --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || VERSION=unknown
echo "# harness claude $VERSION"

REAL_TMUX=$(command -v tmux)
REAL_PS=$(command -v ps)
SOCKET="fm-restart-live-$$"
LAB=$(fm_test_tmproot fm-restart-live) || die "could not create a scratch directory"
mkdir -p "$LAB"
LAB=$(cd "$LAB" && pwd -P)
ID="rrlive$$"
MODEL=${FM_RESTART_RECOVERY_LIVE_MODEL:-haiku}
TOKEN="KESTREL-$(( (RANDOM << 15 | RANDOM) % 900000 + 100000 ))"
ANSWER=$(printf '%s' "$TOKEN" | tr '[:upper:]' '[:lower:]')
HOME_DIR="$LAB/fmhome"
STATE_DIR="$HOME_DIR/state"
PROJ_DIR="$LAB/proj"
WT="$LAB/pool/1/wt"
META="$STATE_DIR/$ID.meta"
RECORD="$STATE_DIR/$ID.harness-session"
BOOT_FILE="$LAB/boot-id"
SS_ROOT="$LAB/ssroot"

# Claude Code keeps a directory per path it ran in, named after that path: the
# worktree's holds its conversations, and the scratch repository's its project
# memory. This run removes exactly those two, whose names carry the lab's own
# unique scratch path, and no other.
claude_lab_dirs() {
  local root p
  root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  for p in "$WT" "$PROJ_DIR"; do
    printf '%s/%s\n' "$root" "$(printf '%s' "$p" | sed 's/[^A-Za-z0-9]/-/g')"
  done
}

cleanup_live() {
  local dir
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -f -- "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET"
  while IFS= read -r dir; do
    case "$dir" in */projects/-*fm-restart-live-*) rm -rf -- "$dir" ;; esac
  done < <(claude_lab_dirs)
  case "/tmp/fm-$ID" in /tmp/fm-rrlive*) rm -rf -- "/tmp/fm-$ID" ;; esac
  fm_test_cleanup
}
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
mkdir -p "$LAB/shim" "$LAB/bin" "$LAB/ssbin" "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$STATE_DIR" "$HOME_DIR/config"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" -f /dev/null "\$@"
SH
chmod +x "$LAB/shim/tmux"
fm_fake_treehouse "$LAB/bin"
# The shared no-mistakes daemon is never asked anything about this lab: the
# stand-in reports no validation run on the branch.
cat > "$LAB/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "no-mistakes version v1.79.0 (fake)" ;;
  axi) printf 'runs_on_current_branch: 0\n' ;;
esac
exit 0
SH
chmod +x "$LAB/bin/no-mistakes"
# The worker's presence beat must never announce this lab on a real board.
fm_fake_exit0 "$LAB/bin" agent-presence gh gh-axi
# Session start's lock reads the harness that owns the session from the process
# ancestry; this ps answers "claude" for this test's own process only.
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
[ "$(command -v tmux)" = "$LAB/shim/tmux" ] || die "the private-socket tmux shim must shadow the real tmux"

fm_git_worktree "$PROJ_DIR" "$WT" "task-$ID" || die "could not create the scratch repository"
git init -q -b main "$SS_ROOT" || die "could not create the scratch firstmate root"
git -C "$SS_ROOT" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q --allow-empty -m init
printf 'claude\n' > "$HOME_DIR/config/crew-harness"
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
tmux new-session -d -s firstmate -n w0 "bash --norc --noprofile" || die "could not start the private tmux server"
tmux set-option -g default-command "bash --norc --noprofile"

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
fm_backend_source tmux || die "the tmux adapter did not load"

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
target() { sed -n 's/^window=//p' "$META" | tail -n 1; }
screen() { tmux capture-pane -p -t "$(target)" 2>/dev/null; }
# A turn of the agent incarnation now running has ended: its own Stop hook
# rewrote the record under the task's current generation.
turn_ended_now() {
  [ -n "$(current_gen)" ] && [ "$(record_get gen)" = "$(current_gen)" ] && [ "$(record_get event)" = Stop ]
}
replies() {
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' \
    "$(record_get transcript)" 2>/dev/null
}
answered() { replies | grep -F -- "$ANSWER" >/dev/null; }
server_gone() { ! "$REAL_TMUX" -L "$SOCKET" list-sessions >/dev/null 2>&1; }

explain_stall() {  # <what>
  die "$1. Screen:"$'\n'"$(screen)"
}
trust_prompt_shown() { screen | grep -F "Yes, I trust this folder" >/dev/null; }
trust_yes_selected() { screen | grep -E '(❯|>) *(2\. *)?Yes, I trust this folder' >/dev/null; }
first_turn_or_trust() { turn_ended_now || trust_prompt_shown; }

# The lab's worktree is new to Claude Code, as every fresh worktree is, so its
# first launch may ask whether to trust it. Accept it the way a fresh fleet
# worktree's prompt is accepted, choosing the trusting option explicitly:
# Claude Code 2.1.316 preselects "No, exit", so Enter alone would end the
# worker. Enter is pressed only once the trusting option is selected.
accept_trust_prompt() {
  local i=0
  tmux send-keys -t "$(target)" Down
  until trust_yes_selected; do
    i=$((i + 1))
    [ "$i" -lt 10 ] || explain_stall "the workspace trust prompt did not move to its trusting option"
    sleep 0.5
  done
  tmux send-keys -t "$(target)" Enter
  echo "# accepted Claude Code's workspace trust prompt for the lab's fresh worktree"
}

# --- 1. a real worker records its conversation from its own hooks ------------------

out=$(fm_env "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ_DIR" --mode no-mistakes --yolo off --model "$MODEL" 2>&1) \
  || die "spawn failed:"$'\n'"$out"
: > "$LAB/pool/treehouse-state.lock"
printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"%s"}]}\n' \
  "$WT" "$(sed -n 's/^lease_holder=//p' "$META")" > "$LAB/pool/treehouse-state.json"
wait_for 120 first_turn_or_trust || explain_stall "the worker's first turn never wrote a conversation record ending at its Stop hook"
if ! turn_ended_now; then
  accept_trust_prompt
  wait_for 120 turn_ended_now \
    || explain_stall "the worker's first turn never wrote a conversation record ending at its Stop hook once its worktree was trusted"
fi
SID=$(record_get session_id)
TRANSCRIPT=$(record_get transcript)
fm_env "$ROOT/bin/fm-harness-session.sh" resumable "$STATE_DIR" "$ID" >/dev/null \
  || die "the hook payload no longer yields a resumable record: $(fm_env "$ROOT/bin/fm-harness-session.sh" resumable "$STATE_DIR" "$ID"); record:"$'\n'"$(cat "$RECORD")"
[ "$(cd "$(record_get cwd)" && pwd -P)" = "$WT" ] || die "the hook payload's cwd is not the worktree: $(record_get cwd)"
replies | grep -qi noted || die "the worker did not acknowledge its brief; its replies were:"$'\n'"$(replies)"
replies | grep -F -- "$ANSWER" >/dev/null && die "the answer leaked into the conversation before the restart, so recall would prove nothing"
pass "claude $VERSION: the worker's own hooks record a resumable conversation $SID in its worktree"

# --- 2. the simulated restart, and what session start reports ----------------------

run_session_start >/dev/null
"$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
wait_for 20 server_gone || die "the private tmux server did not stop"
printf 'live-boot-b\n' > "$BOOT_FILE"
out=$(run_session_start)
assert_contains "$out" "MACHINE RESTART" "claude $VERSION: session start did not report the restart"
assert_contains "$out" "- $ID: ship no-mistakes; resumes its conversation" "claude $VERSION: session start did not list the stopped worker as resumable"
BRING_BACK=$(printf '%s\n' "$out" | sed -n 's/^bring every one back: //p')
[ -n "$BRING_BACK" ] || die "session start printed no bring-back command"
pass "claude $VERSION: after the simulated restart session start lists the worker and the bring-back command"

# --- 3. the printed command brings it back into the same conversation ---------------

out=$(fm_env bash -c "$BRING_BACK" 2>&1) || explain_stall "the printed bring-back command failed:"$'\n'"$out"
assert_contains "$out" "revived $ID via=resume" "claude $VERSION: the worker was not resumed"
assert_contains "$out" "session=$SID" "claude $VERSION: the worker was not resumed into its recorded conversation"
assert_contains "$out" "reopened=yes" "claude $VERSION: the endpoint was not reopened"
[ "$(cd "$(fm_backend_tmux_current_path "$(target)")" && pwd -P)" = "$WT" ] || die "the reopened endpoint is not in the worktree"
wait_for 120 turn_ended_now || explain_stall "the resumed worker never finished the turn its restart note started"
[ "$(record_get session_id)" = "$SID" ] || die "the resumed worker runs a different conversation $(record_get session_id), not $SID"
[ "$(record_get transcript)" = "$TRANSCRIPT" ] || die "the resumed worker writes a different conversation file $(record_get transcript)"
out=$(fm_env "$ROOT/bin/fm-send.sh" "$ID" "Reply with only the token you were asked to remember, written entirely in lowercase letters." 2>&1) \
  || die "the question could not be sent:"$'\n'"$out"
wait_for 120 answered || die "the revived worker did not recall the token from its conversation; its replies were:"$'\n'"$(replies)"$'\n'"Screen:"$'\n'"$(screen)"
pass "claude $VERSION: the revived worker answers from its original conversation $SID"

echo "# all fm-restart-recovery live tests passed"
