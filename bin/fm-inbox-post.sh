#!/usr/bin/env bash
# fm-inbox-post.sh - publish this session's cross-session inbox, and post ONE
# notification-only message into a firstmate session's inbox.
#
# WHY THIS EXISTS. A logbook board holds a captain's answer, but firstmate has
# nothing running that notices it: the answer waits for the board poll's next
# tick. This script is the push that closes that gap. The board spawns it when
# it records a response, and the running firstmate session wakes at once.
#
# NOTIFICATION ONLY - THE ONE RULE THIS FILE EXISTS TO ENFORCE.
# The message says "answers are pending, drain them" and carries NO answer
# content, ever. state/logbook-inbox/, the board poll shim, the answer-draining
# skill, and its ack/resolve/delete ordering remain the single content path,
# untouched. That is what makes a broken or dropped frame degrade to the poll's
# ordinary latency instead of a lost or duplicated answer, and it is why the
# only caller-supplied value in the frame is a charset-validated channel name.
# A future maintainer tempted to "just include the response id" would convert a
# lossless fallback into a second content path that can disagree with the first.
# Do not.
#
# Usage:
#   fm-inbox-post.sh --publish                 # session-start, lock holder only
#   fm-inbox-post.sh --notify <channel>        # the board's configured command
#   fm-inbox-post.sh --print-notify-command    # exact line to configure the board with
#   fm-inbox-post.sh --status                  # human-readable posture of this home
#   fm-inbox-post.sh -h | --help
#
# Options:
#   --home <path>   operate on this home instead of $FM_HOME (also honored as
#                   FM_HOME in the environment, which is how the board sets it)
#   --verbose       print one diagnostic line per outcome to stderr; without it
#                   every outcome is silent, because the board spawns this
#                   command and an expected "nothing to notify" must not log
#
# Exit status (silent by default - the board should ignore it):
#   0  --notify delivered, or --publish wrote/refreshed the record
#   3  nothing to notify: no record, stale record, dead session, unreachable
#      socket, or unsupported peer protocol. Expected, benign, and exactly the
#      case the board poll still covers. --publish also exits 3 when this
#      session has no inbox to publish (any harness that is not claude).
#   2  usage error, including a channel name that fails validation
#   1  an outcome that should not happen: a transport is present but the write
#      itself failed
#
# THE WIRE FRAME - THIS HEADER IS ITS ONE OWNER.
# Transport is a one-shot AF_UNIX stream socket: connect, write, half-close.
# The server never replies and delivery is fire-and-forget, so a wrong frame is
# dropped in silence. Framing is newline-delimited JSON, at most two lines: an
# optional auth line, then exactly one payload line. This script sends no auth
# line - it posts as an unauthenticated peer, which is the board's real
# position, and attests no permission mode (see INBOUND POSTURE below).
#
#   {"msgV":1,"msg_id":"<uuid4>","type":"user",
#    "message":{"role":"user","content":"<envelope>"},"priority":"next"}\n
#
# The content envelope is:
#
#   <cross-session-message from-name="<name>">\nBODY\n</cross-session-message>
#
# Attribute order is FIXED (from, from-session, hop-chain, from-name,
# from-mode) and each is optional; the receiver matches an ordered pattern, so
# an out-of-order attribute makes the whole envelope render as literal text.
# This script sends from-name only.
#
# The frame is undocumented by the vendor as a payload specification, but the
# running binary prints the injection recipe itself: start any session with
# --debug and its log carries an "[uds-messaging] Inject messages" line showing
# this exact shape and both socat and nc -U transports. That printed recipe,
# not disassembly, is the reproduction path for a future version.
# docs/verification/cross-session-messaging.md carries the dated evidence, the
# permission matrix, and the stability risk this transport is accepted under.
#
# INBOUND POSTURE - WHY NOTHING HERE ATTESTS A PERMISSION MODE.
# The receiver decides delivery from its own permission class and the sender's
# self-asserted from-mode. A prompting receiver delivers an unattested message;
# a receiver that bypasses prompts holds one for approval unless its effective
# crossSessionInbound setting is "accept". Attesting from-mode would be a false
# claim by a process that has no permission class, and it now fails a second
# way: an attested mode that does not match the receiver's is held as a
# mismatch. So this script attests nothing and accepts that a bypassing home
# may hold the nudge - a held nudge still costs only poll latency, because the
# answer never travelled in it. docs/configuration.md tells the captain how to
# pin delivery if they want it.
#
# THE PUBLISHED RECORD - THIS HEADER IS ITS ONE OWNER.
# state/primary-inbox is gitignored volatile runtime state, mode 0600, rewritten
# at every locked session start, key=value lines:
#
#   version=fm-inbox-v1
#   socket=<absolute AF_UNIX path>
#   pid=<session pid that owns the socket>
#   session_id=<harness session id>
#   peer_protocol=<integer the session advertised>
#
# ONLY THE LOCK HOLDER PUBLISHES. Several sessions can share one home's cwd and
# nothing in the harness registry distinguishes the real primary among them, so
# fm-session-start.sh calls --publish only on the path where it already holds
# the per-home session lock. Staleness needs no cleanup because every consumer
# revalidates: pid alive, socket present and connectable, and the live registry
# entry still agreeing with the record. A stale record therefore fails quietly
# and the board poll covers the gap.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

