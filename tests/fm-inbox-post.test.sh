#!/usr/bin/env bash
# tests/fm-inbox-post.test.sh - the board-answer nudge, pinned without a harness.
#
# bin/fm-inbox-post.sh publishes a session's cross-session inbox and posts ONE
# notification-only message into it, so a board that records a captain's answer
# wakes the running session instead of leaving the answer for the next poll.
# Two properties carry the whole safety story and are what this file exists to
# hold still:
#
#   1. THE NUDGE CARRIES NO ANSWER. The frame's body names a channel and says
#      "drain them"; nothing else from the caller reaches it. That is what makes
#      a broken or dropped frame cost poll latency instead of an answer.
#   2. EVERY UNCERTAIN PATH DEGRADES QUIETLY. No record, a stale one, a dead
#      session, a socket that is gone, or a peer protocol this frame was never
#      verified against must all decline silently, never post, and never fail
#      loudly enough to make a board treat it as an error.
#
# It drives the real script end to end over a REAL AF_UNIX listener and REAL
# live/dead pids, so the frame asserted here is the frame that goes on the wire.
# It deliberately never asserts the script's own source text. The companion
# tests/fm-inbox-post-live-e2e.test.sh proves the same frame is ACCEPTED by an
# installed harness - a claim no harness-free test can make.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

POST="$ROOT/bin/fm-inbox-post.sh"
TMP_ROOT=$(fm_test_tmproot fm-inbox-post-tests)
HOME_DIR="$TMP_ROOT/home"
CFG_DIR="$TMP_ROOT/claude"
mkdir -p "$HOME_DIR/state" "$CFG_DIR/sessions"

# A stand-in for a live session: a real process we own, so kill -0 answers
# honestly, plus the registry entry a real harness writes for it.
LIVE_PID=
SOCK="$TMP_ROOT/live.sock"
LISTENER_PID=
CAPTURE="$TMP_ROOT/captured"

