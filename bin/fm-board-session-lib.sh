#!/usr/bin/env bash
# fm-board-session-lib.sh - publish state/board-session.json, this home's
# session-identity record for a board that wakes firstmate by session id.
#
# bin/fm-session-start.sh is the only caller, and its header owns the record's
# fields and when it is written. This file owns how that identity is resolved,
# by two routes the record names in its own source field:
#
#   environment  CLAUDE_CODE_SESSION_ID, which inside a tool call is the
#                registry's own sessionId, with CLAUDE_PID as the session
#                process. Preferred: the session states its identity directly,
#                so there is no lookup to miss and no corpse record to mistake
#                for it. Measured against Claude Code 2.1.263.
#   registry     the session lock's harness pid, looked up in the Claude session
#                registry under the liveness rule that registry's readers apply.
#                The fallback, for a start that runs without those variables.
#
# The registry lookup is by pid, where bin/fm-inbox-post.sh's own reader looks up
# by socket. The two want different things from the same registry - a socket to
# write a frame to, against the selector a board configures itself with - so they
# stay separate readers rather than one with a mode flag.
#
# Sourced, not executed; no side effects on source.

# Registry directory. CLAUDE_CONFIG_DIR is the harness's own override, so a
# session that registered somewhere else is still found.
fm_board_session_registry_dir() {
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
}

# One field out of a registry entry. The entry is one line of machine-generated
# JSON, so a narrow match keeps this off a JSON dependency; an unmatched or
# unexpected shape yields empty, and every caller treats empty as refuse or null.
fm_board_session_field() {  # <entry> <name>
  sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | sed -n 1p
}

