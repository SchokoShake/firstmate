#!/usr/bin/env bash
# fm-agent-view-lib.sh - the single owner of the opt-in agent-view pilot.
#
# Sourced, never executed, and only through bin/fm-backend.sh's
# fm_agent_view_source, which loads the tmux adapter and the bounded-command
# runner this file calls.
#
# What the pilot is. With the home-local switch config/agent-view-workers set to
# `on` (docs/configuration.md owns the switch), a NEW crewmate or scout launched
# on the claude harness and the tmux backend runs as a Claude Code background
# session (`claude --bg`) rather than as an interactive session in its tmux
# window, so Claude Code's agent view (`claude agents`) lists it as a row. The
# worker's window runs `claude attach <id>`, a live viewer of that session, so
# firstmate's typing, peeking, and busy-state paths keep working through it.
# docs/tmux-backend.md "Agent-view pilot" is the operator guide; this header
# owns the mechanics.
#
# A record is a pilot record when its meta carries agent_view_id=: `pending`
# while the launch is in flight, then the session's 8-hex id. Every lifecycle
# path keys off that recorded value and never off the switch, so turning the
# switch off never touches a running pilot, and a pilot keeps its shape through
# relaunch until cleanup. Secondmates are never piloted: their supervision
# rides Claude Stop-hook rewakes and their FM_HOME would have to move into
# settings, neither of which was verified for a background session.
#
# The five behaviour changes it owns, each verified on Claude Code 2.1.314
# (docs/verification/runtime-backends.md "Agent-view pilot"):
#   1. Launch environment. A background session is hosted by Claude Code's
#      background service and inherits that service's environment - whichever
#      client happened to start it - never the dispatching shell's. Everything
#      firstmate passes a worker therefore rides `--settings` env
#      (fm_agent_view_settings_json): GOTMPDIR, the prompt-suggestion switch,
#      TRACEPARENT (the empty string when trace context is off, because a
#      setting can override a variable but cannot unset one), and
#      FM_AGENT_VIEW_TASK, the marker every pilot hook is gated on
#      (fm_agent_view_hook_gate). The agent view itself fires the worktree's
#      SessionStart and SessionEnd hooks from processes that are not the worker,
#      without that marker, so an ungated hook would mark the task idle and
#      retire its presence row behind firstmate's back. The settings survive a
#      stop and a resume. Every client the pilot types into a worker's window
#      (fm_agent_view_client_line) drops the window's tmux identity and Cursor
#      markers, because that client may be the one that starts the service.
#      The service itself runs in the home directory and its idle pty hosts
#      under /tmp/cc-daemon-<uid>/; only the pty host running a session takes
#      that session's working directory. In a worker's worktree, teardown's
#      working-directory reaper (bin/fm-teardown.sh) can therefore reach only
#      the worker's own session and the pty host running it, which teardown
#      stops and removes before its reap, and never the service or the
#      processes that host other sessions.
#   2. Exit is `claude stop <id>` (fm_agent_view_stop). `/exit` in a viewer
#      leaves the worker running and turns the window into the agent view.
#   3. Liveness reads `claude agents --json --all` by id
#      (fm_agent_view_session_state), never the window's foreground process: a
#      shell in the window no longer proves the worker is gone, and a viewer in
#      the window no longer proves it is alive.
#   4. Typing is refused unless the viewer shows this worker's own session
#      (fm_agent_view_viewer_state), so a steer can never land in the agent
#      view's dispatch box, where Enter starts a new session in the worker's
#      local copy.
#   5. Cleanup removes the session (fm_agent_view_rm) after landing, so the
#      agent view lists only live work, and relaunch resumes the real
#      conversation with `claude attach <id>` (a stopped session resumes with a
#      new process, its name, and its settings).
#
# The viewer cannot be locked out of the agent view the way an ordinary worker
# is: CLAUDE_CODE_DISABLE_AGENT_VIEW=1 also disables `--bg` and `attach`, and the
# per-session disableAgentView setting does not reach a viewer. Inside a viewer,
# the left arrow on an empty prompt, `/exit`, and a double Ctrl+C re-execute the
# viewer in place as the agent view (its argv becomes `claude agents`), Escape
# then leaves it for the shell (a first Escape clears a typed draft), and Ctrl+Z
# suspends it at the shell. None of these stop the worker. What closes them is
# that no firstmate path acts on a window it has not re-proven: the typing guard
# refuses, liveness never reads the window, the gated hooks ignore the agent
# view's own events, and relaunch ends any viewer client before re-attaching.
#
# Every `claude` call runs under a hard bound (fm_run_timed) with this process's
# own CLAUDE_CONFIG_DIR, the store fm-spawn forwards onto the launch, so every
# call addresses the same background service the worker runs in.
#
# Functions:
#   fm_agent_view_switch <config-dir>             -> on|off|invalid
#   fm_agent_view_id_valid <id>                   -> 0 for an 8-hex session id
#   fm_agent_view_settings_json <task> <gotmp> <traceparent>
#                                                 -> the --settings JSON
#   fm_agent_view_hook_gate <task>                -> shell prefix gating a hook
#   fm_agent_view_parse_launch <out-file> <task>  -> the session id the launch printed
#   fm_agent_view_session_state <id> <worktree> [own]
#                                                 -> alive|dead|missing|ambiguous|unreadable
#   fm_agent_view_named_ids <name> <worktree>     -> ids of background sessions so named there
#   fm_agent_view_viewer_state <target> <task> <id>
#                                                 -> session|detached|missing|unreadable
#   fm_agent_view_release_window <target>         -> 0 once the window is at its shell
#   fm_agent_view_client_line <claude-args>       -> the shell line for one window client
#   fm_agent_view_attach_window <target> <task> <id> <wait>
#                                                 -> 0 once a viewer shows the session
#   fm_agent_view_input_guard <task> <id> <target> key|text <input>
#                                                 -> 0 when the input may be typed
#   fm_agent_view_stop <id> / fm_agent_view_rm <id>
#   fm_agent_view_meta_state <meta>               -> the session state for a pilot record
#
# Environment knobs:
#   FM_AGENT_VIEW_CLAUDE_TIMEOUT  bound in seconds for one `claude` call (20)

