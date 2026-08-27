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
# It also drives the real bootstrap against a scratch home to pin how the
# board's notify command is published and withdrawn.
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

write_registry_entry() {  # <pid> <socket> <peerProtocol> [<sessionId>]
  printf '{"pid":%s,"sessionId":"%s","cwd":"%s","version":"test","peerProtocol":%s,"kind":"interactive","messagingSocketPath":"%s","name":"fm-test"}\n' \
    "$1" "${4:-11111111-2222-3333-4444-555555555555}" "$HOME_DIR" "$3" "$2" > "$CFG_DIR/sessions/$1.json"
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
assert_grep "registry=$CFG_DIR/sessions" "$HOME_DIR/state/primary-inbox" 'record is missing the registry directory'
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
if "msg_id" in frame:
    assert re.match(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                    frame["msg_id"]), frame["msg_id"]
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
# The uuid-less fallback. msg_id is optional in the harness's own documented
# minimal frame, so a home with no uuid source must still send a valid frame
# rather than lose the push. Only assertable where the kernel uuid source can be
# hidden; say so rather than passing having checked nothing.
if [ -r /proc/sys/kernel/random/uuid ]; then
  echo "skip: /proc uuid source cannot be hidden here, so the uuid-less frame is unverified"
else
  # Shadow uuidgen with a failing stub rather than restricting PATH, so every
  # other tool - the transports included - still resolves and the fallback is
  # what gets exercised instead of the no-transport decline.
  command -v uuidgen >/dev/null 2>&1 \
    || fail 'no uuidgen to shadow; the uuid-less fallback would go vacuous'
  mkdir -p "$TMP_ROOT/nouuidbin"
  printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/nouuidbin/uuidgen"
  chmod 0755 "$TMP_ROOT/nouuidbin/uuidgen"
  rm -f "$CAPTURE"
  start_listener
  PATH="$TMP_ROOT/nouuidbin:$PATH" HOME="$TMP_ROOT" CLAUDE_CONFIG_DIR="$CFG_DIR" FM_HOME="$HOME_DIR" \
    "$POST" --notify logbook || fail 'the uuid-less fallback did not send'
  waited=0
  while [ ! -s "$CAPTURE" ]; do
    waited=$((waited + 1))
    [ "$waited" -lt 200 ] || fail 'the uuid-less fallback posted nothing'
    sleep 0.05
  done
  FM_T_CAP="$CAPTURE" python3 -c '
import json, os
frame = json.loads(open(os.environ["FM_T_CAP"], "rb").read().decode())
assert "msg_id" not in frame, "expected the fallback to omit msg_id: %r" % frame
assert frame["type"] == "user" and frame["msgV"] == 1, frame
assert frame["message"]["content"].startswith("<cross-session-message "), frame
' || fail 'the uuid-less fallback did not produce a valid frame'
  pass 'a home with no uuid source still sends a valid frame instead of losing the push'
fi

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

# A pid gets recycled: the primary exits, and an unrelated session of the same
# OS user lands on its pid, binds the same pid-derived socket path, and writes
# the same registry entry name. Every check so far passes for it, so only the
# session id separates a nudge to this home's primary from one to a stranger.
write_registry_entry "$LIVE_PID" "$SOCK" 1 99999999-8888-7777-6666-555555555555
rm -f "$CAPTURE"
start_listener
out=$(run_post --notify logbook 2>&1)
code=$?
[ "$code" -eq 3 ] || fail "a recycled pid should decline with 3, got $code"
[ -z "$out" ] || fail "a recycled pid should stay silent, printed: $out"
assert_absent "$CAPTURE" 'a recycled pid still received the nudge'
pass 'a recycled pid whose registry entry names another session is not nudged'

# A registry entry that exposes no session id cannot vouch for the record, and
# an empty id on both sides must read as no agreement rather than as a match.
printf '{"pid":%s,"cwd":"%s","version":"test","peerProtocol":1,"kind":"interactive","messagingSocketPath":"%s","name":"fm-test"}\n' \
  "$LIVE_PID" "$HOME_DIR" "$SOCK" > "$CFG_DIR/sessions/$LIVE_PID.json"
rm -f "$HOME_DIR/state/primary-inbox"
CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" run_post --publish || fail 're-publish without a session id failed'
rm -f "$CAPTURE"
start_listener
out=$(run_post --notify logbook 2>&1)
code=$?
[ "$code" -eq 3 ] || fail "a registry entry with no session id should decline with 3, got $code"
[ -z "$out" ] || fail "a registry entry with no session id should stay silent, printed: $out"
assert_absent "$CAPTURE" 'a registry entry with no session id still received the nudge'
pass 'a registry entry that exposes no session id never counts as agreement'

write_registry_entry "$LIVE_PID" "$SOCK" 1
CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" run_post --publish || fail 're-publish failed'

# Publishing required a live registry entry, so a record with none left behind
# it is stale by definition: liveness of the pid and presence of the socket
# alone must never carry a nudge to whatever now holds them.
rm -f "$CFG_DIR/sessions/$LIVE_PID.json"
rm -f "$CAPTURE"
start_listener
out=$(run_post --notify logbook 2>&1)
code=$?
[ "$code" -eq 3 ] || fail "a socket with no live registry entry should decline with 3, got $code"
[ -z "$out" ] || fail "a socket with no live registry entry should stay silent, printed: $out"
assert_absent "$CAPTURE" 'a socket with no live registry entry still received the nudge'
pass 'a record whose registry entry is gone declines instead of trusting liveness alone'

write_registry_entry "$LIVE_PID" "$SOCK" 1

# The board may be spawned from an environment that does not share the
# captain's CLAUDE_CONFIG_DIR, so the record names the registry the publisher
# used and the notifier must look there, not in its own default.
ELSEWHERE="$TMP_ROOT/elsewhere"
mkdir -p "$ELSEWHERE/sessions"
rm -f "$CAPTURE"
start_listener
HOME="$TMP_ROOT" CLAUDE_CONFIG_DIR="$ELSEWHERE" FM_HOME="$HOME_DIR" "$POST" --notify logbook \
  || fail 'a notifier with a different default registry could not use the recorded one'
waited=0
while [ ! -s "$CAPTURE" ]; do
  waited=$((waited + 1))
  [ "$waited" -lt 200 ] || fail 'a notifier with a different default registry posted nothing'
  sleep 0.05
done
pass 'a notifier resolves the entry in the registry the record names, not its own default'

# A record written before the registry field existed still resolves against
# the notifier's own default registry, and only there.
printf 'version=fm-inbox-v1\nsocket=%s\npid=%s\nsession_id=11111111-2222-3333-4444-555555555555\npeer_protocol=1\n' \
  "$SOCK" "$LIVE_PID" > "$HOME_DIR/state/primary-inbox"
rm -f "$CAPTURE"
start_listener
out=$(HOME="$TMP_ROOT" CLAUDE_CONFIG_DIR="$ELSEWHERE" FM_HOME="$HOME_DIR" "$POST" --notify logbook 2>&1)
code=$?
[ "$code" -eq 3 ] || fail "a field-less record with no entry in the default registry should decline with 3, got $code"
assert_absent "$CAPTURE" 'a field-less record was nudged without any registry agreement'
rm -f "$CAPTURE"
start_listener
run_post --notify logbook || fail 'a field-less record did not resolve against the default registry'
waited=0
while [ ! -s "$CAPTURE" ]; do
  waited=$((waited + 1))
  [ "$waited" -lt 200 ] || fail 'a field-less record posted nothing through the default registry'
  sleep 0.05
done
pass 'a record without the registry field falls back to the default registry alone'

CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" run_post --publish || fail 're-publish failed'

rm -f "$HOME_DIR/state/primary-inbox"
start_listener
out=$(run_post --notify logbook 2>&1)
code=$?
[ "$code" -eq 3 ] || fail "no published record should decline with 3, got $code"
[ -z "$out" ] || fail "no published record should stay silent, printed: $out"
assert_absent "$CAPTURE" 'a home with no published record still posted'
pass 'a home that never published an inbox declines quietly'

# A socket file outlives the session that bound it, so the record can look
# entirely healthy while nothing is listening. That must read as the same benign
# staleness as a missing record, not as an error a board would surface.
CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" run_post --publish || fail 're-publish failed'
[ -z "$LISTENER_PID" ] || kill "$LISTENER_PID" 2>/dev/null || true
[ -z "$LISTENER_PID" ] || wait "$LISTENER_PID" 2>/dev/null || true
LISTENER_PID=
rm -f "$SOCK"
python3 -c 'import os,socket,sys; s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.bind(sys.argv[1]); s.close()' "$SOCK"
[ -S "$SOCK" ] || fail 'could not stage an abandoned socket file'
out=$(run_post --notify logbook 2>&1)
code=$?
[ "$code" -eq 3 ] || fail "an abandoned socket should decline with 3, got $code"
[ -z "$out" ] || fail "an abandoned socket should stay silent, printed: $out"
pass 'a socket file whose session is gone declines quietly instead of erroring'

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
  "FM_HOME='$HOME_DIR' '"*"/bin/fm-inbox-post.sh' --notify <channel>") ;;
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