RECORD_VERSION=fm-inbox-v1
# Peer protocol versions this script's frame is verified against. A session
# advertising anything else is refused rather than guessed at: the frame is
# undocumented, and a bumped protocol is the one signal available that it may
# have changed. Widen this only alongside refreshed verification evidence.
SUPPORTED_PEER_PROTOCOLS=1
# The from-name the board's nudge carries into the session. Fixed, so the
# receiving firstmate can always tell a board nudge from a captain message.
FROM_NAME=firstmate-board

VERBOSE=0

note() {
  [ "$VERBOSE" -eq 1 ] || return 0
  printf 'fm-inbox-post: %s\n' "$1" >&2
}

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# A channel name reaches this script from the board, which is code firstmate
# does not own. It is the ONLY caller-supplied value that reaches the frame, so
# it is validated rather than escaped: anything outside this charset could
# otherwise close the envelope early and inject arbitrary text - including
# instructions - into the captain's firstmate session.
channel_valid() {
  case "$1" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
    [!A-Za-z0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

# Extract one field from a harness session-registry entry. The registry is one
# line of machine-generated JSON, so a narrow field match is enough and keeps
# this script free of a JSON dependency on its critical path. An unmatched or
# unexpected shape yields empty, and every caller treats empty as refuse.
registry_string_field() {
  sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | sed -n 1p
}

registry_number_field() {
  sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | sed -n 1p
}

registry_dir() {
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
}

# Echo the registry entry path whose messagingSocketPath equals $1, if any.
#
# More than one entry can name the same socket: a session that died without
# cleaning up leaves its entry behind, and the path is reused. Only a LIVE pid
# can actually be listening, so dead entries are skipped rather than taken in
# glob order - otherwise a stale neighbour decides this home's peer protocol and
# pid, and the push stands down against a session that is running fine.
registry_entry_for_socket() {
  local want=$1 dir entry sock pid
  dir=$(registry_dir)
  [ -d "$dir" ] || return 1
  for entry in "$dir"/*.json; do
    [ -f "$entry" ] || continue
    sock=$(registry_string_field "$entry" messagingSocketPath)
    [ "$sock" = "$want" ] || continue
    pid=$(basename "$entry" .json)
    case "$pid" in
      '' | *[!0-9]*) continue ;;
    esac
    kill -0 "$pid" 2>/dev/null || continue
    printf '%s\n' "$entry"
    return 0
  done
  return 1
}

peer_protocol_supported() {
  local want=$1 supported
  case "$want" in
    '' | *[!0-9]*) return 1 ;;
  esac
  for supported in $SUPPORTED_PEER_PROTOCOLS; do
    [ "$want" = "$supported" ] && return 0
  done
  return 1
}

record_field() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | sed -n 1p
}

# --- publish ---------------------------------------------------------------

do_publish() {
  local state=$1 socket entry pid session_id protocol tmp
  socket=${CLAUDE_CODE_MESSAGING_SOCKET:-}
  if [ -z "$socket" ]; then
    # Every harness other than claude has no such socket. The whole feature
    # degrades to the board poll with no branch anywhere else.
    note 'no cross-session inbox in this environment; nothing published'
    return 3
  fi
  case "$socket" in
    /*) ;;
    *) note 'inbox socket path is not absolute; nothing published'; return 3 ;;
  esac
  if ! entry=$(registry_entry_for_socket "$socket"); then
    note 'no session registry entry owns this inbox socket; nothing published'
    return 3
  fi
  pid=$(basename "$entry" .json)
  case "$pid" in
    '' | *[!0-9]*) note 'registry entry does not name a pid; nothing published'; return 3 ;;
  esac
  protocol=$(registry_number_field "$entry" peerProtocol)
  if ! peer_protocol_supported "$protocol"; then
    note "unsupported peer protocol '${protocol:-none}'; nothing published"
    return 3
  fi
  session_id=$(registry_string_field "$entry" sessionId)
  [ -d "$state" ] && [ ! -L "$state" ] || { note 'state directory is unavailable'; return 1; }

  umask 077
  tmp=$(mktemp "$state/.fm-inbox.XXXXXX") || { note 'could not stage the record'; return 1; }
  trap '[ -z "${tmp:-}" ] || rm -f -- "$tmp"' EXIT HUP INT TERM
  {
    printf 'version=%s\n' "$RECORD_VERSION"
    printf 'socket=%s\n' "$socket"
    printf 'pid=%s\n' "$pid"
    printf 'session_id=%s\n' "$session_id"
    printf 'peer_protocol=%s\n' "$protocol"
  } > "$tmp" || { note 'could not write the record'; return 1; }
  chmod 0600 "$tmp" || return 1
  mv -f -- "$tmp" "$state/primary-inbox" || { note 'could not publish the record'; return 1; }
  tmp=
  note "published inbox for pid $pid"
  return 0
}

# --- notify ----------------------------------------------------------------

# Read and revalidate the published record. Echoes "<socket> <pid>" on success.
# Every failure here is the benign "nothing to notify" case.
resolve_inbox() {
  local state=$1 record socket pid protocol entry live_protocol
  record="$state/primary-inbox"
  [ -f "$record" ] && [ ! -L "$record" ] || { note 'no published inbox'; return 3; }
  [ "$(record_field "$record" version)" = "$RECORD_VERSION" ] \
    || { note 'published inbox has an unrecognized record version'; return 3; }
  socket=$(record_field "$record" socket)
  pid=$(record_field "$record" pid)
  protocol=$(record_field "$record" peer_protocol)
  case "$socket" in
    /*) ;;
    *) note 'published inbox has no absolute socket path'; return 3 ;;
  esac
  case "$pid" in
    '' | *[!0-9]*) note 'published inbox has no pid'; return 3 ;;
  esac
  peer_protocol_supported "$protocol" \
    || { note "published inbox advertises unsupported peer protocol '${protocol:-none}'"; return 3; }
  kill -0 "$pid" 2>/dev/null || { note "session $pid is gone"; return 3; }
  [ -S "$socket" ] || { note 'inbox socket is absent'; return 3; }
  # Cross-check the live registry. This catches a recycled pid and, more
  # importantly, a harness upgrade that bumped the protocol under a record this
  # home published before the upgrade.
  if entry=$(registry_entry_for_socket "$socket"); then
    [ "$(basename "$entry" .json)" = "$pid" ] \
      || { note 'live registry disagrees with the published inbox'; return 3; }
    live_protocol=$(registry_number_field "$entry" peerProtocol)
    peer_protocol_supported "$live_protocol" \
      || { note "live session advertises unsupported peer protocol '${live_protocol:-none}'"; return 3; }
  fi
  printf '%s %s\n' "$socket" "$pid"
}

# Build the frame. The body is a fixed template; $1 is the already-validated
# channel name and is the only value interpolated anywhere in it.
#
# The template deliberately contains no double quote and no backslash. Together
# with the channel charset that admits neither, the body needs no JSON escaping
# at all, so the frame is well-formed by construction rather than by a quoting
# routine a later edit could get wrong. A malformed frame would not error - the
# receiver logs "Failed to parse JSON line" and drops it in silence - so keep
# any future wording inside the same character budget.
notify_frame() {
  local channel=$1 uuid body
  uuid=$(frame_uuid) || return 1
  body="Board answers are pending on the $channel channel. Drain the stashed answers through the ordinary board-answer handling now - this notification carries no answer content, and the board poll remains the only content path."
  printf '{"msgV":1,"msg_id":"%s","type":"user","message":{"role":"user","content":"<cross-session-message from-name=\\"%s\\">\\n%s\\n</cross-session-message>"},"priority":"next"}\n' \
    "$uuid" "$FROM_NAME" "$body"
}

frame_uuid() {
  local raw
  if [ -r /proc/sys/kernel/random/uuid ]; then
    raw=$(cat /proc/sys/kernel/random/uuid 2>/dev/null) && [ -n "$raw" ] && {
      printf '%s\n' "$raw"
      return 0
    }
  fi
  if command -v uuidgen >/dev/null 2>&1; then
    raw=$(uuidgen 2>/dev/null) && [ -n "$raw" ] && {
      printf '%s\n' "$raw" | tr '[:upper:]' '[:lower:]'
      return 0
    }
  fi
  return 1
}

# Write one already-built frame to $1. Prefers the two transports the harness
# itself names in its injection recipe, then python3, so a home missing one
# still pushes rather than silently falling back to poll-only latency.
write_frame() {
  local socket=$1 frame=$2
  if command -v socat >/dev/null 2>&1; then
    printf '%s\n' "$frame" | socat -t 5 - "UNIX-CONNECT:$socket" >/dev/null 2>&1
    return
  fi
  if command -v nc >/dev/null 2>&1 && nc -h 2>&1 | grep -q -- '-U'; then
    printf '%s\n' "$frame" | nc -U "$socket" >/dev/null 2>&1
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    FM_INBOX_SOCKET=$socket FM_INBOX_FRAME=$frame python3 -c '
import os, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
try:
    s.connect(os.environ["FM_INBOX_SOCKET"])
    s.sendall((os.environ["FM_INBOX_FRAME"] + "\n").encode())
    s.shutdown(socket.SHUT_WR)
finally:
    s.close()
' >/dev/null 2>&1
    return
  fi
  return 127
}

do_notify() {
  local state=$1 channel=$2 resolved socket frame rc
  if ! channel_valid "$channel"; then
    printf 'error: --notify needs a channel name of letters, digits, dot, dash or underscore\n' >&2
    return 2
  fi
  resolved=$(resolve_inbox "$state") || return 3
  socket=${resolved%% *}
  frame=$(notify_frame "$channel") || { note 'could not build the frame'; return 1; }
  write_frame "$socket" "$frame"
  rc=$?
  if [ "$rc" -eq 127 ]; then
    note 'no socat, nc -U, or python3 available to reach the inbox'
    return 3
  fi
  if [ "$rc" -ne 0 ]; then
    note 'the inbox socket refused the write'
    return 1
  fi
  note "notified $socket about the \"$channel\" channel"
  return 0
}

# --- reporting -------------------------------------------------------------

# The one producer of the command a board is configured to spawn. Bootstrap
# publishes exactly this string into state/logbook-notify-command rather than
# composing its own, so a board and a human are never shown two forms of it.
# <channel> stays a placeholder: a board may watch several channels and
# substitutes its own, and fm-inbox-post.sh validates whatever arrives.
notify_command_line() {
  printf 'FM_HOME=%s %s/bin/fm-inbox-post.sh --notify <channel>\n' "$1" "$FM_ROOT"
}

# The operator's effective inbound setting, or empty when none is set.
#
# Only the user tier is read. A repo may TIGHTEN this setting but never loosen
# it, so an "accept" written into a home's own .claude/settings.json is a no-op
# that would read as protection - which is exactly why firstmate does not write
# one and why this reports the tier that can actually decide.
inbound_user_setting() {
  local file
  file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  [ -f "$file" ] || return 0
  tr -d ' \t\n' < "$file" 2>/dev/null \
    | sed -n 's/.*"crossSessionInbound":"\([a-z]*\)".*/\1/p' | sed -n 1p
}

do_status() {
  local state=$1 home=$2 resolved setting
  if resolved=$(resolve_inbox "$state" 2>/dev/null); then
    printf 'inbox: live (pid %s)\n' "${resolved##* }"
  else
    printf 'inbox: none published for this home\n'
  fi
  printf 'record: %s\n' "$state/primary-inbox"
  setting=$(inbound_user_setting)
  case "$setting" in
    accept) printf 'inbound: delivery pinned by crossSessionInbound=accept\n' ;;
    '') printf 'inbound: unset - delivered while this session prompts for permissions, held for approval while it bypasses them; set crossSessionInbound to accept in %s to pin delivery\n' \
      "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" ;;
    *) printf 'inbound: crossSessionInbound=%s - nudges are not delivered to this session\n' "$setting" ;;
  esac
  printf 'notify command: %s' "$(notify_command_line "$home")"
}

# --- entry point -----------------------------------------------------------

MODE=
CHANNEL=
HOME_OVERRIDE=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --publish) MODE=publish ;;
    --notify)
      MODE=notify
      shift
      [ "$#" -gt 0 ] || { printf 'error: --notify needs a channel name\n' >&2; exit 2; }
      CHANNEL=$1
      ;;
    --print-notify-command) MODE=print-notify-command ;;
    --status) MODE=status ;;
    --home)
      shift
      [ "$#" -gt 0 ] || { printf 'error: --home needs a path\n' >&2; exit 2; }
      HOME_OVERRIDE=$1
      ;;
    --verbose) VERBOSE=1 ;;
    -h | --help) usage; exit 0 ;;
    *) printf 'error: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$MODE" ] || { usage >&2; exit 2; }

FM_HOME="${HOME_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

case "$MODE" in
  publish) do_publish "$STATE" ;;
  notify) do_notify "$STATE" "$CHANNEL" ;;
  print-notify-command) notify_command_line "$FM_HOME" ;;
  status) do_status "$STATE" "$FM_HOME" ;;
esac
