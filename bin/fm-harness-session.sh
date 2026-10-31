#!/usr/bin/env bash
# fm-harness-session.sh - the durable record of the conversation a worker's
# harness is running, so a worker that a machine restart stopped can be brought
# back into that same conversation (bin/fm-control.sh revive). ONE owner for the
# record's format, its writer, and the rule deciding whether it may be resumed.
#
# Saved continuously, never only at shutdown. A machine can stop without any
# shutdown step running - a crash, an out-of-memory kill, a VM that is simply
# terminated - so the per-task turn-boundary hooks bin/fm-spawn.sh installs
# rewrite this record at every turn, and whatever was last written is what
# survives the stop.
#
# state/<id>.harness-session, one key=value per line:
#   harness     the verified adapter whose session this is (claude today)
#   session_id  the harness's own session id (a UUID for claude)
#   gen         the busy-state generation of the agent incarnation that wrote it
#   cwd         the session's working directory, from the hook payload
#   transcript  the session's conversation file, from the hook payload
#   event       the hook event that last wrote it
#   recorded    when it was last written, ISO-8601 UTC
#
# Writers and lifetime:
#   - Only `record`, run from a turn-boundary hook, writes it, and only while
#     the generation the hook was installed with is the task's current one
#     (state/<id>.busy-gen, bin/fm-busy-lib.sh), so a superseded agent can never
#     overwrite its replacement's conversation. bin/fm-spawn.sh also gates the
#     hook to the worker's own agent, the one process carrying the task's
#     GOTMPDIR, so another session opened in the same worktree never replaces
#     the recorded conversation.
#   - bin/fm-spawn.sh removes it before every launch that starts a NEW
#     conversation (a fresh spawn, or a relaunch that does not resume), and
#     keeps it for a resume, whose session keeps its id and rewrites the record
#     from its own hooks.
#   - bin/fm-teardown.sh removes it with the task's other records.
#   - Nothing removes it when a session ends: a machine shutdown ends every
#     session, and that is exactly when the record must survive.
#
# Which adapters: fm_control_harness_resume_mode (bin/fm-control-lib.sh) owns
# which adapters resume a recorded session. Today that is claude alone, whose
# hook payload carries session_id and transcript_path, and whose
# `claude --resume <session-id>` run in the worktree continues that
# conversation under the same id (docs/verification/runtime-backends.md
# "Restart recovery").
#
# Usage:
#   fm-harness-session.sh record <state-dir> <task-id> --gen <gen> --harness <name>
#       The hook writer. Reads the hook's JSON payload on stdin. It is silent and
#       always exits 0, because a hook's stdout can reach the conversation and a
#       failing hook must never break the harness's own turn; a payload it cannot
#       use, a stale generation, or an adapter with no resume path writes nothing.
#   fm-harness-session.sh resumable <state-dir> <task-id>
#       Prints the session id and exits 0 when bin/fm-control.sh revive may resume
#       the task's recorded conversation; otherwise prints why not and exits 1.
#
# Source-safe: sourcing defines the functions below and runs nothing.

FM_HARNESS_SESSION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F fm_control_harness_resume_mode >/dev/null 2>&1; then
  # shellcheck source=bin/fm-control-lib.sh
  . "$FM_HARNESS_SESSION_LIB_DIR/fm-control-lib.sh"
fi
if ! declare -F fm_busy_current_gen >/dev/null 2>&1; then
  # shellcheck source=bin/fm-busy-lib.sh
  . "$FM_HARNESS_SESSION_LIB_DIR/fm-busy-lib.sh"
fi

fm_harness_session_path() {  # <state-dir> <id>
  printf '%s/%s.harness-session' "$1" "$2"
}