# A home under a path holding a space or a quote is an ordinary path, and the
# board runs the published line through a shell, so the line must survive both
# or the nudge silently never fires.
SPACED_HOME="$TMP_ROOT/my home's dir"
mkdir -p "$SPACED_HOME/state"
CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" run_post --home "$SPACED_HOME" --publish \
  || fail 'publish into a home whose path holds a space failed'
line=$(run_post --home "$SPACED_HOME" --print-notify-command)
runnable=${line%<channel>}logbook
rm -f "$CAPTURE"
start_listener
evalout=$(eval "$runnable --verbose" 2>&1) \
  || fail "the published notify command did not run for a home path holding a space: $runnable
  reason: $evalout"
waited=0
while [ ! -s "$CAPTURE" ]; do
  waited=$((waited + 1))
  [ "$waited" -lt 200 ] || fail 'the published notify command posted nothing from a home path holding a space'
  sleep 0.05
done
pass 'the published notify command survives a home path holding a space and a quote'

# --status is read at a prompt and appended to files by scripts, so its last
# line must end the way every other line does.
run_post --status > "$TMP_ROOT/status" || fail '--status failed'
[ "$(tail -c 1 "$TMP_ROOT/status" | wc -l)" -eq 1 ] \
  || fail '--status output does not end with a newline'