cleanup() {
  [ -z "$LIVE_PID" ] || kill "$LIVE_PID" 2>/dev/null || true
  [ -z "$LISTENER_PID" ] || kill "$LISTENER_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

write_registry_entry() {  # <pid> <socket> <peerProtocol>
  printf '{"pid":%s,"sessionId":"11111111-2222-3333-4444-555555555555","cwd":"%s","version":"test","peerProtocol":%s,"kind":"interactive","messagingSocketPath":"%s","name":"fm-test"}\n' \
    "$1" "$HOME_DIR" "$3" "$2" > "$CFG_DIR/sessions/$1.json"
}

# One-shot AF_UNIX listener: accept a single connection, store the first line,
# exit. This is the receiving half of the real transport, so a frame that fails
# to arrive here would have failed to arrive at a harness too.
start_listener() {
  [ -z "$LISTENER_PID" ] || kill "$LISTENER_PID" 2>/dev/null || true
  [ -z "$LISTENER_PID" ] || wait "$LISTENER_PID" 2>/dev/null || true
  rm -f "$SOCK" "$CAPTURE"
  FM_T_SOCK="$SOCK" FM_T_OUT="$CAPTURE" python3 -c '
import os, socket
p = os.environ["FM_T_SOCK"]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(p); s.listen(1); s.settimeout(20)
conn, _ = s.accept()
data = b""
while b"\n" not in data:
    chunk = conn.recv(65536)
    if not chunk:
        break
    data += chunk
with open(os.environ["FM_T_OUT"], "wb") as fh:
    fh.write(data.split(b"\n")[0])
conn.close(); s.close()
' 2>/dev/null &
  LISTENER_PID=$!
  local waited=0
  while [ ! -S "$SOCK" ]; do
    waited=$((waited + 1))
    [ "$waited" -lt 200 ] || fail 'listener never bound its socket'
    sleep 0.05
  done
}

run_post() {  # runs the real script against the fixture home and registry
  HOME="$TMP_ROOT" CLAUDE_CONFIG_DIR="$CFG_DIR" FM_HOME="$HOME_DIR" "$POST" "$@"
}

# --- publish ---------------------------------------------------------------

out=$(CLAUDE_CODE_MESSAGING_SOCKET='' run_post --publish 2>&1)
code=$?
[ "$code" -eq 3 ] || fail "publish without an inbox socket should decline with 3, got $code"
[ -z "$out" ] || fail "publish without an inbox socket should stay silent, printed: $out"
assert_absent "$HOME_DIR/state/primary-inbox" 'publish without an inbox socket wrote a record'
pass 'a harness with no cross-session inbox publishes nothing, silently'

out=$(CLAUDE_CODE_MESSAGING_SOCKET="$TMP_ROOT/unowned.sock" run_post --publish 2>&1)
code=$?
[ "$code" -eq 3 ] || fail "publish for an unregistered socket should decline with 3, got $code"
assert_absent "$HOME_DIR/state/primary-inbox" 'publish for an unregistered socket wrote a record'
pass 'a socket no registry entry owns publishes nothing'

# A live pid the fixture owns, so pid-liveness checks are real rather than mocked.
sleep 300 &
LIVE_PID=$!

write_registry_entry "$LIVE_PID" "$SOCK" 1
CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" run_post --publish || fail 'publish with a registered socket failed'
assert_present "$HOME_DIR/state/primary-inbox" 'publish wrote no record'
assert_grep "socket=$SOCK" "$HOME_DIR/state/primary-inbox" 'record is missing the socket'
assert_grep "pid=$LIVE_PID" "$HOME_DIR/state/primary-inbox" 'record is missing the pid'
assert_grep 'peer_protocol=1' "$HOME_DIR/state/primary-inbox" 'record is missing the peer protocol'
assert_grep 'session_id=11111111-' "$HOME_DIR/state/primary-inbox" 'record is missing the session id'
if [ "$(uname)" = Darwin ]; then
  mode=$(stat -f %Lp "$HOME_DIR/state/primary-inbox")
else
  mode=$(stat -c %a "$HOME_DIR/state/primary-inbox")
fi
[ "$mode" = 600 ] || fail "record should be private, got mode $mode"
pass 'the lock holder publishes a private record naming its socket, pid and protocol'

# THE SECTION-7 GUARD, publish half. The frame is undocumented; a bumped peer
# protocol is the only signal available that it may have changed shape, so an
# unverified protocol must refuse rather than guess.
rm -f "$HOME_DIR/state/primary-inbox"
write_registry_entry "$LIVE_PID" "$SOCK" 7
out=$(CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" run_post --publish 2>&1)
code=$?
[ "$code" -eq 3 ] || fail "publish on an unverified peer protocol should decline with 3, got $code"
[ -z "$out" ] || fail "publish on an unverified peer protocol should stay silent, printed: $out"
assert_absent "$HOME_DIR/state/primary-inbox" 'publish on an unverified peer protocol wrote a record'
pass 'an unverified peer protocol refuses to publish rather than guessing at the frame'

write_registry_entry "$LIVE_PID" "$SOCK" 1
CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" run_post --publish || fail 're-publish failed'

# --- notify: the quiet-decline paths ---------------------------------------

start_listener

out=$(run_post --notify 'bad channel' 2>&1)
code=$?
[ "$code" -eq 2 ] || fail "a hostile channel name should be a usage error, got $code"
assert_absent "$CAPTURE" 'a rejected channel name still reached the socket'
pass 'a channel name outside the safe charset is refused before anything is sent'

out=$(run_post --notify 'x"></cross-session-message><injected' 2>&1)
code=$?
[ "$code" -eq 2 ] || fail "an envelope-closing channel name should be refused, got $code"
assert_absent "$CAPTURE" 'an envelope-closing channel name still reached the socket'
pass 'a channel name that would close the envelope early cannot reach the frame'

# --- notify: the delivered path --------------------------------------------

capture_body() {  # <channel> -> writes the envelope body to stdout
  rm -f "$CAPTURE"
  start_listener
  run_post --notify "$1" || fail "notify with channel $1 failed"
  local waited=0
  while [ ! -s "$CAPTURE" ]; do
    waited=$((waited + 1))
    [ "$waited" -lt 200 ] || fail "the listener captured no frame for channel $1"
    sleep 0.05
  done
  # The frame must be well-formed JSON in the exact envelope the receiver
  # parses. A malformed frame is dropped in SILENCE by the real receiver, so a
  # shape regression would otherwise surface only as answers quietly ceasing to
  # arrive - which is the failure this whole feature exists to prevent.
  FM_T_CAP="$CAPTURE" python3 -c '
import json, os, re
frame = json.loads(open(os.environ["FM_T_CAP"], "rb").read().decode())
assert frame["type"] == "user", frame.get("type")
assert frame["msgV"] == 1, frame.get("msgV")
assert frame["priority"] == "next", frame.get("priority")
assert re.match(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                frame["msg_id"]), frame["msg_id"]
assert frame["message"]["role"] == "user", frame["message"].get("role")
content = frame["message"]["content"]
# The receiver matches an ORDERED attribute pattern; an out-of-order or
# unexpected attribute makes the whole envelope render as literal text instead.
m = re.match(
    r"^<cross-session-message"
    r"(?: from=\"[^\"]+\")?(?: from-session=\"[^\"]+\")?(?: hop-chain=\"[^\"]+\")?"
    r"(?: from-name=\"([^\"<>\n\r]+)\")?(?: from-mode=\"[^\"]+\")?"
    r">\n([\s\S]*)\n</cross-session-message>$",
    content)
assert m, "envelope does not match the receiver pattern: %r" % content
assert m.group(1), "the nudge must identify itself by name: %r" % content
body = m.group(2)
# chr(34)/chr(92) are the quote and backslash the body is never escaped for, so
# either one would silently break the frame it is interpolated into.
for forbidden in ["{", "}", chr(34), chr(92)]:
    assert forbidden not in body, "body carries %r: %r" % (forbidden, body)
print(body)
' || fail "the frame for channel $1 is not the shape the receiver accepts"
}

body_a=$(capture_body logbook)
pass 'a live inbox receives a well-formed nudge in the envelope the receiver parses'

case "$body_a" in
  *logbook*) ;;
  *) fail "the nudge does not name its channel: $body_a" ;;