# True when a value can be re-emitted as a JSON string with no escaping. A
# registry value holding a quote, a backslash, or a control character is one the
# narrow reader above truncated, so the entry is refused rather than published as
# malformed JSON.
fm_board_session_plain() {  # <value>
  case "$1" in
    *[\"\\]* | *[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

# An absent field is emitted as null, never as an empty string. For nameSource
# the two genuinely differ: the harness omits it for a name set through
# CLAUDE_CODE_SESSION_NAME, which is a name a person chose and not the unnamed
# case, so collapsing absent to "" would assert something the registry did not.
fm_board_session_json_field() {  # <key> <value>
  if [ -z "$2" ]; then
    printf ',"%s":null' "$1"
  else
    printf ',"%s":"%s"' "$1" "$2"
  fi
}

# The registry entry at <entry> for <pid> is live, by the three tests the
# registry's own readers apply: the pid exists, its start time still matches the
# recorded one, and the record was written in this pid namespace. The last two
# read /proc and /etc/machine-id and are skipped where those are unreadable,
# degrading to pid existence alone off Linux or in a container without a machine
# id - weaker rather than broken, and the same degradation bridge-axi documents
# for its own wake.
#
# The start-time test is the one that matters here. Without it, a corpse entry
# left behind by a dead session whose pid this session was later assigned would
# be published as this session's identity, and every wake aimed at it would
# silently reach nothing - the exact failure this record exists to end.
fm_board_session_entry_live() {  # <entry> <pid>
  local entry=$1 pid=$2 want_start want_domain stat rest have_start have_domain machine_id
  kill -0 "$pid" 2>/dev/null || return 1

  want_start=$(fm_board_session_field "$entry" procStart)
  if [ -n "$want_start" ] && stat=$(cat "/proc/$pid/stat" 2>/dev/null); then
    # Field 2 (comm) may hold spaces and parentheses, so count from after its
    # closing paren: field 22 is the 20th field of what remains.
    rest=${stat##*') '}
    have_start=$(printf '%s\n' "$rest" | awk '{print $20}')
    [ "$have_start" = "$want_start" ] || return 1
  fi

  want_domain=$(fm_board_session_field "$entry" pidDomain)
  if [ -n "$want_domain" ] \
    && machine_id=$(cat /etc/machine-id 2>/dev/null) && [ -n "$machine_id" ] \
    && have_domain=$(readlink /proc/self/ns/pid 2>/dev/null) && [ -n "$have_domain" ]; then
    [ "$want_domain" = "linux:$machine_id:$have_domain" ] || return 1
  fi
  return 0
}

# A session id is interpolated into this record and then into a wake selector,
# so it is validated rather than escaped, whichever route produced it.
fm_board_session_id_valid() {  # <value>
  case "$1" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Write the record for this session into <state>, atomically and mode 0600.
# <lock-pid> is the harness pid the session lock holds, used as the registry key
# when the environment does not name the session process itself.
#
# On a decline it prints one reason to stdout and returns 1, leaving any prior
# record untouched, so the caller can name what it could not confirm rather than
# publish a guessed identity.
fm_board_session_publish() {  # <state> <lock-pid> [registry-dir]
  local state=$1 lock_pid=$2 dir=${3:-}
  local pid='' entry='' source='' session_id='' cwd='' kind='' name='' name_source=''
  local entry_session prior_umask tmp value
  [ -n "$dir" ] || dir=$(fm_board_session_registry_dir)

  # The session process, preferring the pid the harness names over the one the
  # ancestry walk inferred. A named pid that is not running is not this session,
  # so it is dropped rather than published.
  case "${CLAUDE_PID:-}" in
    '' | *[!0-9]*) ;;
    *) kill -0 "$CLAUDE_PID" 2>/dev/null && pid=$CLAUDE_PID ;;
  esac
  if [ -z "$pid" ]; then
    case "$lock_pid" in
      '' | *[!0-9]*) ;;
      *) pid=$lock_pid ;;
    esac
  fi
  [ -n "$pid" ] || { printf 'the session lock names no harness process\n'; return 1; }

  # The registry entry for that pid, when there is a live one. It carries the
  # informational fields on both routes, and the session id only on the fallback.
  if [ -f "$dir/$pid.json" ] && [ ! -L "$dir/$pid.json" ] \
    && fm_board_session_entry_live "$dir/$pid.json" "$pid"; then
    entry="$dir/$pid.json"
  fi

  if fm_board_session_id_valid "${CLAUDE_CODE_SESSION_ID:-}"; then
    session_id=$CLAUDE_CODE_SESSION_ID
    source=environment
    # Two independent statements of the same identity, so they are checked
    # against each other rather than one being trusted. A live entry under this
    # exact pid is that process's own record - not a corpse, which the liveness
    # rule above already dropped - so naming a different session is drift in one
    # of the two vendor sources. Refuse loudly: an unregistered session is a
    # board that keeps polling, where a wrong session id is a wake sent
    # confidently into nothing.
    if [ -n "$entry" ]; then
      entry_session=$(fm_board_session_field "$entry" sessionId)
      if [ -n "$entry_session" ] && [ "$entry_session" != "$session_id" ]; then
        printf 'this session names one id and its registry entry names another\n'
        return 1
      fi
    fi
  elif [ -n "$entry" ]; then
    source=registry
    session_id=$(fm_board_session_field "$entry" sessionId)
    fm_board_session_id_valid "$session_id" || {
      printf 'the session registry entry names no usable session id\n'
      return 1
    }
  elif [ -f "$dir/$pid.json" ]; then
    printf 'the session registry entry for this session is stale\n'
    return 1
  else
    printf 'no session registry entry for this session in %s\n' "$dir"
    return 1
  fi

  if [ -n "$entry" ]; then
    cwd=$(fm_board_session_field "$entry" cwd)
    kind=$(fm_board_session_field "$entry" kind)
    name=$(fm_board_session_field "$entry" name)
    name_source=$(fm_board_session_field "$entry" nameSource)
    for value in "$cwd" "$kind" "$name" "$name_source"; do
      [ -z "$value" ] || fm_board_session_plain "$value" || {
        printf 'the session registry entry holds a value this reader cannot represent\n'
        return 1
      }
    done
  fi

  [ -d "$state" ] && [ ! -L "$state" ] || { printf 'the state directory is unavailable\n'; return 1; }
  # Restored before returning: this file is SOURCED, so a umask left behind here
  # would follow the caller through every file it writes afterwards.
  prior_umask=$(umask)
  umask 077
  tmp=$(mktemp "$state/.fm-board-session.XXXXXX" 2>/dev/null) || {
    umask "$prior_umask"
    printf 'could not stage the record\n'
    return 1
  }
  {
    printf '{"schema":"fm-board-session.v1"'
    printf ',"session_id":"%s"' "$session_id"
    printf ',"pid":%s' "$pid"
    fm_board_session_json_field cwd "$cwd"
    fm_board_session_json_field kind "$kind"
    printf ',"registered_at":"%s"' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fm_board_session_json_field name "$name"
    fm_board_session_json_field name_source "$name_source"
    fm_board_session_json_field source "$source"
    printf '}\n'
  } > "$tmp" 2>/dev/null && chmod 0600 "$tmp" 2>/dev/null \
    && mv -f -- "$tmp" "$state/board-session.json" 2>/dev/null && {
    umask "$prior_umask"
    return 0
  }

  rm -f -- "$tmp"
  umask "$prior_umask"
  printf 'could not publish the record\n'
  return 1
}