FM_AGENT_VIEW_CLAUDE_TIMEOUT=${FM_AGENT_VIEW_CLAUDE_TIMEOUT:-20}

# The agent view's own footer and dispatch-box wording. Any one of these in the
# bottom of the window means the viewer is not showing a session, whatever else
# the screen says.
FM_AGENT_VIEW_SCREEN_MARKERS='enter to return|space to reply|enter to create|enter to open|space to close|ctrl+x to delete|describe a task for a new session'

# fm_agent_view_switch: the home-local switch. Absent or `off` is off, `on` is
# on, and anything else - an empty file included - is invalid, which an
# eligible spawn refuses rather than guessing what was meant.
fm_agent_view_switch() {  # <config-dir> -> on|off|invalid
  local file="$1/agent-view-workers" value
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf 'off'
    return 0
  fi
  value=$(tr -d '[:space:]' < "$file" 2>/dev/null) || { printf 'invalid'; return 0; }
  case "$value" in
    on) printf 'on' ;;
    off) printf 'off' ;;
    *) printf 'invalid' ;;
  esac
}

fm_agent_view_id_valid() {  # <id>
  local LC_ALL=C
  case "${1-}" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;;
  esac
  return 1
}

fm_agent_view_claude() {  # <claude-args...>
  fm_run_timed "$FM_AGENT_VIEW_CLAUDE_TIMEOUT" claude "$@" </dev/null
}