pass '--status ends its last line with a newline'

# --- bootstrap wiring ------------------------------------------------------

# Bootstrap publishes the board's notify command only while a board poll shim is
# armed, so the artifact must track the shim: absent without one, published and
# announced once when it appears, silent while unchanged, withdrawn when the
# last shim goes. The real bootstrap runs against a scratch home for all of it.
BOOT_HOME="$TMP_ROOT/boot-home"
ARTIFACT="$BOOT_HOME/state/logbook-notify-command"
mkdir -p "$BOOT_HOME/state"

# The shim is staged the way the connector arms it - an executable check bound
# by bin/fm-check-register.sh - so bootstrap's poll migration recognizes it as
# intentional instead of quarantining an unbound stray before the nudge runs.
arm_board_poll() {
  printf '#!/bin/sh\nexit 0\n' > "$BOOT_HOME/state/logbook-watch.check.sh"
  chmod 0700 "$BOOT_HOME/state/logbook-watch.check.sh"
  FM_HOME="$BOOT_HOME" "$ROOT/bin/fm-check-register.sh" logbook-watch >/dev/null \
    || fail 'could not register the board poll shim'
}
disarm_board_poll() {
  rm -f "$BOOT_HOME/state/logbook-watch.check.sh" "$BOOT_HOME/state/logbook-watch.check-trust"
}

