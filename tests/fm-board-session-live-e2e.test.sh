#!/usr/bin/env bash
# Opt-in live guard for the board wake-up registration's environment route.
#
# tests/fm-board-session.test.sh pins both routes portably: given a set of
# environment variables and a registry entry, it proves the record firstmate
# writes is the record intended. That is everything CI can see, and it is not
# the risky half.
#
# The risky half is a claim only the vendor can settle:
#
#   CLAUDE_CODE_SESSION_ID, INSIDE A TOOL CALL, IS THE REGISTRY'S sessionId,
#   AND CLAUDE_PID IS THE PROCESS THAT REGISTRY ENTRY IS KEYED BY.
#
# Neither variable is documented as that, and if either changed meaning the
# portable suite would keep passing while every wake went to a session id that
# names nothing. The runtime does cross-check the two sources and refuses on a
# disagreement, so the drift would surface as an unregistered session rather
# than a misdirected wake - but it would still cost the feature, quietly, and
# nothing in CI would say why.
#
# So this guard settles it against the real binary. It starts a THROWAWAY
# session in its own scratch directory, has it print its own environment from a
# real tool call, and compares that against the registry entry the same session
# wrote. It never touches a real home, lock, fleet, or the operator's sessions.
#
# Run it after every Claude Code upgrade, and before trusting refreshed evidence
# in docs/verification/cross-session-messaging.md:
#
#   FM_BOARD_SESSION_LIVE_E2E=1 tests/fm-board-session-live-e2e.test.sh
#
# It starts a real session and costs a real model turn.
set -u

if [ "${FM_BOARD_SESSION_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_BOARD_SESSION_LIVE_E2E=1 to run the live session-identity regression"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-board-session-lib.sh"

# An absent harness is reported, never passed over: a guard that checked nothing
# must not read as a guard that found nothing wrong.
for tool in claude tmux python3; do
  command -v "$tool" >/dev/null 2>&1 \
    || fail "the live session-identity guard needs $tool; refusing to pass having checked nothing"
done

CLAUDE_VERSION=$(claude --version 2>&1 | head -1)
TMP_ROOT=$(fm_test_tmproot fm-board-session-live)
LAB_DIR="$TMP_ROOT/lab"
STATE="$TMP_ROOT/state"
ENV_FILE="$LAB_DIR/session-env.txt"
mkdir -p "$LAB_DIR" "$STATE"

LAB="fm-board-session-live-$$"
SESSION_NAME="fm-board-session-probe-$$"

cleanup() {
  tmux kill-session -t "$LAB" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# The throwaway's own registry entry, found by the name this suite gave it, so a
# sibling session of the operator's can never be mistaken for it.
probe_entry() {
  local entry
  for entry in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/sessions/*.json; do
    [ -f "$entry" ] || continue
    FM_T_ENTRY="$entry" FM_T_NAME="$SESSION_NAME" python3 -c '
import json, os, sys
try:
    d = json.load(open(os.environ["FM_T_ENTRY"]))
except Exception:
    sys.exit(1)
sys.exit(0 if d.get("name") == os.environ["FM_T_NAME"] else 1)
' 2>/dev/null || continue
    printf '%s\n' "$entry"
    return 0
  done
  return 1
}

tmux kill-session -t "$LAB" 2>/dev/null || true
tmux new-session -d -s "$LAB" -x 200 -y 50 -c "$LAB_DIR" \
  "claude --name $SESSION_NAME --dangerously-skip-permissions \
     -p 'Run exactly this one command and then stop: printenv > $ENV_FILE'" \
  || fail 'could not start the throwaway session'

# Wait for both halves: the registry entry the session writes at startup, and
# the environment its own tool call printed.
ENTRY=
waited=0
while [ "$waited" -lt 180 ]; do
  [ -n "$ENTRY" ] || ENTRY=$(probe_entry) || ENTRY=
  if [ -n "$ENTRY" ] && [ -s "$ENV_FILE" ]; then
    break
  fi
  if tmux capture-pane -p -t "$LAB" 2>/dev/null | grep -q 'I trust this folder'; then
    tmux send-keys -t "$LAB" Enter
  fi
  waited=$((waited + 1))
  sleep 1
done
[ -n "$ENTRY" ] || fail "the throwaway session never registered ($CLAUDE_VERSION)"
[ -s "$ENV_FILE" ] || fail "the throwaway session never printed its environment ($CLAUDE_VERSION)"

env_value() {  # <name>
  sed -n "s/^$1=//p" "$ENV_FILE" | sed -n 1p
}
ENV_SESSION=$(env_value CLAUDE_CODE_SESSION_ID)
ENV_PID=$(env_value CLAUDE_PID)
REG_SESSION=$(fm_board_session_field "$ENTRY" sessionId)
REG_PID=$(basename "$ENTRY" .json)

[ -n "$ENV_SESSION" ] \
  || fail "a live $CLAUDE_VERSION tool call exports no CLAUDE_CODE_SESSION_ID;
  the environment route is gone and only the registry fallback still registers this session"
[ -n "$ENV_PID" ] \
  || fail "a live $CLAUDE_VERSION tool call exports no CLAUDE_PID;
  the environment route now depends on the session lock's pid for its registry lookup"

[ "$ENV_SESSION" = "$REG_SESSION" ] \
  || fail "$CLAUDE_VERSION: CLAUDE_CODE_SESSION_ID ($ENV_SESSION) is not the registry's sessionId ($REG_SESSION);
  the environment route would register an id no wake can resolve"
[ "$ENV_PID" = "$REG_PID" ] \
  || fail "$CLAUDE_VERSION: CLAUDE_PID ($ENV_PID) is not the pid the registry entry is keyed by ($REG_PID);
  the environment route would read the informational fields from another session's entry"
pass "a live $CLAUDE_VERSION tool call states the same session id and pid the registry records"

# THE CLAIM, through the real publisher rather than a reading of these values:
# the environment a real session exports must produce a record naming that
# session, by the environment route, with no disagreement to refuse over.
CLAUDE_CODE_SESSION_ID="$ENV_SESSION" CLAUDE_PID="$ENV_PID" \
  fm_board_session_publish "$STATE" 1 >/dev/null \
  || fail "$CLAUDE_VERSION: the real publisher refused a live session's own environment"
assert_grep "\"session_id\":\"$REG_SESSION\"" "$STATE/board-session.json" \
  "$CLAUDE_VERSION: the published record does not name the live session"
assert_grep '"source":"environment"' "$STATE/board-session.json" \
  "$CLAUDE_VERSION: a live session's own environment did not take the environment route"
pass "the real publisher registers a live session from its own environment"
