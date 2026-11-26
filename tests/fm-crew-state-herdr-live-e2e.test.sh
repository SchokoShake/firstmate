#!/usr/bin/env bash
# Live guard: a real Claude worker on a real Herdr reads as bin/fm-crew-state.sh
# and bin/fm-busy-lib.sh say through a long foreground tool call, an interrupt,
# an open question, and an exit. Herdr classifies a Claude pane from what Claude
# Code renders, through detection rules that update on their own, so only a real
# worker shows a drift; failures name both versions. Every Herdr call goes through
# bin/fm-herdr-lab.sh against an isolated lab session.
# docs/verification/runtime-backends.md records the last result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

if [ "${FM_CREW_STATE_HERDR_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_CREW_STATE_HERDR_LIVE=1 to run the real Claude/Herdr current-state guard"
  exit 0
fi

for tool in claude herdr jq git; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed, so nothing was checked"
done
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
HERDR_VERSION=$(herdr --version 2>/dev/null | head -1)
echo "# harness claude ${CLAUDE_VERSION:-unknown} on ${HERDR_VERSION:-herdr unknown}"
die() { fail "claude ${CLAUDE_VERSION:-unknown} on ${HERDR_VERSION:-herdr unknown}: $1"; }

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
ORIGINAL_PATH=$PATH
# The helper must reach the real herdr, never the wrapper below.
lab() { PATH="$ORIGINAL_PATH" "$LAB_HELPER" "$@"; }
SESSION=$(lab name fm-crew-state-live)
LAB=$(fm_test_tmproot fm-crew-state-live) || die "could not create a scratch directory"
LAB=$(cd "$LAB" && pwd -P)
ID="cslive$$"
HOME_DIR="$LAB/fmhome"
STATE_DIR="$HOME_DIR/state"
PROJ_DIR="$LAB/proj"
WT="$LAB/pool/1/wt"
META="$STATE_DIR/$ID.meta"

cleanup_live() {
  local rc=$? p
  trap - EXIT
  lab teardown "$SESSION" || rc=1
  # Claude Code keeps a directory per path it ran in; remove only the ones
  # named after this run's scratch root.
  for p in "$WT" "$PROJ_DIR"; do
    case "$p" in */fm-crew-state-live.*/*)
      rm -rf -- "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$p" | sed 's/[^A-Za-z0-9]/-/g')" ;;
    esac
  done
  rm -rf -- "/tmp/fm-$ID"
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_live EXIT

# The worker's shell looks like a fleet window's, not like this test's caller.
herdr_forget_inherited_pane
unset TMUX TMUX_PANE GOTMPDIR TRACEPARENT FM_AGENT_VIEW_TASK FM_TRACE_CONTEXT \
  CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH CLAUDE_CODE_SESSION_ID \
  CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_MESSAGING_SOCKET \
  CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION CLAUDE_EFFORT CLAUDE_PID AI_AGENT
mkdir -p "$LAB/bin" "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$STATE_DIR" "$HOME_DIR/config"

# Route production adapter calls through the guarded helper, which scopes each
# to the lab: strip the adapter's trailing --session, refusing any other session.
cat > "$LAB/bin/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = '$SESSION' ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
fi
PATH='$ORIGINAL_PATH' exec '$LAB_HELPER' run '$SESSION' "\${args[@]}"
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
export PATH="$LAB/bin:$PATH" HERDR_SESSION="$SESSION"

fm_git_worktree "$PROJ_DIR" "$WT" "task-$ID" || die "could not create the scratch repository"
printf 'claude\n' > "$HOME_DIR/config/crew-harness"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
cat > "$HOME_DIR/data/$ID/brief.md" <<'EOF'
# Live guard worker

This is an automated check of how firstmate reads a worker's state.
Do not read, run, or change anything, and use no tool unless a later message asks for one.
Reply with the single word noted.
EOF

fm_env() {  # <command...>
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$STATE_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" FM_GATE_REFUSE_BYPASS=1 \
    "$@"
}

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

wait_for() {  # <seconds> <command...>
  local limit=$(($1 * 2)) i=0
  shift
  until "$@"; do
    i=$((i + 1))
    [ "$i" -lt "$limit" ] || return 1
    sleep 0.5
  done
}

PANE=
native() { lab run "$SESSION" agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null; }
screen() { lab run "$SESSION" pane read "$PANE" --lines 200 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 12; }
crew_state() { fm_env "$ROOT/bin/fm-crew-state.sh" "$ID" 2>&1; }
busy_verdict() { fm_busy_classify_meta "$META" "$ID" "$STATE_DIR"; }
record() { fm_busy_record_read "$STATE_DIR" "$ID" | cut -d' ' -f1,2; }
native_is() { [ "$(native)" = "$1" ]; }
native_idle() { case "$(native)" in idle|done) return 0 ;; esac; return 1; }
turn_ended() { [ "$(busy_verdict)" = "idle claude-hook" ] && native_idle; }
trust_prompt_shown() { screen | grep -F "Yes, I trust this folder" >/dev/null; }
trust_yes_selected() { screen | grep -E '(❯|>) *(2\. *)?Yes, I trust this folder' >/dev/null; }
first_turn_or_trust() { turn_ended || trust_prompt_shown; }
explain() {  # <what>
  die "$1"$'\n'"native=$(native) busy=$(busy_verdict) record=$(record)"$'\n'"crew-state: $(crew_state)"$'\n'"Herdr's reading:"$'\n'"$(lab run "$SESSION" agent explain "$PANE" 2>&1 | head -6)"$'\n'"Screen:"$'\n'"$(screen)"
}

lab provision "$SESSION" >/dev/null || die "could not provision the isolated Herdr lab session"
out=$(fm_env "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ_DIR" --mode no-mistakes --yolo off --model haiku --backend herdr 2>&1) \
  || die "spawn failed:"$'\n'"$out"
TARGET=$(fm_backend_target_of_meta "$META")
PANE=${TARGET#*:}
case "$TARGET" in "$SESSION":*) : ;; *) die "spawn recorded an unexpected Herdr target: $TARGET" ;; esac

wait_for 120 first_turn_or_trust || explain "the worker's first turn never ended"
if ! turn_ended; then
  trust_yes_selected || lab run "$SESSION" pane send-keys "$PANE" down >/dev/null
  wait_for 5 trust_yes_selected || explain "the workspace trust prompt did not move to its trusting option"
  lab run "$SESSION" pane send-keys "$PANE" enter >/dev/null
  wait_for 120 turn_ended || explain "the worker's first turn never ended once its worktree was trusted"
fi
case "$(crew_state)" in "state: working"*) explain "an idle worker read working" ;; esac
pass "real worker idles after its first turn and does not read working"

# A long foreground tool call: Herdr must keep reading the turn, past the
# moment a leftover Claude record would start yielding to its idle.
printf '#!/bin/sh\necho holding\nsleep 45\necho released\n' > "$WT/hold.sh"
chmod +x "$WT/hold.sh"
fm_env "$ROOT/bin/fm-send.sh" "$ID" "Run exactly this command with the Bash tool in the foreground, not in the background: ./hold.sh ; when it returns, reply with the single word reached." >/dev/null \
  || explain "the long-tool steer was not delivered"
turn_open() { [ "$(record)" = "busy claude-hook" ]; }
wait_for 60 turn_open || explain "the worker never opened the long-tool turn"
sleep $((FM_BUSY_HERDR_IDLE_SETTLE_SECS + 3))
for _ in 1 2 3 4 5; do
  native_is working || explain "Herdr stopped reading the turn during a long foreground tool call"
  case "$(crew_state)" in "state: working"*) : ;; *) explain "a worker inside a long foreground tool call did not read working" ;; esac
  sleep 1
done
pass "a long foreground tool call reads working throughout, natively and in crew state"

# Interrupt: Claude fires no hook, so its busy record stays behind.
fm_env "$ROOT/bin/fm-control.sh" "$ID" interrupt >/dev/null || explain "the interrupt was not delivered"
interrupted() { native_idle && [ "$(busy_verdict)" = "idle herdr-native" ]; }
wait_for 15 interrupted || explain "an interrupted worker's leftover busy record did not yield to Herdr's idle"
[ "$(record)" = "busy claude-hook" ] || explain "the record no longer disagrees with Herdr, so the interrupt case checked nothing"
case "$(crew_state)" in "state: working"*) explain "an interrupted, idle worker still read working" ;; esac
pass "an interrupted worker stops reading working although its busy record remains"

# An open question keeps the turn busy; only Herdr's blocked tells it apart.
fm_env "$ROOT/bin/fm-send.sh" "$ID" "Use the AskUserQuestion tool right now to ask me exactly one question: which colour do I prefer, with the two options red and blue. Do nothing else." >/dev/null \
  || explain "the question steer was not delivered"
wait_for 90 native_is blocked || explain "Herdr never read the open question as blocked"
[ "$(busy_verdict)" = "busy claude-hook" ] || explain "an open question no longer keeps the turn busy, so the question case checked nothing"
case "$(crew_state)" in "state: blocked"*) : ;; *) explain "an open question did not read blocked" ;; esac
pass "an open question reads blocked, not working"
lab run "$SESSION" pane send-keys "$PANE" enter >/dev/null
wait_for 60 turn_ended || explain "the worker did not finish its turn after the question was answered"

# Exit: the pane outlives its agent.
fm_env "$ROOT/bin/fm-control.sh" "$ID" exit >/dev/null || explain "the exit was not delivered"
case "$(crew_state)" in "state: exited"*) : ;; *) explain "an exited worker did not read exited" ;; esac
pass "an exited worker reads exited"