esac
case "$body_a" in
  *[Dd]rain*) ;;
  *) fail "the nudge does not tell the session to drain the answers: $body_a" ;;
esac
case "$body_a" in
  *'carries no answer content'*) ;;
  *) fail "the nudge does not state that it carries no answer: $body_a" ;;
esac
pass 'the nudge names its channel, says to drain, and states that it carries none'

# THE PROPERTY THE WHOLE DESIGN RESTS ON. Send a second nudge on a different
# channel: the two bodies must be identical once the channel token is removed.
# Anything else that varied would be caller-supplied content riding along on a
# transport whose whole safety argument is that it carries none.
body_b=$(capture_body board-2.x)
norm_a=${body_a//logbook/CHANNEL}
norm_b=${body_b//board-2.x/CHANNEL}
[ "$norm_a" = "$norm_b" ] || fail "the nudge body varies by more than its channel:
  a: $norm_a
  b: $norm_b"
pass 'the channel name is the only part of the nudge a caller can influence'

# --- notify: staleness ------------------------------------------------------

rm -f "$CAPTURE"
start_listener
kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true
DEAD_PID=$LIVE_PID
LIVE_PID=
out=$(run_post --notify logbook 2>&1)
code=$?
[ "$code" -eq 3 ] || fail "a record naming a dead session should decline with 3, got $code"
[ -z "$out" ] || fail "a stale record should stay silent, printed: $out"
assert_absent "$CAPTURE" "a record naming dead pid $DEAD_PID still posted"
pass 'a record whose session is gone declines quietly and posts nothing'

sleep 300 &
LIVE_PID=$!
write_registry_entry "$LIVE_PID" "$SOCK" 1
CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" run_post --publish || fail 're-publish failed'
rm -f "$CAPTURE"
start_listener

# THE SECTION-7 GUARD, send half. The record was published before an upgrade;
# the live session now advertises a protocol this frame was never verified
# against, so the push must stand down and leave the answer to the poll.
write_registry_entry "$LIVE_PID" "$SOCK" 9
out=$(run_post --notify logbook 2>&1)
code=$?
[ "$code" -eq 3 ] || fail "a live protocol bump should decline with 3, got $code"
[ -z "$out" ] || fail "a live protocol bump should stay silent, printed: $out"
assert_absent "$CAPTURE" 'a live protocol bump still posted a frame'
pass 'a harness upgrade that bumps the peer protocol stands the push down'

write_registry_entry "$LIVE_PID" "$SOCK" 1

# A session that died without cleaning up leaves its registry entry behind while
# a live session owns the same socket path. The dead neighbour must not decide
# this home's pid or peer protocol, or the push stands down against a session
# that is running fine.
STALE_PID=$((LIVE_PID - 1))
[ "$STALE_PID" -gt 1 ] || STALE_PID=$((LIVE_PID + 1))
while kill -0 "$STALE_PID" 2>/dev/null; do STALE_PID=$((STALE_PID - 1)); done
write_registry_entry "$STALE_PID" "$SOCK" 9
rm -f "$HOME_DIR/state/primary-inbox"
CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" run_post --publish \
  || fail 'a dead registry entry sharing the socket blocked publishing'
assert_grep "pid=$LIVE_PID" "$HOME_DIR/state/primary-inbox" \
  'publish took a dead session over the live one'
assert_grep 'peer_protocol=1' "$HOME_DIR/state/primary-inbox" \
  "publish took the dead entry's peer protocol"
rm -f "$CAPTURE"
start_listener
run_post --notify logbook || fail 'a dead registry entry sharing the socket blocked the nudge'
waited=0
while [ ! -s "$CAPTURE" ]; do
  waited=$((waited + 1))
  [ "$waited" -lt 200 ] || fail 'a dead registry entry sharing the socket suppressed the nudge'
  sleep 0.05
done
rm -f "$CFG_DIR/sessions/$STALE_PID.json"
pass 'a dead session that still claims the socket does not speak for the live one'

rm -f "$HOME_DIR/state/primary-inbox"
start_listener
out=$(run_post --notify logbook 2>&1)
code=$?
[ "$code" -eq 3 ] || fail "no published record should decline with 3, got $code"
[ -z "$out" ] || fail "no published record should stay silent, printed: $out"
assert_absent "$CAPTURE" 'a home with no published record still posted'
pass 'a home that never published an inbox declines quietly'

printf 'version=fm-inbox-v0\nsocket=%s\npid=%s\npeer_protocol=1\n' "$SOCK" "$LIVE_PID" \
  > "$HOME_DIR/state/primary-inbox"
out=$(run_post --notify logbook 2>&1)
code=$?
[ "$code" -eq 3 ] || fail "an unrecognized record version should decline with 3, got $code"
assert_absent "$CAPTURE" 'an unrecognized record version still posted'
pass 'a record written by a different record version is not acted on'

# --- the command the board is told to run ----------------------------------

line=$(run_post --print-notify-command)
case "$line" in
  *"FM_HOME=$HOME_DIR"*"/bin/fm-inbox-post.sh --notify <channel>") ;;
  *) fail "the published notify command is not the form a board can configure: $line" ;;
esac
pass 'the notify command names the home and leaves the channel for the board to fill in'

# A board substitutes its own channel into that template, so the template must
# actually run once it does. Prove it rather than assuming the shape is right.
runnable=${line%<channel>}logbook
CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" run_post --publish || fail 're-publish failed'
rm -f "$CAPTURE"
start_listener
evalout=$(eval "$runnable --verbose" 2>&1) \
  || fail "the published notify command did not run: $runnable
  reason: $evalout"
waited=0
while [ ! -s "$CAPTURE" ]; do
  waited=$((waited + 1))
  [ "$waited" -lt 200 ] || fail 'the published notify command posted nothing'
  sleep 0.05
done
pass 'the published notify command delivers once a board fills in its channel'