out=$(FM_HOME="$BOOT_HOME" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
assert_absent "$ARTIFACT" 'bootstrap published a notify command for a home with no board poll'
assert_not_contains "$out" 'logbook answer nudge' 'bootstrap mentioned the nudge for a home with no board poll'
assert_not_contains "$out" 'LOGBOOK_NOTIFY:' 'bootstrap raised a nudge diagnostic for a home with no board poll'
pass 'bootstrap is inert on the nudge while no board poll is armed'

arm_board_poll
out=$(FM_HOME="$BOOT_HOME" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
assert_contains "$out" 'BOOTSTRAP_INFO: logbook answer nudge available' 'bootstrap did not announce the published notify command'
assert_present "$ARTIFACT" 'bootstrap published no notify command for an armed board poll'
if [ "$(uname)" = Darwin ]; then
  mode=$(stat -f %Lp "$ARTIFACT")
else
  mode=$(stat -c %a "$ARTIFACT")
fi
[ "$mode" = 600 ] || fail "the notify command should be private, got mode $mode"
cmp -s "$ARTIFACT" <(FM_HOME="$BOOT_HOME" "$POST" --print-notify-command) \
  || fail "the published notify command differs from the one the script prints:
  artifact: $(cat "$ARTIFACT")
  script:   $(FM_HOME="$BOOT_HOME" "$POST" --print-notify-command)"
pass 'an armed board poll publishes, once, the private notify command the script itself prints'

out=$(FM_HOME="$BOOT_HOME" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
assert_not_contains "$out" 'logbook answer nudge' 'an unchanged notify command was announced again'
assert_present "$ARTIFACT" 'a rerun withdrew an unchanged notify command'
pass 'a rerun with an unchanged notify command stays silent'

# The two failure branches are actionable, so they must not wear the benign
# BOOTSTRAP_INFO class that tells firstmate nothing needs doing.
rm -f "$ARTIFACT"
mkdir "$ARTIFACT"
out=$(FM_HOME="$BOOT_HOME" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
assert_contains "$out" 'LOGBOOK_NOTIFY: answer nudge unavailable - could not publish state/logbook-notify-command' \
  'an unpublishable notify command was not reported as actionable'
assert_not_contains "$out" 'BOOTSTRAP_INFO: logbook answer nudge' 'an unpublishable notify command was reported as a benign fact'
pass 'a notify command that cannot be published is reported as actionable'

disarm_board_poll
out=$(FM_HOME="$BOOT_HOME" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
assert_contains "$out" 'LOGBOOK_NOTIFY: answer nudge off - could not remove stale state/logbook-notify-command' \
  'an unremovable stale notify command was not reported as actionable'
assert_not_contains "$out" 'BOOTSTRAP_INFO: logbook answer nudge' 'an unremovable stale notify command was reported as a benign fact'
pass 'a stale notify command that cannot be removed is reported as actionable'

rmdir "$ARTIFACT"
arm_board_poll
FM_HOME="$BOOT_HOME" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
assert_present "$ARTIFACT" 'bootstrap did not republish once the path was clear'
disarm_board_poll
out=$(FM_HOME="$BOOT_HOME" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
assert_absent "$ARTIFACT" 'disarming the last board poll left the notify command behind'
assert_contains "$out" 'BOOTSTRAP_INFO: logbook answer nudge off - no board poll is armed' 'withdrawing the notify command was not announced'
out=$(FM_HOME="$BOOT_HOME" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
assert_not_contains "$out" 'logbook answer nudge' 'an already-withdrawn notify command was announced again'
pass 'disarming the last board poll withdraws the notify command and says so once'
