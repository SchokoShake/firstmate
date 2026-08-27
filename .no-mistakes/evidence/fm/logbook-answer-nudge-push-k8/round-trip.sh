#!/usr/bin/env bash
# Manual end-to-end evidence for the board-answer nudge (test phase, no-mistakes).
# Mirrors tests/fm-inbox-post-live-e2e.test.sh but keeps reviewer-visible
# artifacts: the throwaway session's pane, the receiver's own [uds-messaging]
# log lines, the exact bytes on the wire, --status, and the stale decline.
# Starts a THROWAWAY Claude Code session in a scratch dir. Never touches the
# captain's live sessions.
set -u
ROOT=$1
EVID=$2
POST="$ROOT/bin/fm-inbox-post.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-inbox-evidence.XXXXXX")
HOME_DIR="$TMP/home"; LAB_DIR="$TMP/lab"; DEBUG_LOG="$TMP/receiver.log"
mkdir -p "$HOME_DIR/state" "$LAB_DIR"
LAB="fm-inbox-evidence-$$"
SESSION_NAME="fm-inbox-evidence-$$"
cleanup() { tmux kill-session -t "$LAB" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

registry_dir() { printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"; }
probe_entry() {
  local entry
  for entry in "$(registry_dir)"/*.json; do
    [ -f "$entry" ] || continue
    FM_T_ENTRY="$entry" FM_T_NAME="$SESSION_NAME" python3 -c '
import json, os, sys
try: d = json.load(open(os.environ["FM_T_ENTRY"]))
except Exception: sys.exit(1)
sys.exit(0 if d.get("name") == os.environ["FM_T_NAME"] else 1)' 2>/dev/null || continue
    printf '%s\n' "$entry"; return 0
  done
  return 1
}

T="$EVID/round-trip-transcript.md"
{
  echo "# Board-answer nudge: real round trip into a throwaway Claude Code session"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)  Host: $(uname -srm)  Harness: $(claude --version 2>&1 | head -1)"
  echo "Throwaway session name: $SESSION_NAME (registry entries of the captain's own sessions are never touched)."
  echo
} > "$T"

echo "## 1. Start the throwaway session" >> "$T"
tmux new-session -d -s "$LAB" -x 160 -y 45 -c "$LAB_DIR" \
  "claude --name $SESSION_NAME --debug --debug-file $DEBUG_LOG" || { echo "FAIL: tmux start" >> "$T"; exit 1; }
ENTRY=; waited=0
while [ "$waited" -lt 120 ]; do
  if ENTRY=$(probe_entry); then break; fi
  if tmux capture-pane -p -t "$LAB" 2>/dev/null | grep -q 'I trust this folder'; then tmux send-keys -t "$LAB" Enter; fi
  waited=$((waited + 1)); sleep 1
done
[ -n "$ENTRY" ] || { echo "FAIL: no registry entry" >> "$T"; exit 1; }
{
  echo
  echo '```'
  echo "\$ cat $ENTRY   # the session registry entry (pid, socket, peerProtocol)"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps({k:d[k] for k in ("pid","sessionId","version","peerProtocol","messagingSocketPath","name") if k in d}, indent=2))' "$ENTRY"
  echo '```'
  echo
} >> "$T"
SOCK=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["messagingSocketPath"])' "$ENTRY")

echo "## 2. Publish the inbox record exactly as fm-session-start.sh does (lock-holder path)" >> "$T"
{
  echo
  echo '```'
  echo "\$ CLAUDE_CODE_MESSAGING_SOCKET=$SOCK FM_HOME=$HOME_DIR bin/fm-inbox-post.sh --publish --verbose"
  CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" FM_HOME="$HOME_DIR" "$POST" --publish --verbose 2>&1; echo "exit=$?"
  echo
  echo "\$ cat $HOME_DIR/state/primary-inbox"
  cat "$HOME_DIR/state/primary-inbox"
  echo "\$ ls -l $HOME_DIR/state/primary-inbox"
  ls -l "$HOME_DIR/state/primary-inbox" | sed "s|$TMP|<tmp>|"
  echo '```'
  echo
} >> "$T"

echo "## 3. --status as an operator would see it in this home" >> "$T"
{
  echo
  echo '```'
  echo "\$ FM_HOME=$HOME_DIR bin/fm-inbox-post.sh --status"
  FM_HOME="$HOME_DIR" "$POST" --status
  echo '```'
  echo
} >> "$T"

echo "## 4. The board's configured command fires (the exact published line, channel filled in)" >> "$T"
LINE=$(FM_HOME="$HOME_DIR" "$POST" --print-notify-command)
RUNNABLE=${LINE%<channel>}logbook
before=$(grep -c 'uds-messaging' "$DEBUG_LOG" 2>/dev/null || true)
{
  echo
  echo '```'
  echo "\$ cat $HOME_DIR/state/logbook-notify-command-equivalent   # from --print-notify-command"
  echo "$LINE"
  echo "\$ $RUNNABLE --verbose"
  eval "$RUNNABLE --verbose" 2>&1; echo "exit=$?"
  echo '```'
  echo
} >> "$T"

echo "## 5. The receiver's verdict (its own --debug log, not the sender's exit status)" >> "$T"
routed=0; waited=0
while [ "$waited" -lt 60 ]; do
  grep -q 'Failed to parse JSON line' "$DEBUG_LOG" 2>/dev/null && break
  grep -q 'Routed user message to queue' "$DEBUG_LOG" 2>/dev/null && { routed=1; break; }
  waited=$((waited + 1)); sleep 1
done
{
  echo
  echo '```'
  grep -n 'uds-messaging\|Routed user message\|cross-session\|Failed to parse' "$DEBUG_LOG" | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-400
  echo '```'
  echo
  [ "$routed" -eq 1 ] && echo "Receiver ROUTED the frame (no parse failure)." || echo "Receiver did NOT report routing within 60s."
  echo
} >> "$T"

echo "## 6. The nudge surfaces in the throwaway session's pane under its own sender name" >> "$T"
delivered=0; waited=0
while [ "$waited" -lt 90 ]; do
  tmux capture-pane -p -S -200 -t "$LAB" 2>/dev/null | grep -q 'firstmate-board' && { delivered=1; break; }
  waited=$((waited + 1)); sleep 1
done
sleep 8  # let the model's reply render
tmux capture-pane -p -S -200 -t "$LAB" 2>/dev/null | sed 's/[[:space:]]*$//' | grep -v '^$' > "$EVID/throwaway-session-pane.txt"
{
  echo
  [ "$delivered" -eq 1 ] && echo "Delivered: the pane shows the message from \`firstmate-board\`." || echo "NOT delivered within 90s."
  echo
  echo '```text'
  cat "$EVID/throwaway-session-pane.txt"
  echo '```'
  echo
} >> "$T"

echo "## 7. Degrade path: session gone -> the same command declines quietly (exit 3, nothing sent, board poll covers it)" >> "$T"
tmux kill-session -t "$LAB" 2>/dev/null || true
sleep 3
{
  echo
  echo '```'
  echo "\$ (throwaway session killed)"
  echo "\$ $RUNNABLE            # silent by default"
  out=$(eval "$RUNNABLE" 2>&1); rc=$?; printf '%s' "$out"; echo "exit=$rc (stdout+stderr: '${out}')"
  echo "\$ $RUNNABLE --verbose"
  eval "$RUNNABLE --verbose" 2>&1; echo "exit=$?"
  echo "\$ FM_HOME=$HOME_DIR bin/fm-inbox-post.sh --status"
  FM_HOME="$HOME_DIR" "$POST" --status
  echo '```'
  echo
} >> "$T"

echo "## 8. The exact bytes on the wire (captured by a raw AF_UNIX listener standing in for the session)" >> "$T"
CFG="$TMP/cfg"; mkdir -p "$CFG/sessions" "$TMP/home2/state"
sleep 300 & LIVE=$!
SOCK2="$TMP/probe.sock"; CAP="$TMP/frame"
printf '{"pid":%s,"sessionId":"aaaaaaaa-0000-0000-0000-000000000000","peerProtocol":1,"messagingSocketPath":"%s","name":"probe"}\n' "$LIVE" "$SOCK2" > "$CFG/sessions/$LIVE.json"
FM_T_SOCK="$SOCK2" FM_T_OUT="$CAP" python3 -c '
import os, socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(os.environ["FM_T_SOCK"]); s.listen(1); s.settimeout(20)
c, _ = s.accept(); data = b""
while b"\n" not in data:
    ch = c.recv(65536)
    if not ch: break
    data += ch
open(os.environ["FM_T_OUT"], "wb").write(data); c.close(); s.close()' &
LST=$!
while [ ! -S "$SOCK2" ]; do sleep 0.05; done
CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_MESSAGING_SOCKET="$SOCK2" FM_HOME="$TMP/home2" "$POST" --publish
CLAUDE_CONFIG_DIR="$CFG" FM_HOME="$TMP/home2" "$POST" --notify logbook
wait "$LST" 2>/dev/null || true
kill "$LIVE" 2>/dev/null || true
{
  echo
  echo '```json'
  cat "$CAP"
  echo '```'
  echo
  echo "Decoded content field:"
  echo
  echo '```text'
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["message"]["content"])' "$CAP"
  echo '```'
  echo
  echo "Note: no answer id, no answer text - only the validated channel name is caller-supplied."
} >> "$T"
cp "$DEBUG_LOG" "$EVID/throwaway-session-debug.log" 2>/dev/null || true
echo "done: $T"
