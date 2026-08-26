#!/usr/bin/env bash
# Opt-in live guard for the board-answer nudge's wire frame.
#
# tests/fm-inbox-post.test.sh pins the frame portably: it proves the bytes
# bin/fm-inbox-post.sh puts on the wire are the bytes we intend, over a real
# AF_UNIX socket, with no harness anywhere. That is everything CI can see, and
# it is not the risky half.
#
# The risky half is that the frame is UNDOCUMENTED as a payload specification.
# Nothing in the vendor's public documentation promises its shape, there is no
# CLI that emits it, and a receiver that no longer recognizes it does not error
# - it logs "Failed to parse JSON line" to a debug log nobody is reading and
# drops the message. Board answers would simply stop being pushed, which is
# exactly the failure this feature exists to prevent. So the one claim a
# harness-free test can never make is the one that matters:
#
#   AN INSTALLED HARNESS STILL ACCEPTS THIS FRAME.
#
# This guard makes that claim against the real binary. It starts a THROWAWAY
# session in its own scratch directory, publishes that session's inbox into a
# throwaway home, posts a real nudge through the real script, and then reads the
# receiver's own debug log for its routing verdict. It never touches a real
# home, lock, fleet, or the operator's own sessions.
#
# The verdict is read from the receiver, not from the sender: fm-inbox-post.sh
# exiting 0 only proves a socket accepted bytes, which is precisely what a
# silently-dropped frame also looks like.
#
# Run it after every Claude Code upgrade, and before trusting refreshed evidence
# in docs/verification/cross-session-messaging.md:
#
#   FM_INBOX_POST_LIVE_E2E=1 tests/fm-inbox-post-live-e2e.test.sh
#
# It starts a real session and costs a real model turn.
set -u

if [ "${FM_INBOX_POST_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_INBOX_POST_LIVE_E2E=1 to run the live cross-session frame regression"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in claude tmux python3; do
  command -v "$tool" >/dev/null 2>&1 \
    || fail "live frame guard needs $tool; refusing to pass having checked nothing"
done

CLAUDE_VERSION=$(claude --version 2>&1 | head -1)
POST="$ROOT/bin/fm-inbox-post.sh"
TMP_ROOT=$(fm_test_tmproot fm-inbox-post-live)
HOME_DIR="$TMP_ROOT/home"
LAB_DIR="$TMP_ROOT/lab"
DEBUG_LOG="$TMP_ROOT/receiver.log"
mkdir -p "$HOME_DIR/state" "$LAB_DIR"

# A tmux session name this suite owns outright, so nothing here can touch the
# fleet's own session even if a step fails midway.
LAB="fm-inbox-live-$$"
SESSION_NAME="fm-inbox-probe-$$"

cleanup() {
  tmux kill-session -t "$LAB" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

registry_dir() { printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"; }

# The registry entry for the throwaway, found by its name so a sibling session
# of the operator's can never be mistaken for it.
probe_entry() {
  local entry
  for entry in "$(registry_dir)"/*.json; do
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
  "claude --name $SESSION_NAME --debug --debug-file $DEBUG_LOG" \
  || fail 'could not start the throwaway session'

# A fresh directory raises the workspace-trust prompt before the session
# registers an inbox. Accept it once, then wait for the registry entry.
ENTRY=
waited=0
while [ "$waited" -lt 120 ]; do
  if ENTRY=$(probe_entry); then
    break
  fi
  if tmux capture-pane -p -t "$LAB" 2>/dev/null | grep -q 'I trust this folder'; then
    tmux send-keys -t "$LAB" Enter
  fi
  waited=$((waited + 1))
  sleep 1
done
[ -n "$ENTRY" ] || fail "the throwaway session never registered an inbox ($CLAUDE_VERSION)"

SOCK=$(FM_T_ENTRY="$ENTRY" python3 -c \
  'import json, os; print(json.load(open(os.environ["FM_T_ENTRY"]))["messagingSocketPath"])')
PROTOCOL=$(FM_T_ENTRY="$ENTRY" python3 -c \
  'import json, os; print(json.load(open(os.environ["FM_T_ENTRY"])).get("peerProtocol"))')
[ -S "$SOCK" ] || fail "the throwaway session advertised no live inbox socket ($CLAUDE_VERSION)"
pass "a live $CLAUDE_VERSION session advertises an inbox on peer protocol $PROTOCOL"

# Publish exactly as fm-session-start.sh does from inside the session, then post
# exactly as the board will. Both through the real script, no shortcuts.
CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" FM_HOME="$HOME_DIR" "$POST" --publish \
  || fail "the real publisher refused a live $CLAUDE_VERSION session (peer protocol $PROTOCOL);
  if the protocol was bumped, re-verify the frame before widening the supported list"
pass 'the real publisher accepts a live session and records its inbox'

FM_HOME="$HOME_DIR" "$POST" --notify logbook \
  || fail "the real sender could not post to a live $CLAUDE_VERSION inbox"

# THE CLAIM. Read the receiver's verdict, not the sender's exit status: the
# receiver logs a routing line when it accepts the frame and a parse warning
# when it drops one, and a dropped frame is otherwise indistinguishable from a
# delivered one at the sending end.
routed=0
dropped=0
waited=0
while [ "$waited" -lt 60 ]; do
  if grep -q 'Failed to parse JSON line' "$DEBUG_LOG" 2>/dev/null; then
    dropped=1
    break
  fi
  if grep -q 'Routed user message to queue' "$DEBUG_LOG" 2>/dev/null; then
    routed=1
    break
  fi
  waited=$((waited + 1))
  sleep 1
done

[ "$dropped" -eq 0 ] || fail "$CLAUDE_VERSION REJECTED the nudge frame as unparseable.
  The wire format has changed. Re-derive it from this build's own debug log
  ('[uds-messaging] Inject messages'), update bin/fm-inbox-post.sh's header and
  frame, and refresh docs/verification/cross-session-messaging.md.
  $(grep -m1 'Failed to parse JSON line' "$DEBUG_LOG" 2>/dev/null)"
[ "$routed" -eq 1 ] || fail "$CLAUDE_VERSION neither routed nor rejected the nudge within 60s;
  the receiver's verdict is unknown, so this guard refuses to report a pass"
pass "$CLAUDE_VERSION accepts and routes the nudge frame"

# Delivery, not merely acceptance: the nudge has to reach the session as a turn,
# carrying the sender name that distinguishes it from a captain message.
delivered=0
waited=0
while [ "$waited" -lt 90 ]; do
  if tmux capture-pane -p -S -200 -t "$LAB" 2>/dev/null | grep -q 'firstmate-board'; then
    delivered=1
    break
  fi
  waited=$((waited + 1))
  sleep 1
done
[ "$delivered" -eq 1 ] || fail "$CLAUDE_VERSION routed the nudge but it never surfaced in the session;
  a held or discarded nudge means the inbound posture changed - check this
  build's crossSessionInbound handling before trusting the push"
pass "$CLAUDE_VERSION delivers the nudge into the session under its own name"