# fm_agent_view_settings_json: the per-session environment, as compact JSON
# for `claude --bg --settings`. See behaviour change 1 above.
fm_agent_view_settings_json() {  # <task-id> <gotmp-dir> <traceparent-or-empty>
  jq -cn --arg task "$1" --arg gotmp "$2" --arg tp "$3" \
    '{env: {CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION: "false", GOTMPDIR: $gotmp, TRACEPARENT: $tp, FM_AGENT_VIEW_TASK: $task}}'
}

# fm_agent_view_hook_gate: the prefix every pilot hook command carries, so only
# the worker's own session - the one process launched with the marker - can
# write the task's busy state, turn-end notification, or presence beat. Hook
# commands run under /bin/sh; the task id is path-safe, so it needs no quoting
# beyond the single quotes.
fm_agent_view_hook_gate() {  # <task-id>
  # shellcheck disable=SC2016  # the expansion is the hook shell's, not ours
  printf '[ "${FM_AGENT_VIEW_TASK:-}" = %s ] || exit 0; ' "'$1'"
}

# fm_agent_view_parse_launch: the session id from `claude --bg`'s
# `backgrounded · <id> · <name>` line, accepted only when the name is this
# task's own window label, so a launch that named anything else is refused.
fm_agent_view_parse_launch() {  # <launch-output-file> <task-id>
  local file=$1 task=$2 id
  id=$(LC_ALL=C awk -v name="fm-$task" '
    $1 == "backgrounded" && NF == 5 && $5 == name { print $3; found = 1; exit }
    END { exit !found }
  ' "$file" 2>/dev/null) || return 1
  fm_agent_view_id_valid "$id" || return 1
  printf '%s' "$id"
}

# fm_agent_view_session_state: recovery-grade state of one pilot worker, read
# from the background service's own session list by exact id, in the shared
# vocabulary of fm_backend_agent_state (bin/fm-backend.sh):
#   alive      - the session is running (its row carries a pid).
#   dead       - the session is stopped and resumable, and no other running
#                session works in the same local copy.
#   missing    - the session no longer exists (removed), and no other running
#                session works in the same local copy.
#   ambiguous  - the row is not a background session in this worktree, or
#                another running session works in it, so no "no agent owns
#                this task" proof is possible.
#   unreadable - the list could not be read or contradicted itself.
# With the third argument `own`, other sessions in the local copy are ignored:
# the verdict is then about this session alone, for a record whose copy may
# already belong to another task.
fm_agent_view_session_state() {  # <id> <worktree> [own]
  local id=$1 wt=$2 scope=${3:-} wt_real json verdict
  fm_agent_view_id_valid "$id" || { printf 'unreadable'; return 0; }
  [ -n "$wt" ] || { printf 'unreadable'; return 0; }
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || wt_real=$wt
  json=$(fm_agent_view_claude agents --json --all 2>/dev/null) || { printf 'unreadable'; return 0; }
  verdict=$(printf '%s' "$json" | jq -r --arg id "$id" --arg wt "$wt" --arg wtreal "$wt_real" --arg scope "$scope" '
    def here: ((.cwd // "") == $wt or (.cwd // "") == $wtreal);
    def running: ((.pid | type) == "number");
    if type != "array" then "unreadable"
    else
      [ .[] | objects | select(.id == $id) ] as $mine
      | (if $scope == "own" then 0
         else [ .[] | objects | select(.id != $id and running and here) ] | length
         end) as $others
      | if ($mine | length) > 1 then "unreadable"
        elif ($mine | length) == 0 then (if $others > 0 then "ambiguous" else "missing" end)
        elif ($mine[0].kind != "background") or (($mine[0] | here) | not) then "ambiguous"
        elif ($mine[0] | running) then "alive"
        elif $others > 0 then "ambiguous"
        else "dead"
        end
    end' 2>/dev/null) || verdict=unreadable
  case "$verdict" in
    alive|dead|missing|ambiguous|unreadable) printf '%s' "$verdict" ;;
    *) printf 'unreadable' ;;
  esac
}

# fm_agent_view_named_ids: the ids of every background session named <name>
# whose local copy is <worktree>, one per line, so a launch whose output carried
# no usable id can still be tied to the one session it created. Non-zero when
# the list cannot be read.
fm_agent_view_named_ids() {  # <name> <worktree>
  local name=$1 wt=$2 wt_real json
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || wt_real=$wt
  json=$(fm_agent_view_claude agents --json --all 2>/dev/null) || return 1
  printf '%s' "$json" | jq -r --arg name "$name" --arg wt "$wt" --arg wtreal "$wt_real" '
    if type != "array" then error("not a session list") else . end
    | .[] | objects
    | select(.kind == "background" and .name == $name
             and ((.cwd // "") == $wt or (.cwd // "") == $wtreal))
    | .id | strings | select(test("^[0-9a-f]{8}$"))' 2>/dev/null
}

# fm_agent_view_meta_state: fm_agent_view_session_state for a pilot record. A
# launch still in flight, a secondmate record that claims the pilot, and a
# malformed id are all unreadable, so nothing acts on them.
fm_agent_view_meta_state() {  # <meta-file>
  local meta=$1 id
  id=$(fm_meta_get "$meta" agent_view_id)
  if [ "$(fm_meta_get "$meta" kind)" = secondmate ] || ! fm_agent_view_id_valid "$id"; then
    printf 'unreadable'
    return 0
  fi
  fm_agent_view_session_state "$id" "$(fm_meta_get "$meta" worktree)"
}

# fm_agent_view_foreground: the window's foreground job leader - the process
# whose pid is its tty's foreground process group - as "<pgid> <args>"; nothing
# when the tty cannot be read or the leader has already gone. Only the leader
# is classified, because a client's own children share its group.
fm_agent_view_foreground() {  # <target>
  local target=$1 tty pid pgid tpgid args
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid= 2>/dev/null \
    | while read -r pid pgid tpgid; do
        [ -n "$pid" ] && [ "$pid" = "$pgid" ] && [ "$pgid" = "$tpgid" ] || continue
        args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
        printf '%s %s\n' "$pgid" "$args"
      done
}

# fm_agent_view_client_kind: classify one process's argv. `viewer:<id>` is
# exactly `claude attach <id>` and `agents` exactly `claude agents`, where the
# program is argv[0] named claude; `other` is anything else.
fm_agent_view_client_kind() {  # <args>
  local words=()
  read -r -a words <<< "$1"
  if [ "${words[0]:-}" = "" ] || [ "${words[0]##*/}" != claude ]; then
    printf 'other'
  elif [ "${#words[@]}" -eq 3 ] && [ "${words[1]}" = attach ] && fm_agent_view_id_valid "${words[2]}"; then
    printf 'viewer:%s' "${words[2]}"
  elif [ "${#words[@]}" -eq 2 ] && [ "${words[1]}" = agents ]; then
    printf 'agents'
  else
    printf 'other'
  fi
}

# fm_agent_view_screen_shows_session: the rendered half of the viewer proof.
# The session's own composer border carries its name, `fm-<task>`, at its right
# end; the agent view's never does, and its footer names agent-view actions.
fm_agent_view_screen_shows_session() {  # <task-id>, screen on stdin
  LC_ALL=C awk -v want=" fm-$1 ─" -v bar="─" -v markers="$FM_AGENT_VIEW_SCREEN_MARKERS" '
    BEGIN { n = split(markers, m, "|") }
    {
      line = $0
      sub(/[ \t]+$/, "", line)
      lines[++count] = line
      if (!label) {
        len = length(line); w = length(want)
        if (len > w && substr(line, len - w + 1) == want) {
          head = substr(line, 1, len - w)
          gsub(bar, "", head)
          if (head == "") label = 1
        }
      }
    }
    END {
      if (!label) exit 1
      seen = 0
      for (i = count; i >= 1 && seen < 8; i--) {
        if (lines[i] == "") continue
        seen++
        low = tolower(lines[i])
        for (j = 1; j <= n; j++) if (index(low, m[j])) exit 1
      }
      exit 0
    }'
}

# fm_agent_view_viewer_state: may firstmate type into this pilot's window?
# `session` only when all three independent signals agree: the window's
# foreground process is `claude attach <id>` for this exact session (a kernel
# read), the screen shows the session's own name in its composer border, and
# no agent-view footer is on screen. The guard is a conjunction on purpose: its
# failure direction is a refusal, so a Claude Code release that renders any of
# these differently can only make it refuse - loudly, through the caller and the
# live guard - never let a steer through to the dispatch box.
#   session    - the viewer shows this worker's own session.
#   detached   - the window shows a shell, the agent view, or another session.
#   missing    - the window is gone.
#   unreadable - the window could not be read.
fm_agent_view_viewer_state() {  # <target> <task-id> <id>
  local target=$1 task=$2 id=$3 leader
  case "$(fm_backend_tmux_agent_state "$target")" in
    alive) ;;
    dead|ambiguous) printf 'detached'; return 0 ;;
    missing) printf 'missing'; return 0 ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  leader=$(fm_agent_view_foreground "$target")
  if [ -z "$leader" ] || [ "$(fm_agent_view_client_kind "${leader#* }")" != "viewer:$id" ]; then
    printf 'detached'
    return 0
  fi
  if ! tmux capture-pane -p -t "$target" 2>/dev/null | fm_agent_view_screen_shows_session "$task"; then
    printf 'detached'
    return 0
  fi
  printf 'session'
}

# fm_agent_view_release_window: end every Claude Code viewer client in the
# window's foreground - `claude attach <any id>` or the agent view - so the
# window is back at its shell for a fresh `claude attach`. A viewer is only a
# client, so ending it never stops a session. Anything else in the foreground
# (an interactive session, any other program) refuses, and nothing is signalled.
fm_agent_view_release_window() {  # <target>
  local target=$1 leader group i
  for i in $(seq 1 40); do
    : "$i"
    case "$(fm_backend_tmux_agent_state "$target")" in
      dead) return 0 ;;
      alive)
        # No leader means the foreground changed between reads (a viewer
        # exiting on its own); the next pass reads it again.
        leader=$(fm_agent_view_foreground "$target")
        if [ -n "$leader" ]; then
          case "$(fm_agent_view_client_kind "${leader#* }")" in
            viewer:*|agents) ;;
            *) return 1 ;;
          esac
          group=${leader%% *}
          case "$group" in
            ''|*[!0-9]*|0|1) return 1 ;;
          esac
          kill -TERM -- "-$group" 2>/dev/null || true
        fi
        ;;
      missing|unreadable) return 1 ;;
    esac
    sleep 0.25
  done
  return 1
}