# The last value of <key> in a key=value file, the same rule fm_meta_get
# applies to task metadata.
fm_harness_session_get() {  # <file> <key>
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_harness_session_uuid_valid() {  # <value>
  [[ "${1-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# fm_harness_session_payload: the hook payload on stdin, as four lines -
# session_id, transcript_path, cwd, hook_event_name - each empty when absent,
# not a string, or carrying a control character. Fails on input that is not a
# JSON object. A real JSON parse, so text quoted inside the prompt can never be
# mistaken for the payload's own fields.
fm_harness_session_payload() {
  command -v perl >/dev/null 2>&1 || return 1
  perl -MJSON::PP -e '
    binmode STDIN; binmode STDOUT, ":encoding(UTF-8)";
    local $/; my $raw = <STDIN>;
    my $d = eval { JSON::PP->new->utf8->decode($raw) };
    exit 1 unless ref $d eq "HASH";
    for my $k (qw(session_id transcript_path cwd hook_event_name)) {
      my $v = $d->{$k};
      $v = "" unless defined $v && !ref $v;
      $v = "" if $v =~ /[\x00-\x1f\x7f]/;
      print "$v\n";
    }
  ' 2>/dev/null
}

fm_harness_session_record() {  # <state-dir> <id> <gen> <harness>   (payload on stdin)
  local state=${1-} id=${2-} gen=${3-} harness=${4-} family mode current parsed
  local sid='' transcript='' cwd='' event='' path tmp
  [ -d "$state" ] || return 0
  fm_busy_token_valid "$id" || return 0
  fm_busy_token_valid "$gen" || return 0
  family=$(fm_control_harness_family "$harness" 2>/dev/null) || return 0
  mode=$(fm_control_harness_resume_mode "$family" 2>/dev/null) || return 0
  [ "$mode" = session-id ] || return 0
  current=$(fm_busy_current_gen "$state" "$id" 2>/dev/null) || return 0
  [ "$current" = "$gen" ] || return 0
  parsed=$(fm_harness_session_payload) || return 0
  {
    IFS= read -r sid
    IFS= read -r transcript
    IFS= read -r cwd
    IFS= read -r event
  } <<EOF
$parsed
EOF
  fm_harness_session_uuid_valid "$sid" || return 0
  case "$event" in *[!A-Za-z]*) event= ;; esac
  path=$(fm_harness_session_path "$state" "$id")
  tmp="$path.tmp.${BASHPID:-$$}"
  if {
    printf 'harness=%s\n' "$family"
    printf 'session_id=%s\n' "$sid"
    printf 'gen=%s\n' "$gen"
    printf 'cwd=%s\n' "$cwd"
    printf 'transcript=%s\n' "$transcript"
    printf 'event=%s\n' "$event"
    printf 'recorded=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$path" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# fm_harness_session_clear: drop the record because the next agent starts a
# new conversation.
fm_harness_session_clear() {  # <state-dir> <id>
  rm -f "$(fm_harness_session_path "$1" "$2")" 2>/dev/null || true
}

# A path in canonical form when it exists, so a symlinked spelling of the
# worktree still compares equal; unchanged otherwise.
fm_harness_session_canonical() {  # <path>
  local p=${1%/}
  if [ -d "$p" ]; then
    (cd "$p" 2>/dev/null && pwd -P) || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

# fm_harness_session_resumable: may revive resume this task's recorded
# conversation? On success sets FM_HARNESS_SESSION_ID; on refusal sets
# FM_HARNESS_SESSION_REASON to a plain-language reason and returns 1.
FM_HARNESS_SESSION_ID=
FM_HARNESS_SESSION_REASON=
fm_harness_session_resumable() {  # <state-dir> <id>
  local state=$1 id=$2 meta record recorded family mode sid cwd transcript wt
  FM_HARNESS_SESSION_ID=
  FM_HARNESS_SESSION_REASON=
  meta="$state/$id.meta"
  recorded=$(fm_harness_session_get "$meta" harness)
  if ! family=$(fm_control_harness_family "$recorded" 2>/dev/null) \
     || ! mode=$(fm_control_harness_resume_mode "$family" 2>/dev/null); then
    FM_HARNESS_SESSION_REASON="its recorded harness '${recorded:-none}' has no verified resume path"
    return 1
  fi
  if [ "$mode" != session-id ]; then
    FM_HARNESS_SESSION_REASON="$family has no verified way to resume a recorded conversation"
    return 1
  fi
  record=$(fm_harness_session_path "$state" "$id")
  if [ ! -f "$record" ]; then
    FM_HARNESS_SESSION_REASON="no conversation was recorded for its current agent"
    return 1
  fi
  if [ "$(fm_harness_session_get "$record" harness)" != "$family" ]; then
    FM_HARNESS_SESSION_REASON="the recorded conversation belongs to another harness"
    return 1
  fi
  sid=$(fm_harness_session_get "$record" session_id)
  if ! fm_harness_session_uuid_valid "$sid"; then
    FM_HARNESS_SESSION_REASON="the recorded session id is malformed"
    return 1
  fi
  wt=$(fm_harness_session_get "$meta" worktree)
  cwd=$(fm_harness_session_get "$record" cwd)
  if [ -n "$wt" ] && [ -n "$cwd" ]; then
    wt=$(fm_harness_session_canonical "$wt")
    cwd=$(fm_harness_session_canonical "$cwd")
    case "$cwd/" in
      "$wt/"*) ;;
      *)
        FM_HARNESS_SESSION_REASON="the recorded conversation ran outside the task's worktree"
        return 1
        ;;
    esac
  fi
  transcript=$(fm_harness_session_get "$record" transcript)
  if [ -z "$transcript" ] || [ ! -s "$transcript" ]; then
    FM_HARNESS_SESSION_REASON="its conversation file ${transcript:-(unrecorded)} is gone"
    return 1
  fi
  FM_HARNESS_SESSION_ID=$sid
  return 0
}

fm_harness_session_main() {
  local cmd=${1-} state id gen='' harness=''
  case "$cmd" in
    -h|--help)
      sed -n '2,${/^#/!q;p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      return 0
      ;;
    record)
      shift
      state=${1-}
      id=${2-}
      [ "$#" -ge 2 ] && shift 2
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --gen) gen=${2-}; shift 2 2>/dev/null || shift ;;
          --harness) harness=${2-}; shift 2 2>/dev/null || shift ;;
          *) shift ;;
        esac
      done
      fm_harness_session_record "$state" "$id" "$gen" "$harness" >/dev/null 2>&1 || true
      return 0
      ;;
    resumable)
      [ "$#" -eq 3 ] || { echo "usage: fm-harness-session.sh resumable <state-dir> <task-id>" >&2; return 2; }
      if fm_harness_session_resumable "$2" "$3"; then
        printf '%s\n' "$FM_HARNESS_SESSION_ID"
        return 0
      fi
      printf 'not resumable: %s\n' "$FM_HARNESS_SESSION_REASON"
      return 1
      ;;
    *)
      echo "usage: fm-harness-session.sh record|resumable ... (see --help)" >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fm_harness_session_main "$@"
  exit $?
fi