fm_agent_view_shell_quote() {  # <text>
  local quote="'" escaped="'\\''"
  printf "'%s'" "${1//$quote/$escaped}"
}

# fm_agent_view_client_line: the shell line that runs one Claude Code client in
# a worker's window, with this process's own CLAUDE_CONFIG_DIR. The client may
# be the one that starts Claude Code's shared background service, which hands
# its environment to every session it hosts, other workers' and the captain's
# alike, so the line drops the window's tmux identity and Cursor markers.
fm_agent_view_client_line() {  # <claude-arguments, already shell-quoted>
  local prefix=
  [ -z "${CLAUDE_CONFIG_DIR:-}" ] || prefix="CLAUDE_CONFIG_DIR=$(fm_agent_view_shell_quote "$CLAUDE_CONFIG_DIR") "
  printf '%senv -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u TMUX -u TMUX_PANE claude %s' "$prefix" "$1"
}

# fm_agent_view_attach_window: start a viewer of session <id> in the window's
# own shell, which must be at its prompt, then wait up to <wait> seconds for it
# to show the session. Returns 0 once it does, 1 when the window is not at its
# shell (nothing is typed), and 2 when the viewer was started but could not be
# confirmed in time. The shell's line is cleared first, so nothing a person
# left half-typed there runs along with it.
fm_agent_view_attach_window() {  # <target> <task> <id> <wait-seconds>
  local target=$1 task=$2 id=$3 wait=$4 line elapsed=0
  fm_agent_view_id_valid "$id" || return 1
  [ "$(fm_backend_tmux_agent_state "$target")" = dead ] || return 1
  line=$(fm_agent_view_client_line "attach $id")
  fm_backend_tmux_send_key "$target" C-u || return 1
  fm_backend_tmux_send_literal "$target" "$line" || return 1
  sleep 0.3
  fm_backend_tmux_send_key "$target" Enter || return 1
  until [ "$(fm_agent_view_viewer_state "$target" "$task" "$id")" = session ]; do
    awk -v e="$elapsed" -v t="$wait" 'BEGIN{exit !(e < t)}' || return 2
    sleep 0.5
    elapsed=$(awk -v e="$elapsed" 'BEGIN{printf "%.1f", e + 0.5}')
  done
}

# fm_agent_view_input_guard: the gate every path that types into a pilot
# worker's window runs first. It refuses, naming why and the recovery, unless
# the viewer is showing the worker's own session, and it refuses the inputs
# that would themselves take the viewer off that session: any key but Escape,
# Enter, Up, Down, Tab, and a single digit (the left arrow opens the agent
# view, a double Ctrl+C detaches to it, Ctrl+Z suspends the viewer), and the
# /exit, /quit, /bg, and /background commands, which leave the worker running
# unwatched.
fm_agent_view_input_guard() {  # <task> <id> <target> key|text <input>
  local task=$1 id=$2 target=$3 kind=$4 input=$5 state first
  if ! fm_agent_view_id_valid "$id"; then
    echo "error: task $task records agent-view session '$id' rather than a session id, so its launch may still be in flight; nothing was sent" >&2
    return 1
  fi
  case "$kind" in
    key)
      case "$input" in
        Escape|escape|Esc|esc|Enter|Up|Down|Tab|[1-9]) ;;
        *)
          echo "error: key '$input' is refused for agent-view pilot worker $task: only Escape, Enter, Up, Down, Tab, and a single digit reach its viewer, because other keys can take it off the worker's session (the left arrow opens the agent view, a double Ctrl+C detaches to it, Ctrl+Z suspends it); interrupt with bin/fm-control.sh $task interrupt; nothing was sent" >&2
          return 1
          ;;
      esac
      ;;
    text)
      first=${input%%[[:space:]]*}
      case "$first" in
        /exit|/quit|/bg|/background)
          echo "error: '$first' would detach agent-view pilot worker $task's viewer and leave the worker running unwatched; stop it with bin/fm-control.sh $task exit; nothing was sent" >&2
          return 1
          ;;
      esac
      ;;
    *)
      echo "error: unknown input kind '$kind'" >&2
      return 1
      ;;
  esac
  state=$(fm_agent_view_viewer_state "$target" "$task" "$id")
  [ "$state" = session ] && return 0
  echo "error: window $target is not showing agent-view pilot worker $task's own session (viewer state: $state), so input could land in the agent view, where Enter starts a new session in the worker's local copy; nothing was sent. Re-attach the viewer with bin/fm-control.sh $task relaunch" >&2
  return 1
}

fm_agent_view_stop() {  # <id>
  fm_agent_view_id_valid "${1-}" || return 1
  fm_agent_view_claude stop "$1" >/dev/null 2>&1
}

fm_agent_view_rm() {  # <id>
  fm_agent_view_id_valid "${1-}" || return 1
  fm_agent_view_claude rm "$1" >/dev/null 2>&1
}
