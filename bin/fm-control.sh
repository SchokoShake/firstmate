#!/usr/bin/env bash
# fm-control.sh - the CONTROL PLANE for a firstmate-owned agent: allowlisted
# lifecycle verbs addressed to an exact task id.
#
# Usage: fm-control.sh <task-id> interrupt
#        fm-control.sh <task-id> exit
#        fm-control.sh <task-id> relaunch [--harness <name>] [--model <name>]
#                                         [--effort <level>]
#                                         (--note <text> | --note-file <path>)
#        fm-control.sh revive <task-id>... [--fresh]
#        fm-control.sh revive --stopped-by-restart [--fresh]
#        fm-control.sh <task-id> revive [--fresh]
#
# Why this exists, and how it differs from fm-send.sh. bin/fm-send.sh is the
# DATA plane: conversational text for the agent to read, always routing-marked
# for a kind=secondmate target so the reply returns through the status path.
# That marking is right for a message and wrong for a lifecycle command - a
# marked "/quit" arrives as ordinary chat the agent reasons ABOUT instead of
# executing. This script is the control plane: semantic process control with a
# closed verb list, per-harness mechanics owned by an executable adapter
# (bin/fm-control-lib.sh) rather than improvised in agent prose, and a verified
# postcondition for every action. There is deliberately NO arbitrary-text and
# NO generic raw-key entry point here; fm-send remains the only way to send an
# agent something to read.
#
#   interrupt  Deliver the harness's verified interrupt sequence. The agent
#              keeps running. Postcondition: delivery succeeded, the endpoint
#              still exists, and the agent is still alive where the backend can
#              classify that. Cancellation is confirmed only from an adapter-
#              owned acknowledgement and otherwise reported unconfirmed. Busy
#              state is never rewritten as proof of the action.
#   exit       Stop the agent, preserving its terminal endpoint, worktree, and
#              every uncommitted change. Interrupts first when the task reads
#              busy, then submits the harness's exit command. Postcondition:
#              the backend's recovery-grade classifier reports the agent gone.
#              Already-stopped is success (idempotent).
#   relaunch   Transactionally replace the running agent with a new one, in the
#              SAME endpoint and SAME worktree, on the same or a newly chosen
#              harness/model/effort - so switching harness is one ordinary use
#              of this verb. With no explicit axis, a secondmate re-resolves its
#              durable config/secondmate-harness pin (harness plus its optional
#              model and effort tokens) exactly as any other respawn does, while
#              a ship or scout keeps the exact adapter already recorded for it.
#              A prefixed raw-command basename cannot reconstruct its launch
#              command, so relaunch requires an explicit --harness for it.
#              --note is required for a ship or scout, whose replacement
#              inherits the local copy but none of the conversation; a
#              secondmate reconciles its own home's records at startup, so its
#              standing charter is never rewritten.
#              Before that checkpoint is recorded, the note is written, or the
#              agent is stopped, a ship or scout on a treehouse-backed backend
#              is refused unless the pool's durable lease proves the record
#              still owns its worktree (bin/fm-slot-lib.sh owns that verdict),
#              and the refusal names the deliberate path instead.
#              Records a durable checkpoint and that note, re-arms a recorded
#              PR's merge poll through its owner bin/fm-pr-check.sh while the
#              old agent still runs, exits the old agent, then delegates the
#              launch to its single owner, bin/fm-spawn.sh --relaunch, which
#              publishes the new generation without unbinding that poll, so the
#              watcher never finds it to quarantine. A poll that cannot be
#              re-armed refuses the relaunch before the agent is touched. A
#              failure before publication keeps the prior durable record in
#              place and reports the concrete state; it never leaves a
#              half-transitioned task claiming to be running. A task whose
#              recorded endpoint is gone has no agent to replace, so relaunch
#              refuses it before anything is written and names revive.
#   revive     Bring back a ship or scout whose agent stopped - its endpoint
#              gone because the machine or its tmux server restarted, or its
#              window still there with no agent in it - into the SAME worktree
#              on the same recorded harness, model, and effort. Every proof
#              relaunch makes comes first and changes nothing: the recorded
#              worktree is a readable worktree root and, on a treehouse-backed
#              backend, the pool's durable lease proves the record still owns
#              it. Only then is a gone endpoint recreated under its recorded
#              name with its shell in that worktree; that is tmux only, and
#              every other backend is refused by name. Revive writes its own
#              restart note: what happened, and for a no-mistakes ship task
#              whose branch no-mistakes reports a next action for (a
#              validation run a shutdown killed leaves recover_custody),
#              exactly what to run before any commit or new run. Then the
#              relaunch transaction above runs with that note. The agent comes
#              back INTO its recorded conversation when
#              bin/fm-harness-session.sh says that conversation may be resumed
#              (claude today: `claude --resume <session-id>` in the worktree,
#              the note submitted as its next message), and otherwise fresh
#              from its instructions with the note appended, as relaunch does;
#              --fresh forces the fresh path. A resume counts as done only once
#              the resumed session's own hook has recorded that same session id
#              under the new generation. Idempotent: an agent already running
#              is reported and left alone, and the same note is never appended
#              twice in a row, so a revive that failed part way is simply run
#              again. Several ids are revived one after another, and
#              --stopped-by-restart revives every task the last recorded
#              machine restart stopped that is still stopped
#              (bin/fm-restart-lib.sh owns that list), leaving secondmates to
#              the startup secondmate check. An agent-view pilot worker gets
#              its window back and then the pilot relaunch plan below, which
#              resumes its background session. Nothing calls revive on its own.
#
# An agent-view pilot worker (bin/fm-agent-view-lib.sh owns the pilot) is a
# Claude Code background session that its window only views, so every verb
# reads and drives that session by its recorded id. `interrupt` first proves
# the viewer shows the worker's own session; `exit` is `claude stop <id>`,
# without an interrupt first, and then ends the window's viewer client; and
# `relaunch` keeps the worker's conversation: a running session whose window
# does not show it only gets a fresh viewer (nothing durable changes), a running
# session that is shown is stopped and resumed, a stopped one is resumed, and
# only a session that no longer exists starts afresh from the instructions,
# which is the one pilot case that takes --note. A pilot relaunches only as
# itself, so --harness, --model, and --effort are refused for it.
#
# Teardown and discard are NOT verbs here and never will be. `exit` stops an
# agent and preserves everything else; removing a worktree, killing an
# endpoint, or discarding work stays with bin/fm-teardown.sh, which owns the
# landed-work test.
#
# `resume` is not a verb: it is not deterministic across the verified adapters
# (bin/fm-control-lib.sh's header owns that reasoning). `revive` resumes a
# recorded conversation only where that is verified, and otherwise relies on
# the brief on disk, not a harness-private session, as the durable instruction.
#
# Targeting is EXACT: only a bare task id with a state/<id>.meta record in
# THIS home is accepted, and the record must pass the shared endpoint-identity
# validation (bin/fm-backend.sh's fm_backend_validate_task_endpoint). A legacy
# fm-<id> label, an explicit session:window endpoint, and a bare window name
# are all refused - a lifecycle command delivered to the wrong endpoint is far
# worse than a loud refusal.
#
# A remotely placed secondmate is refused by name: its agent runs on another
# host, so no postcondition this plane verifies could be read for it here.
#
# Fail-closed boundaries:
#   - An unverified harness, or a harness whose control mechanics are unknown,
#     is refused rather than guessed at.
#   - A backend that cannot deliver the harness's interrupt key is refused
#     (Orca's terminal API has no Escape).
#   - `exit`, `relaunch`, and `revive` require a backend with a recovery-grade
#     agent-state classifier (tmux, herdr), because without one the "the agent
#     stopped" postcondition cannot be proven. zellij, orca, and cmux are
#     refused rather than reported as successful blind. `revive` reopens a
#     gone endpoint on tmux alone, so a gone herdr endpoint is refused by
#     name; a herdr window that is still there with no agent in it revives.
#   - An ambiguous or unreadable endpoint state refuses; only a positively
#     classified state acts.
#
# Environment knobs (all bounded waits, seconds):
#   FM_CONTROL_POLL              poll interval for postcondition waits (0.5)
#   FM_CONTROL_SETTLE_WAIT       adapter acknowledgement wait after interrupt (5)
#   FM_CONTROL_EXIT_WAIT         alive->dead wait after the exit command (30)
#   FM_CONTROL_LAUNCH_WAIT       dead->alive wait after a relaunch (90)
#   FM_CONTROL_EXIT_RETRIES      Enter retries for the exit command (3)
#   FM_CONTROL_NM_TIMEOUT        bound on revive's `no-mistakes axi status` (15)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  # The whole leading comment block, ending at the first non-comment line.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# drive a crewmate's lifecycle (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-control refuses to resolve a task without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || {
  echo "error: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 1
}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
[ -d "$STATE" ] || {
  echo "error: state dir '$STATE' is missing; fm-control cannot resolve tasks for FM_HOME '$FM_HOME'" >&2
  exit 1
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-slot-lib.sh
. "$SCRIPT_DIR/fm-slot-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-restart-lib.sh
. "$SCRIPT_DIR/fm-restart-lib.sh"
# shellcheck source=bin/fm-harness-session.sh
. "$SCRIPT_DIR/fm-harness-session.sh"

POLL=${FM_CONTROL_POLL:-0.5}
SETTLE_WAIT=${FM_CONTROL_SETTLE_WAIT:-5}
EXIT_WAIT=${FM_CONTROL_EXIT_WAIT:-30}
LAUNCH_WAIT=${FM_CONTROL_LAUNCH_WAIT:-90}
EXIT_RETRIES=${FM_CONTROL_EXIT_RETRIES:-3}
NM_TIMEOUT=${FM_CONTROL_NM_TIMEOUT:-15}

die() {  # <message>
  echo "error: $1" >&2
  exit 1
}

CONTROL_LOCK=
CONTROL_LOCK_HELD=0
RELAUNCH_ACTIVE=0
RELAUNCH_PHASE=start

control_cleanup() {
  local status=$?
  if [ "$RELAUNCH_ACTIVE" = 1 ] \
     && declare -F relaunch_rollback >/dev/null 2>&1; then
    relaunch_rollback || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  return "$status"
}

# --- revive over several tasks ----------------------------------------------
#
# `revive <task-id>...` and `revive --stopped-by-restart` run the single-task
# form below once per task, one after another, each under its own lock and
# transaction, and fail when any of them failed. A secondmate is never on the
# restart list: the startup secondmate check owns bringing one back.

if [ "${1:-}" = revive ]; then
  shift
  REVIVE_IDS=()
  REVIVE_FLAGS=()
  REVIVE_RESTART=0
  for a in "$@"; do
    case "$a" in
      --fresh) REVIVE_FLAGS=(--fresh) ;;
      --stopped-by-restart) REVIVE_RESTART=1 ;;
      -*) die "unexpected argument '$a'" ;;
      *) REVIVE_IDS+=("$a") ;;
    esac
  done
  if [ "$REVIVE_RESTART" = 1 ]; then
    [ "${#REVIVE_IDS[@]}" -eq 0 ] \
      || die "--stopped-by-restart names its own tasks; pass task ids or --stopped-by-restart, not both"
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      [ "$(fm_meta_get "$STATE/$a.meta" kind)" != secondmate ] || continue
      REVIVE_IDS+=("$a")
    done < <(fm_restart_stopped_tasks "$STATE")
    if [ "${#REVIVE_IDS[@]}" -eq 0 ]; then
      echo "nothing to revive: no task the last recorded machine restart stopped is still stopped"
      exit 0
    fi
  fi
  [ "${#REVIVE_IDS[@]}" -gt 0 ] || { usage >&2; exit 2; }
  REVIVE_FAILED=0
  for a in "${REVIVE_IDS[@]}"; do
    "$SCRIPT_DIR/fm-control.sh" "$a" revive "${REVIVE_FLAGS[@]+"${REVIVE_FLAGS[@]}"}" \
      || REVIVE_FAILED=$((REVIVE_FAILED + 1))
  done
  [ "$REVIVE_FAILED" -eq 0 ] \
    || die "$REVIVE_FAILED of ${#REVIVE_IDS[@]} revives did not complete; each one above names its task and what is left to do"
  exit 0
fi

# --- argument parsing -------------------------------------------------------

RAW_ID=${1:-}
VERB=${2:-}
[ -n "$RAW_ID" ] && [ -n "$VERB" ] || { usage >&2; exit 2; }
shift 2

if ! fm_control_verb_allowed "$VERB"; then
  {
    if [ "$VERB" = resume ]; then
      echo "error: 'resume' is not a control verb: resuming an exited agent is not deterministic across the verified adapters. Use 'revive', which brings a stopped agent back into its recorded conversation where the adapter's resume is verified and otherwise fresh from its brief plus a restart note, or 'relaunch' to replace a running agent with a progress note."
    else
      echo "error: '$VERB' is not a control verb"
    fi
    echo "allowed verbs:"
    fm_control_verbs | sed 's/^/  /'
  } >&2
  exit 2
fi

NEW_HARNESS=
NEW_MODEL=
NEW_EFFORT=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
NOTE=
NOTE_SET=0
FRESH=0
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) die "--$want_value requires a value" ;;
    esac
    case "$want_value" in
      harness) NEW_HARNESS=$a; HARNESS_SET=1 ;;
      model) NEW_MODEL=$a; MODEL_SET=1 ;;
      effort) NEW_EFFORT=$a; EFFORT_SET=1 ;;
      note) NOTE=$a; NOTE_SET=1 ;;
      note-file)
        [ -f "$a" ] || die "--note-file '$a' is not a readable file"
        NOTE=$(cat "$a")
        NOTE_SET=1
        ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --harness) want_value=harness ;;
    --harness=*) NEW_HARNESS=${a#--harness=}; HARNESS_SET=1 ;;
    --model) want_value=model ;;
    --model=*) NEW_MODEL=${a#--model=}; MODEL_SET=1 ;;
    --effort) want_value=effort ;;
    --effort=*) NEW_EFFORT=${a#--effort=}; EFFORT_SET=1 ;;
    --note) want_value=note ;;
    --note=*) NOTE=${a#--note=}; NOTE_SET=1 ;;
    --note-file) want_value=note-file ;;
    --note-file=*)
      [ -f "${a#--note-file=}" ] || die "--note-file '${a#--note-file=}' is not a readable file"
      NOTE=$(cat "${a#--note-file=}")
      NOTE_SET=1
      ;;
    --fresh) FRESH=1 ;;
    *) die "unexpected argument '$a'" ;;
  esac
done
[ -z "$want_value" ] || die "--$want_value requires a value"

if [ "$VERB" != relaunch ]; then
  [ "$HARNESS_SET" = 0 ] && [ "$MODEL_SET" = 0 ] && [ "$EFFORT_SET" = 0 ] && [ "$NOTE_SET" = 0 ] \
    || die "--harness, --model, --effort, and --note apply to 'relaunch' only"
fi
[ "$FRESH" = 0 ] || [ "$VERB" = revive ] || die "--fresh applies to 'revive' only"
[ "$HARNESS_SET" = 0 ] || [ -n "$NEW_HARNESS" ] || die "--harness requires a non-empty value"
[ "$MODEL_SET" = 0 ] || [ -n "$NEW_MODEL" ] || die "--model requires a non-empty value"
[ "$EFFORT_SET" = 0 ] || [ -n "$NEW_EFFORT" ] || die "--effort requires a non-empty value"
case "$NEW_EFFORT" in
  ''|low|medium|high|xhigh|max) ;;
  *) die "--effort must be one of low, medium, high, xhigh, max" ;;
esac

# --- exact task-id resolution ----------------------------------------------

case "$RAW_ID" in
  *:*) die "'$RAW_ID' is an explicit backend endpoint; fm-control accepts an exact task id only, so a lifecycle command can never land on an endpoint this home does not own" ;;
esac
if ! fm_task_id_creation_valid "$RAW_ID"; then
  die "'$RAW_ID' is not a valid task id"
fi
ID=$RAW_ID
CONTROL_LOCK="$STATE/.control-$ID.lock"
trap control_cleanup EXIT
fm_lock_try_acquire "$CONTROL_LOCK" \
  || die "another lifecycle action is already running for task $ID"
CONTROL_LOCK_HELD=1
META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  case "$RAW_ID" in
    fm-*)
      if [ -f "$STATE/${RAW_ID#fm-}.meta" ]; then
        die "'$RAW_ID' is a window label, not a task id; pass the exact task id '${RAW_ID#fm-}'"
      fi
      ;;
  esac
  die "no task '$ID' in $STATE (fm-control resolves an exact task id only)"
fi

# A remotely placed secondmate records its endpoint on ANOTHER host, so every
# postcondition this plane verifies - the agent-state classification, the busy
# verdict, the endpoint's existence - would be read here for an endpoint that
# does not live here. Endpoint validation already refuses such a record, since
# `window=remote:<id>` can never match a local backend's required shape, so
# nothing can be delivered to a wrong endpoint either way. What that refusal
# cannot say is WHY, and "malformed metadata" is the wrong thing to tell an
# operator about a correctly configured remote route. Name the placement
# instead, using the same `remote_host` signal bin/fm-send.sh routes on.
if [ -n "$(fm_meta_get "$META" remote_host)" ]; then
  die "task $ID is a remotely placed secondmate on $(fm_meta_get "$META" remote_host); its agent runs outside this home, so no lifecycle action here could verify that it interrupted, stopped, or came back. Drive its lifecycle on that host, and reconcile it through the secondmate recovery path rather than this plane"
fi

fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
T=$FM_BACKEND_VALIDATED_TARGET
LABEL="fm-$ID"
RECORDED_HARNESS=$(fm_meta_get "$META" harness)
KIND=$(fm_meta_get "$META" kind)
WT=$(fm_meta_get "$META" worktree)
[ -n "$KIND" ] || KIND=ship

HARNESS=$(fm_control_harness_family "$RECORDED_HARNESS") \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; fm-control refuses to guess an interrupt key or exit command"
fm_control_harness_supported "$HARNESS" \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; fm-control refuses to guess an interrupt key or exit command"

fm_backend_validate "$BACKEND" || exit 1

# A pilot record names its background session; a malformed or in-flight one
# is refused here, before any verb can act on it.
AGENT_VIEW_ID=$(fm_meta_get "$META" agent_view_id)
if [ -n "$AGENT_VIEW_ID" ]; then
  fm_agent_view_source || die "task $ID is an agent-view pilot worker, but the pilot library could not be loaded"
  [ "$KIND" != secondmate ] \
    || die "secondmate $ID's record names agent-view session '$AGENT_VIEW_ID', but secondmates are never piloted; reconcile its record before any lifecycle action"
  [ "$HARNESS" = claude ] && [ "$BACKEND" = tmux ] \
    || die "task $ID's record names agent-view session '$AGENT_VIEW_ID' on harness $HARNESS and backend $BACKEND, but the pilot runs only claude on tmux; reconcile its record before any lifecycle action"
  fm_agent_view_id_valid "$AGENT_VIEW_ID" \
    || die "task $ID records agent-view session '$AGENT_VIEW_ID' rather than a session id, so its launch may still be in flight; find its session with 'claude agents --json --all' (name fm-$ID) and reconcile the record before any lifecycle action"
fi

# --- shared helpers ---------------------------------------------------------

agent_state() {
  fm_task_agent_state "$META" "$BACKEND" "$T"
}

# The endpoint's own state, which for an agent-view pilot is its window rather
# than its background session.
window_state() {
  fm_backend_agent_state "$BACKEND" "$T"
}

busy_verdict() {
  fm_busy_classify_meta "$META" "$ID" "$STATE"
}

# wait_agent_state <timeout> <wanted...>: poll until agent_state prints one of
# the wanted values. Prints the final observed state; returns 0 on a match.
wait_agent_state() {  # <timeout> <wanted>...
  wait_for_state agent_state "$@"
}

wait_for_state() {  # <reader> <timeout> <wanted>...
  local reader=$1 timeout=$2 state want elapsed=0
  shift 2
  while :; do
    state=$("$reader")
    for want in "$@"; do
      if [ "$state" = "$want" ]; then
        printf '%s' "$state"
        return 0
      fi
    done
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf '%s' "$state"
  return 1
}

require_state_verified_backend() {  # <verb>
  fm_control_backend_state_verified "$BACKEND" && return 0
  die "task $ID runs on the $BACKEND backend, which has no recovery-grade agent-state classifier, so '$1' cannot prove the agent actually stopped; refusing rather than reporting an unproven transition as done"
}

# send_interrupt_keys: deliver the harness's interrupt key the verified number
# of times, then the composer-clear key when the adapter needs one. Refuses
# before sending anything when the backend cannot deliver either key, because
# an interrupt that cancels the turn but leaves the restored prompt in the
# composer would make the next submitted line concatenate onto it.
send_interrupt_keys() {
  local key repeat clear i=0
  key=$(fm_control_interrupt_key "$HARNESS")
  repeat=$(fm_control_interrupt_repeat "$HARNESS")
  clear=$(fm_control_interrupt_clear_key "$HARNESS")
  fm_control_backend_supports_key "$BACKEND" "$key" \
    || die "harness $HARNESS interrupts with $key, which the $BACKEND backend cannot deliver; refusing to send a different key"
  [ -z "$clear" ] || fm_control_backend_supports_key "$BACKEND" "$clear" \
    || die "harness $HARNESS needs $clear to clear its composer after an interrupt, which the $BACKEND backend cannot deliver; refusing to leave the cancelled prompt where the next submitted line would concatenate onto it"
  while [ "$i" -lt "$repeat" ]; do
    fm_backend_send_key "$BACKEND" "$T" "$key" "$LABEL" \
      || die "interrupt key $key was not delivered to task $ID on $BACKEND"
    i=$((i + 1))
    [ "$i" -ge "$repeat" ] || sleep 0.2
  done
  [ -z "$clear" ] || fm_backend_send_key "$BACKEND" "$T" "$clear" "$LABEL" \
    || die "interrupt key $key reached task $ID, but $clear did not, so its composer still holds the cancelled prompt; clear it before the next lifecycle action"
}

prepare_interrupt_ack() {
  INTERRUPT_ACK_SOURCE=$(fm_control_interrupt_ack_source "$HARNESS")
  INTERRUPT_ACK_LOG=
  INTERRUPT_ACK_RUN=
  case "$INTERRUPT_ACK_SOURCE" in
    muse-session-terminal)
      INTERRUPT_ACK_LOG=$(fm_busy_muse_session_log "$STATE" "$ID" 2>/dev/null || true)
      [ -n "$INTERRUPT_ACK_LOG" ] || return 0
      INTERRUPT_ACK_RUN=$(fm_busy_muse_active_run_id "$INTERRUPT_ACK_LOG" 2>/dev/null || true)
      ;;
  esac
}

interrupt_cancel_claim() {
  local elapsed=0 terminal=
  case "$INTERRUPT_ACK_SOURCE:$INTERRUPT_ACK_RUN" in
    muse-session-terminal:?*) ;;
    *) printf 'unconfirmed'; return 0 ;;
  esac
  while :; do
    terminal=$(fm_busy_muse_run_terminal "$INTERRUPT_ACK_LOG" "$INTERRUPT_ACK_RUN" 2>/dev/null || true)
    case "$terminal" in
      cancelled) printf 'confirmed'; return 0 ;;
      ?*) printf 'unconfirmed'; return 0 ;;
    esac
    awk -v e="$elapsed" -v t="$SETTLE_WAIT" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf 'unconfirmed'
}

# deliver_interrupt: deliver and observe the strongest adapter-owned
# cancellation claim available after delivery.
deliver_interrupt() {
  local cancel
  prepare_interrupt_ack
  send_interrupt_keys
  cancel=$(interrupt_cancel_claim)
  printf '%s' "$cancel"
}

verify_interrupt_running() {
  local proof after
  fm_backend_target_exists "$BACKEND" "$T" "$LABEL" \
    || die "task $ID's endpoint disappeared while interrupting it; no further control action is safe"
  proof=endpoint
  if fm_control_backend_state_verified "$BACKEND"; then
    # An interrupt cancels a turn; it must never have stopped the agent. This
    # is the postcondition that separates a landed interrupt from an accident.
    after=$(agent_state)
    [ "$after" = alive ] \
      || die "task $ID's agent is '$after' after its interrupt key; an interrupt must leave the agent running"
    proof=agent-alive
  fi
  printf '%s' "$proof"
}

do_interrupt() {
  local proof cancel
  cancel=$(deliver_interrupt) || return $?
  proof=$(verify_interrupt_running) || return $?
  printf '%s cancel=%s' "$proof" "$cancel"
}

retire_busy_incarnation() {
  if [ -f "$STATE/$ID.busy-gen" ]; then
    "$SCRIPT_DIR/fm-busy-event.sh" retire "$STATE" "$ID" --current-gen >/dev/null 2>&1 || true
  fi
}

# do_exit_agent_view: a pilot worker is its background session, so exit is
# `claude stop <id>`; `/exit` in its viewer would leave the worker running and
# turn the window into the agent view. A busy turn is not interrupted first:
# stopping the session ends it, and the conversation resumes whole on
# relaunch. The window's viewer client is then ended, so the window is back at
# its shell as an ordinary exit leaves it.
do_exit_agent_view() {
  local state result=stopped
  state=$(agent_state)
  case "$state" in
    dead|missing) result=already-stopped ;;
    alive)
      fm_agent_view_stop "$AGENT_VIEW_ID" \
        || die "claude stop $AGENT_VIEW_ID failed for task $ID; its background session may still be running"
      state=$(wait_agent_state "$EXIT_WAIT" dead missing) \
        || die "exit-delivered $ID stop=delivered agent-state=$state exit=unconfirmed; background session $AGENT_VIEW_ID did not stop within ${EXIT_WAIT}s"
      retire_busy_incarnation
      ;;
    *) die "task $ID's background session $AGENT_VIEW_ID reads '$state' rather than a positively classified state; refusing to act on a session that may not be this worker's alone" ;;
  esac
  fm_agent_view_release_window "$T" \
    || echo "warning: task $ID's background session is stopped, but window $T shows something other than its shell; a relaunch needs the window at its shell" >&2
  printf '%s' "$result"
}

# do_exit: stop the running agent, preserving endpoint and worktree. Prints
# `already-stopped` or `stopped`.
do_exit() {
  local state cmd verdict cancel interrupt_result=not-needed
  require_state_verified_backend exit
  if [ -n "$AGENT_VIEW_ID" ]; then
    do_exit_agent_view
    return
  fi
  state=$(agent_state)
  case "$state" in
    dead)
      printf 'already-stopped'
      return 0
      ;;
    alive) ;;
    missing) die "task $ID's recorded endpoint is gone, so there is no agent to stop; reconcile the task before any further control action" ;;
    *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle command into an unattributed endpoint" ;;
  esac
  # A busy agent is interrupted first before the exit command is submitted.
  case "$(busy_verdict)" in
    busy*)
      cancel=$(deliver_interrupt) || return $?
      state=$(agent_state)
      case "$state" in
        dead)
          retire_busy_incarnation
          printf 'stopped'
          return 0
          ;;
        alive) interrupt_result="delivered verified=agent-alive cancel=$cancel" ;;
        missing) die "task $ID's recorded endpoint disappeared after interrupt delivery, so exit cannot prove whether the agent stopped" ;;
        *) die "task $ID's endpoint reads '$state' after interrupt delivery rather than a positively classified state; exit cannot prove whether the agent stopped" ;;
      esac
      ;;
  esac
  cmd=$(fm_control_exit_command "$HARNESS")
  # The submit verdict is NOT the postcondition here: a successful exit command
  # destroys the composer the verdict is read from, so a post-exit read can
  # legitimately report anything. Only a hard transport failure aborts; the
  # authoritative proof is the agent-state wait below. The retried Enter still
  # matters, because a slash command opens a completion popup on some TUIs that
  # swallows the first Enter.
  verdict=$(fm_backend_send_text_submit "$BACKEND" "$T" "$cmd" "$EXIT_RETRIES" "$POLL" 1.2 "$LABEL") \
    || die "the exit command could not be sent to task $ID on $BACKEND"
  [ "$verdict" != send-failed ] \
    || die "the exit command could not be sent to task $ID on $BACKEND"
  state=$(wait_agent_state "$EXIT_WAIT" dead) || {
    die "exit-delivered $ID interrupt=$interrupt_result exit-command=delivered agent-state=$state exit=unconfirmed; the agent did not stop within ${EXIT_WAIT}s"
  }
  # The incarnation is over: retire its busy wiring so no stale record or
  # orphaned generation survives the agent that produced it.
  retire_busy_incarnation
  printf 'stopped'
}

# --- transactional relaunch -------------------------------------------------
#
# The transaction's durable record is state/<id>.control-relaunch, with the
# prior metadata and brief preserved beside it. Every failure path runs through
# relaunch_rollback (an EXIT trap, so a refusal raised deep inside a shared
# helper is covered too) and leaves either the pre-relaunch durable record or a
# concrete, named partial state - never a task whose record claims an agent
# that is not running.

JOURNAL="$STATE/$ID.control-relaunch"
META_PRIOR="$JOURNAL.meta-prior"
BRIEF_PRIOR="$JOURNAL.brief-prior"
NOTE_FILE="$JOURNAL.note"
RELAUNCH_META_PUBLISHED=0
RELAUNCH_AGENT_CONFIRMED=0
RELAUNCH_BRIEF_SAVED=0
RELAUNCH_TX=
RELAUNCH_BRIEF=
RELAUNCH_PR=
PRIOR_HARNESS=$HARNESS
PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
CONFIG_HARNESS=
CONFIG_MODEL=
CONFIG_EFFORT=
PRIOR_MODEL=
PRIOR_EFFORT=
TARGET_HARNESS=$HARNESS
TARGET_MODEL=
TARGET_EFFORT=

journal_write() {  # <phase> [extra-line]...
  local phase=$1
  shift
  if {
    echo "v1"
    echo "task=$ID"
    echo "phase=$phase"
    echo "action=$VERB"
    echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "backend=$BACKEND"
    echo "endpoint=$T"
    echo "worktree=$WT"
    echo "kind=$KIND"
    echo "from_harness=$PRIOR_RECORDED_HARNESS"
    echo "from_model=$PRIOR_MODEL"
    echo "from_effort=$PRIOR_EFFORT"
    echo "to_harness=$TARGET_HARNESS"
    echo "to_model=$TARGET_MODEL"
    echo "to_effort=$TARGET_EFFORT"
    local line
    for line in "$@"; do
      echo "$line"
    done
  } > "$JOURNAL.tmp" && mv -f "$JOURNAL.tmp" "$JOURNAL"; then
    RELAUNCH_PHASE=$phase
    return 0
  fi
  return 1
}

# restore_instructions: put back the instructions THIS transaction preserved,
# and never a copy an earlier transaction left beside the journal.
restore_instructions() {
  [ "$RELAUNCH_BRIEF_SAVED" = 1 ] && [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ] || return 0
  cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
}

relaunch_rollback() {
  local state retry="bin/fm-control.sh revive $ID can be run again"
  [ "${REVIVE_VIA:-}" != resume ] \
    || retry="bin/fm-control.sh revive $ID can be run again to retry the resume, or with --fresh to start it from its instructions and the restart note"
  [ "$RELAUNCH_ACTIVE" = 1 ] || return 0
  [ "$RELAUNCH_PHASE" != complete ] || return 0
  RELAUNCH_ACTIVE=0
  case "$RELAUNCH_PHASE" in
    checkpoint|noted)
      # The old agent was never touched. Restore the instructions byte-exact so
      # a refused relaunch leaves nothing behind.
      restore_instructions
      journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored" || true
      if [ "$VERB" = revive ]; then
        echo "error: revive of $ID was refused before anything was started; nothing changed" >&2
      else
        echo "error: relaunch of $ID was refused before its agent was touched; nothing changed" >&2
      fi
      ;;
    rearming)
      # The old agent was never touched, so its instructions are restored as
      # for any earlier refusal. The poll owner may already have rewritten the
      # record's PR lines or revoked the poll, so this claims no more than that.
      restore_instructions
      journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored-poll-not-rearmed" || true
      echo "error: $VERB of $ID was refused before its agent was touched, because its PR merge poll could not be re-armed; its instructions were restored. Re-arm the poll with bin/fm-pr-check.sh $ID $RELAUNCH_PR, then $VERB" >&2
      ;;
    reopening)
      # revive only: nothing was started. A window it did create is left at its
      # shell in the worktree, where the next revive simply uses it.
      restore_instructions
      journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored" || true
      echo "error: revive of $ID could not reopen its endpoint $T in $WT; no agent was started and its instructions were restored" >&2
      ;;
    stopping)
      state=$(agent_state 2>/dev/null || printf unknown)
      case "$state" in
        alive)
          restore_instructions
          journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored-agent-alive" || true
          echo "error: relaunch of $ID failed while stopping the old agent, which is still running; its original instructions were restored" >&2
          ;;
        dead)
          journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept-agent-dead" || true
          echo "error: $ID's agent stopped but relaunch did not reach replacement launch; no agent is running, and its work plus progress note are preserved at $WT" >&2
          ;;
        *)
          journal_write "failed:$RELAUNCH_PHASE" "rollback=none-agent-state-$state" || true
          echo "error: relaunch of $ID failed while stopping the old agent and its state is '$state'; the durable record and progress note were retained for recovery" >&2
          ;;
      esac
      ;;
    resuming)
      # revive only: the resumed agent was confirmed running, but not yet in
      # its recorded conversation.
      state=$(agent_state 2>/dev/null || printf unknown)
      if [ "$state" = alive ]; then
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-agent-running-resume-unconfirmed" || true
        echo "error: $ID's worker is running again in $T, but it was not confirmed to have resumed its recorded conversation $REVIVE_SESSION within ${LAUNCH_WAIT}s; look at the window before acting further. A later revive reports it as already running rather than starting a second one" >&2
      else
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-resume-exited" || true
        echo "error: $ID's resumed worker exited before it confirmed its recorded conversation $REVIVE_SESSION (its endpoint reads '$state'); no agent is running, and its work plus the restart note are preserved at $WT. Run bin/fm-control.sh revive $ID again to retry the resume, or with --fresh to start it from its instructions and the restart note" >&2
      fi
      ;;
    exited|launching)
      if [ "$RELAUNCH_AGENT_CONFIRMED" = 1 ]; then
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-agent-confirmed" || true
        echo "error: $ID's replacement is running on $TARGET_HARNESS, but transaction completion could not be persisted; its published record was retained for reconciliation" >&2
      elif [ "$RELAUNCH_META_PUBLISHED" = 1 ] \
         || { [ -n "$RELAUNCH_TX" ] \
              && [ "$(fm_meta_get "$META" control_relaunch_tx)" = "$RELAUNCH_TX" ]; }; then
        # The launch owner published the new incarnation's record. Leaving it
        # in place is the honest state: the task is now recorded on the new
        # harness with no agent confirmed, which is exactly what recovery
        # reconciles. Rewriting it back to the old harness would be a second,
        # worse inaccuracy.
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-record-kept" || true
        if [ "$VERB" = revive ]; then
          echo "error: $ID was launched again on $TARGET_HARNESS but no running agent could be confirmed; its work and restart note are preserved at $WT, and $retry" >&2
        else
          echo "error: $ID was relaunched on $TARGET_HARNESS but no running agent could be confirmed; its work is preserved at $WT" >&2
        fi
      else
        journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept" || true
        if [ "$VERB" = revive ]; then
          echo "error: $ID's worker did not launch; no agent is running, and its work plus the restart note are preserved at $WT, so $retry" >&2
        else
          echo "error: $ID's agent was stopped but the replacement did not launch; no agent is running, and its work plus the recorded progress note are preserved at $WT" >&2
        fi
      fi
      ;;
  esac
  return 0
}

resolve_relaunch_profile() {
  PRIOR_HARNESS=$HARNESS
  PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
  PRIOR_MODEL=$(fm_meta_get "$META" model)
  PRIOR_EFFORT=$(fm_meta_get "$META" effort)
  [ -n "$PRIOR_MODEL" ] || PRIOR_MODEL=default
  [ -n "$PRIOR_EFFORT" ] || PRIOR_EFFORT=default
  if [ "$HARNESS_SET" = 0 ] \
     && [ "$PRIOR_RECORDED_HARNESS" != "$PRIOR_HARNESS" ]; then
    die "task $ID records harness '$PRIOR_RECORDED_HARNESS', whose original launch command cannot be reconstructed from its recorded basename; relaunching without --harness would substitute the canonical adapter '$PRIOR_HARNESS' for the command actually running. Pass an explicit --harness to choose the replacement runtime deliberately"
  fi
  CONFIG_HARNESS=
  CONFIG_MODEL=
  CONFIG_EFFORT=
  if [ "$KIND" = secondmate ]; then
    # A secondmate's harness, model, and effort are a durable configured pin
    # that every respawn re-resolves (the secondmate-provisioning contract), so
    # a relaunch with no explicit harness picks up a newly configured one
    # instead of freezing whatever this incarnation happens to run. Crewmates
    # and scouts deliberately do NOT resolve config here: their harness comes
    # from firstmate's own dispatch-profile judgment at intake, and silently
    # re-resolving it would bypass that consultation.
    CONFIG_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" secondmate 2>/dev/null || true)
    CONFIG_MODEL=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model 2>/dev/null || true)
    CONFIG_EFFORT=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort 2>/dev/null || true)
    case "$CONFIG_EFFORT" in
      ''|low|medium|high|xhigh|max) ;;
      *)
        echo "warning: config/secondmate-harness effort token '$CONFIG_EFFORT' is not one of low, medium, high, xhigh, max; ignoring" >&2
        CONFIG_EFFORT=
        ;;
    esac
  fi
  if [ "$HARNESS_SET" = 1 ]; then
    fm_control_harness_supported "$NEW_HARNESS" \
      || die "'$NEW_HARNESS' is not a verified harness; fm-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$NEW_HARNESS
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    fm_control_harness_supported "$CONFIG_HARNESS" \
      || die "the configured secondmate harness '$CONFIG_HARNESS' is not verified; fm-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$CONFIG_HARNESS
  else
    TARGET_HARNESS=$PRIOR_HARNESS
  fi
  # The launch owner refuses an adapter that cannot run this task's kind, but it
  # is only reached after the old agent has been stopped. Asking the same
  # capability table here keeps that refusal on the pre-stop side of the
  # transaction, where nothing has changed yet.
  fm_control_harness_supports_kind "$TARGET_HARNESS" "$KIND" \
    || die "'$TARGET_HARNESS' is not verified to run a $KIND task, so relaunching $ID onto it would stop the running agent for a launch that must be refused; choose an adapter verified for this kind"
  # A model or effort chosen for the previous harness does not transfer to a
  # different one, so an explicit harness change resets both axes unless the
  # caller names them too.
  if [ "$MODEL_SET" = 1 ]; then
    TARGET_MODEL=$NEW_MODEL
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    TARGET_MODEL=${CONFIG_MODEL:-default}
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_MODEL=$PRIOR_MODEL
  else
    TARGET_MODEL=default
  fi
  if [ "$EFFORT_SET" = 1 ]; then
    TARGET_EFFORT=$NEW_EFFORT
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    TARGET_EFFORT=${CONFIG_EFFORT:-default}
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_EFFORT=$PRIOR_EFFORT
  else
    TARGET_EFFORT=default
  fi
}

# safe_checkpoint: prove, before anything is stopped, that the work a relaunch
# must preserve is actually there and recoverable afterwards. Fills
# CHECKPOINT_LINES with the journal lines describing what it proved, and
# refuses outright when any of it cannot be established.
CHECKPOINT_LINES=()
safe_checkpoint() {
  local wt_real wt_top wt_top_real head head_ref head_ref_status status_output dirty children marker child_meta
  CHECKPOINT_LINES=()
  [ -n "$WT" ] || die "task $ID has no recorded worktree; refusing to $VERB without a recorded local copy to preserve"
  [ -d "$WT" ] || die "task $ID's recorded worktree $WT is missing; refusing to $VERB and lose track of its work"
  wt_real=$(cd "$WT" 2>/dev/null && pwd -P) || die "task $ID's recorded worktree $WT cannot be resolved"
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null) \
    || die "task $ID's recorded worktree $WT is not a git worktree; refusing to $VERB without a checkout whose unlanded work can be accounted for"
  wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P) || wt_top_real=$wt_top
  [ "$wt_real" = "$wt_top_real" ] \
    || die "task $ID's recorded worktree $WT is not a worktree root (root is $wt_top); refusing to $VERB against an ambiguous checkout"
  if head=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null); then
    :
  elif head_ref=$(git -C "$WT" symbolic-ref -q HEAD 2>/dev/null); then
    if git -C "$WT" show-ref --verify --quiet "$head_ref" 2>/dev/null; then
      die "task $ID's worktree HEAD exists but cannot be resolved; refusing to $VERB from an unreadable checkout"
    else
      head_ref_status=$?
      [ "$head_ref_status" -eq 1 ] \
        || die "task $ID's worktree HEAD cannot be inspected; refusing to $VERB from an unreadable checkout"
      head=unborn
    fi
  else
    die "task $ID's worktree HEAD cannot be inspected; refusing to $VERB from an unreadable checkout"
  fi
  status_output=$(git -C "$WT" status --porcelain 2>/dev/null) \
    || die "task $ID's worktree status cannot be inspected; refusing to $VERB without accounting for local changes"
  if [ -n "$status_output" ]; then
    dirty=yes
  else
    dirty=no
  fi
  CHECKPOINT_LINES+=("worktree_head=$head" "worktree_dirty=$dirty")
  if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ]; then
    fm_slot_verdict "$STATE" "$ID" || die "task $ID has no readable record at $META; refusing to $VERB"
    case "$FM_SLOT_VERDICT" in
      own) ;;
      released)
        if [ "$VERB" = revive ]; then
          die "task $ID's recorded worktree $WT is no longer its own: $FM_SLOT_EVIDENCE; refusing to revive a worker inside another holder's working copy. Retire only this task's record with bin/fm-teardown.sh $ID --retire-record, or spawn the task afresh from its branch through bin/fm-spawn.sh, which takes a durable lease under the task's own claim"
        fi
        die "task $ID's recorded worktree $WT is no longer its own: $FM_SLOT_EVIDENCE; refusing to relaunch a replacement inside another holder's working copy. Stop the agent with bin/fm-control.sh $ID exit, then retire only this task's record with bin/fm-teardown.sh $ID --retire-record or spawn the task afresh from its branch through bin/fm-spawn.sh, which takes a durable lease under the task's own claim"
        ;;
      *)
        if [ "$VERB" = revive ]; then
          die "cannot prove task $ID still owns its recorded worktree $WT: $FM_SLOT_EVIDENCE; refusing to revive a worker into a working copy that may hold another task's work, because ownership is never inferred. Spawn the task afresh from its branch through bin/fm-spawn.sh, which takes a durable lease under the task's own claim; or confirm by hand whose work the copy holds and tear the task down normally once its work has landed"
        fi
        die "cannot prove task $ID still owns its recorded worktree $WT: $FM_SLOT_EVIDENCE; refusing to relaunch a replacement into a working copy that may hold another task's work, because ownership is never inferred. Stop the agent with bin/fm-control.sh $ID exit, then spawn the task afresh from its branch through bin/fm-spawn.sh, which takes a durable lease under the task's own claim; or confirm by hand whose work the copy holds and tear the task down normally once its work has landed"
        ;;
    esac
  fi
  if [ "$KIND" = secondmate ]; then
    # A secondmate's own crewmates outlive its relaunch: they run in their own
    # endpoints, and the relaunched secondmate reconciles them from its home's
    # durable records at startup. The checkpoint proves those records are
    # readable BEFORE the agent stops, so a relaunch can never strand child
    # work behind an unreadable home.
    marker=$(cat "$WT/.fm-secondmate-home" 2>/dev/null || true)
    [ "$marker" = "$ID" ] \
      || die "task $ID's home $WT is not marked as its own seeded secondmate home (marker: ${marker:-none}); refusing to $VERB"
    [ -d "$WT/state" ] \
      || die "secondmate $ID's home has no readable state directory, so its child work cannot be accounted for; refusing to $VERB"
    find "$WT/state" -mindepth 1 -maxdepth 1 -print >/dev/null 2>&1 \
      || die "secondmate $ID's child records cannot be traversed; refusing to $VERB"
    children=0
    for child_meta in "$WT/state"/*.meta; do
      if [ ! -e "$child_meta" ] && [ ! -L "$child_meta" ]; then
        continue
      fi
      if [ ! -f "$child_meta" ] || [ -L "$child_meta" ] \
         || ! cat "$child_meta" >/dev/null 2>&1; then
        die "secondmate $ID's child record $child_meta is not a readable regular file; refusing to $VERB"
      fi
      children=$((children + 1))
    done
    CHECKPOINT_LINES+=("children=$children")
  fi
}

# rearm_pr_poll: a task that records a PR has a merge poll bound to its record,
# and a relaunch must never publish a replacement whose poll the watcher would
# quarantine. Rebuild the poll through its single owner, bin/fm-pr-check.sh,
# while the old agent is still running and before the launch owner publishes
# the new generation, which keeps the PR lines last so the rebuilt poll stays
# armed across that publication. A task without a recorded PR is untouched.
# It runs after record_note, so a failure restores instructions this same
# transaction preserved rather than a copy an earlier relaunch left behind.
rearm_pr_poll() {  # <journal-line>...
  RELAUNCH_PR=$(fm_meta_get "$META" pr)
  [ -n "$RELAUNCH_PR" ] || return 0
  journal_write rearming "$@"
  "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$RELAUNCH_PR" >/dev/null \
    || die "the PR merge poll for $ID could not be re-armed from its recorded PR $RELAUNCH_PR"
}

# record_note: put the required progress note somewhere durable, and - for a
# ship or scout, whose only record of the interrupted reasoning is the
# conversation about to be discarded - into the instructions the replacement
# actually reads. A secondmate's charter is a durable standing document and is
# never rewritten: a secondmate reconciles its own home's records at startup,
# so the note stays parent-side audit evidence.
record_note() {
  local stamp
  [ -n "$NOTE" ] || return 0
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\n' "$NOTE" > "$NOTE_FILE"
  case "$KIND" in
    ship|scout)
      cp -p "$RELAUNCH_BRIEF" "$BRIEF_PRIOR" \
        || die "could not preserve task $ID's instructions before recording the progress note"
      RELAUNCH_BRIEF_SAVED=1
      {
        echo
        echo "## Progress note ($stamp)"
        echo
        echo "This task was relaunched. Continue from here; the local copy and every"
        echo "uncommitted change are exactly as the previous worker left them."
        echo
        printf '%s\n' "$NOTE"
      } >> "$RELAUNCH_BRIEF" \
        || die "could not append the progress note to task $ID's instructions"
      ;;
  esac
}

# agent_view_relaunch_plan: what relaunch does for a pilot worker, from its
# background session and window (see the header): reattach, restart, resume,
# or fresh. A session that still holds its conversation takes no progress
# note, because a resumed conversation never re-reads its instructions.
AGENT_VIEW_PLAN=
agent_view_relaunch_plan() {
  local state viewer
  [ "$HARNESS_SET" = 0 ] && [ "$MODEL_SET" = 0 ] && [ "$EFFORT_SET" = 0 ] \
    || die "task $ID is an agent-view pilot worker, which relaunches only as itself; --harness, --model, and --effort do not apply to it"
  state=$(agent_state)
  case "$state" in
    alive)
      viewer=$(fm_agent_view_viewer_state "$T" "$ID" "$AGENT_VIEW_ID")
      case "$viewer" in
        session) AGENT_VIEW_PLAN=restart ;;
        detached) AGENT_VIEW_PLAN=reattach ;;
        *) die "task $ID's window $T reads '$viewer', so no viewer can be attached there; its background session $AGENT_VIEW_ID is still running" ;;
      esac
      ;;
    dead) AGENT_VIEW_PLAN=resume ;;
    missing) AGENT_VIEW_PLAN=fresh ;;
    *) die "cannot prove the state of task $ID's background session $AGENT_VIEW_ID (it reads '$state'); refusing to relaunch alongside an agent that may still own $WT" ;;
  esac
  if [ "$AGENT_VIEW_PLAN" != fresh ] && [ "$NOTE_SET" = 1 ]; then
    die "task $ID's background session $AGENT_VIEW_ID still holds its conversation, so relaunch resumes it rather than starting a fresh worker from its instructions, and a progress note would never be read; relaunch without --note, then steer it with bin/fm-send.sh"
  fi
}

# agent_view_reattach: give a running pilot session a fresh viewer in its
# window. The session, its turn, and every durable record stay as they are, so
# no transaction is journaled.
agent_view_reattach() {
  local rc=0
  fm_agent_view_release_window "$T" \
    || die "task $ID's window $T shows something other than a Claude Code viewer or its shell, so no viewer can be attached there; its background session $AGENT_VIEW_ID is still running"
  fm_agent_view_attach_window "$T" "$ID" "$AGENT_VIEW_ID" "$LAUNCH_WAIT" || rc=$?
  case "$rc" in
    0) ;;
    1) die "task $ID's window $T is not at its shell, so no viewer was attached; its background session $AGENT_VIEW_ID is still running" ;;
    *) die "a viewer of task $ID's background session $AGENT_VIEW_ID was started in window $T but could not be confirmed showing it within ${LAUNCH_WAIT}s, so firstmate still refuses to type there; the session is still running" ;;
  esac
  echo "${VERB%e}ed $ID harness=$TARGET_HARNESS from=$PRIOR_RECORDED_HARNESS model=$TARGET_MODEL effort=$TARGET_EFFORT backend=$BACKEND endpoint=$T worktree=$WT agent_view=$AGENT_VIEW_ID via=reattach"
}

do_relaunch() {
  local exit_result state note_line agent_view_report=
  local -a spawn_args

  require_state_verified_backend relaunch
  # A gone endpoint has no agent to replace and no shell to launch one in, so
  # it is refused here, before a checkpoint, note, or poll is written.
  if [ "$(fm_backend_agent_state "$BACKEND" "$T")" = missing ]; then
    if [ "$KIND" = secondmate ]; then
      die "secondmate $ID's recorded endpoint $T is gone, so there is no agent to replace; the startup secondmate check brings a secondmate whose endpoint is gone back, so reconcile it through the secondmate recovery path"
    fi
    die "task $ID's recorded endpoint $T is gone, so there is no agent to replace and nowhere to launch one; bring the worker back with bin/fm-control.sh revive $ID, which reopens the endpoint in its recorded worktree"
  fi
  [ -z "$AGENT_VIEW_ID" ] || agent_view_relaunch_plan
  resolve_relaunch_profile
  if [ "$AGENT_VIEW_PLAN" = reattach ]; then
    agent_view_reattach
    return
  fi

  case "$KIND" in
    ship|scout)
      RELAUNCH_BRIEF="$DATA/$ID/brief.md"
      [ -f "$RELAUNCH_BRIEF" ] \
        || die "task $ID has no instructions at $RELAUNCH_BRIEF; refusing to relaunch a worker with nothing to work from"
      case "$AGENT_VIEW_PLAN" in
        restart|resume) ;;
        *)
          [ "$NOTE_SET" = 1 ] && [ -n "$NOTE" ] \
            || die "relaunch of a $KIND task requires --note (or --note-file): the replacement worker inherits the local copy but none of the conversation, so it must be told what happened"
          ;;
      esac
      ;;
    secondmate)
      # The charter in the secondmate's own home is its instruction source and
      # stays untouched.
      RELAUNCH_BRIEF=
      ;;
    *)
      die "task $ID records kind '$KIND', which has no defined relaunch shape"
      ;;
  esac

  if [ -n "$NOTE" ]; then
    note_line="note_file=$NOTE_FILE"
  else
    note_line="note=none"
  fi
  safe_checkpoint
  cp -p "$META" "$META_PRIOR" || die "could not preserve task $ID's durable record before relaunching"
  RELAUNCH_ACTIVE=1
  journal_write checkpoint "${CHECKPOINT_LINES[@]}" "$note_line"

  record_note
  journal_write noted "${CHECKPOINT_LINES[@]}" "$note_line"

  rearm_pr_poll "${CHECKPOINT_LINES[@]}" "$note_line"

  journal_write stopping "${CHECKPOINT_LINES[@]}" "$note_line"
  exit_result=$(do_exit)
  journal_write exited "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result"

  # The launch owner (fm-spawn --relaunch) clears the previous incarnation's
  # per-task harness wiring before arming the new one, so nothing to do here.
  RELAUNCH_TX="${BASHPID:-$$}.$(date -u +%Y%m%dT%H%M%SZ).$RANDOM"
  journal_write launching "${CHECKPOINT_LINES[@]}" "$note_line" "relaunch_tx=$RELAUNCH_TX"
  spawn_args=("$ID" --relaunch --harness "$TARGET_HARNESS")
  [ "$TARGET_MODEL" = default ] || spawn_args+=(--model "$TARGET_MODEL")
  [ "$TARGET_EFFORT" = default ] || spawn_args+=(--effort "$TARGET_EFFORT")
  if FM_CONTROL_RELAUNCH_TX="$RELAUNCH_TX" \
      "$SCRIPT_DIR/fm-spawn.sh" "${spawn_args[@]}" >/dev/null; then
    RELAUNCH_META_PUBLISHED=1
  else
    [ "$(fm_meta_get "$META" control_relaunch_tx)" != "$RELAUNCH_TX" ] \
      || RELAUNCH_META_PUBLISHED=1
    die "the replacement agent for $ID could not be launched on $TARGET_HARNESS"
  fi

  state=$(wait_agent_state "$LAUNCH_WAIT" alive) || {
    die "the replacement agent for $ID did not come up within ${LAUNCH_WAIT}s (endpoint reads '$state')"
  }
  RELAUNCH_AGENT_CONFIRMED=1

  journal_write complete "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result"
  RELAUNCH_ACTIVE=0
  [ -z "$AGENT_VIEW_PLAN" ] \
    || agent_view_report=" agent_view=$(fm_meta_get "$META" agent_view_id) via=$AGENT_VIEW_PLAN"
  echo "relaunched $ID harness=$TARGET_HARNESS from=$PRIOR_RECORDED_HARNESS model=$TARGET_MODEL effort=$TARGET_EFFORT backend=$BACKEND endpoint=$T worktree=$WT$agent_view_report"
}

# --- revive -----------------------------------------------------------------
#
# revive reuses the relaunch transaction above - its journal, checkpoint, poll
# re-arm, single launch owner, and rollback - with no old agent to stop, and
# with one step relaunch never needs: reopening a gone endpoint. Its journal
# phases are checkpoint, noted, rearming (only with a recorded PR), reopening
# (only when the endpoint is gone), launching, resuming (only when a recorded
# conversation is resumed), and complete.

WINDOW_STATE=
REVIVE_VIA=
REVIVE_SESSION=
REVIVE_WHY=

real_dir() {  # <path>
  (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"
}

# revive_validation_lines: for a no-mistakes ship task, what no-mistakes says
# must happen first on the branch, quoted from its own structured next action.
revive_validation_lines() {
  local run next cmd step run_part=''
  [ "$KIND" = ship ] && [ "$(fm_meta_get "$META" mode)" = no-mistakes ] || return 0
  if ! fm_restart_validation_read "$WT" "$NM_TIMEOUT"; then
    echo "Validation: no-mistakes could not be asked about this branch just now. Before any edit, commit, or new validation run, run \`no-mistakes axi status\` here and follow its branch_sync.next_action exactly."
    return 0
  fi
  run=$FM_RESTART_NM_RUN
  next=$FM_RESTART_NM_NEXT
  cmd=$FM_RESTART_NM_COMMAND
  [ "$run" = none ] || run_part=" (its status: $run)"
  if [ -n "$cmd" ]; then
    step="run exactly \`$cmd\`"
  else
    step="run exactly the command \`no-mistakes axi status\` names as branch_sync.next_action.command"
  fi
  case "$next" in
    recover_custody)
      echo "Validation: no-mistakes reports that this branch's validation run$run_part still holds the branch and must hand it back first. Before any edit, commit, or new validation run, $step, then confirm with \`no-mistakes axi status\` that branch_sync.next_action no longer asks for recovery. That run cannot continue, so after that confirmation, validate once more from the recovered head."
      ;;
    continue_active_run)
      echo "Validation: no-mistakes reports that a validation run$run_part still owns this branch. Do not edit, commit, or start a new run; continue that run from \`no-mistakes axi status\`, whose next action is to $step."
      ;;
    sync)
      echo "Validation: no-mistakes reports that this branch must first be brought to its validated head. Before any edit, commit, or new validation run, $step."
      ;;
    none)
      [ "$run" != none ] || return 0
      echo "Validation: no-mistakes reports this branch's latest validation run as $run, with nothing to recover. Check \`no-mistakes axi status\` before continuing from it."
      ;;
    *)
      echo "Validation: no-mistakes reports \`$next\` as this branch's next action. Before any edit, commit, or new validation run, $step."
      ;;
  esac
  echo "That is what no-mistakes said when this note was written; \`no-mistakes axi status\` is the current answer."
}

# revive_note_body: the restart note. It is the same text for every attempt at
# the same state, so a retried revive recognizes the note it already recorded.
revive_note_body() {
  local validation
  validation=$(revive_validation_lines)
  echo "You were stopped - the machine or its terminal restarted, or your agent exited - and have been brought back into the same local copy."
  echo "Every commit and uncommitted change there is exactly as it was left, but anything that was running in it, such as a build, a test, or a validation run, may have been ended by the stop."
  if [ -n "$validation" ]; then
    echo
    printf '%s\n' "$validation"
  fi
  echo
  echo "Continue the task from where it stopped."
}

# brief_ends_with: 0 when the instructions already end with <text> - the same
# note recorded by an earlier attempt, which is never appended twice in a row.
brief_ends_with() {  # <text>
  local want
  want=$(printf '%s\n' "$1" | wc -c | tr -d ' ')
  [ "$(wc -c < "$RELAUNCH_BRIEF" | tr -d ' ')" -ge "$want" ] || return 1
  tail -c "$want" "$RELAUNCH_BRIEF" | cmp -s - <(printf '%s\n' "$1")
}

# revive_record_note: write the restart note beside the journal, which is also
# the message a resumed conversation receives next, and append it to the
# instructions a fresh agent reads unless they already end with it.
revive_record_note() {  # <note-body> <into-instructions: 1|0>
  local body=$1 into=$2 stamp
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  {
    printf 'Restart note from firstmate (%s)\n\n' "$stamp"
    printf '%s\n' "$body"
  } > "$NOTE_FILE" || die "could not record the restart note for task $ID"
  [ "$into" = 1 ] || return 0
  ! brief_ends_with "$body" || return 0
  cp -p "$RELAUNCH_BRIEF" "$BRIEF_PRIOR" \
    || die "could not preserve task $ID's instructions before recording the restart note"
  RELAUNCH_BRIEF_SAVED=1
  {
    echo
    echo "## Restart note ($stamp)"
    echo
    printf '%s\n' "$body"
  } >> "$RELAUNCH_BRIEF" \
    || die "could not append the restart note to task $ID's instructions"
}

# reopen_endpoint: recreate the gone endpoint under its recorded identity and
# settle its shell in the recorded worktree the way a fresh spawn does: the
# shell starts beside the worktree and a typed cd moves it in, so seeing it
# there proves it finished its startup files and read that line. A shell
# started inside the worktree can read as idle and then still run a startup
# program, which the launch owner's agent-free check refuses. Settled means
# idle in the worktree on two consecutive reads, as fm-spawn.sh's own cd wait
# requires, because a brand-new window can briefly report a stale path.
reopen_endpoint() {
  local state='' seen='' settled=0 elapsed=0
  fm_backend_recreate_task "$BACKEND" "$T" "$(dirname -- "$WT")" >/dev/null \
    || die "task $ID's endpoint $T could not be reopened beside $WT"
  fm_backend_tmux_send_text_line "$T" "cd -- '${WT//\'/\'\\\'\'}'" \
    || die "task $ID's reopened endpoint $T could not be sent the move into $WT"
  while :; do
    seen=$(fm_backend_tmux_current_path "$T")
    state=$(window_state)
    if [ "$state" = dead ] && [ -n "$seen" ] \
       && [ "$(real_dir "$seen")" = "$(real_dir "$WT")" ]; then
      settled=$((settled + 1))
      [ "$settled" -lt 2 ] || return 0
    else
      settled=0
    fi
    awk -v e="$elapsed" -v t="$LAUNCH_WAIT" 'BEGIN{exit !(e < t)}' \
      || die "task $ID's reopened endpoint $T did not settle as an idle shell in $WT within ${LAUNCH_WAIT}s (it reads '$state' in '${seen:-unknown}')"
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
}

# confirm_resumed: a resume is done only once the resumed session's own hook
# has recorded the same session id under the generation this launch armed.
confirm_resumed() {
  local record gen sid state elapsed=0
  record=$(fm_harness_session_path "$STATE" "$ID")
  gen=$(fm_busy_current_gen "$STATE" "$ID" 2>/dev/null) || gen=
  [ -n "$gen" ] || die "task $ID's new agent has no busy-state generation, so its resume cannot be confirmed"
  while :; do
    if [ "$(fm_harness_session_get "$record" gen)" = "$gen" ]; then
      sid=$(fm_harness_session_get "$record" session_id)
      [ "$sid" = "$REVIVE_SESSION" ] \
        || die "task $ID's agent came back in conversation ${sid:-unknown} rather than its recorded $REVIVE_SESSION"
      return 0
    fi
    state=$(agent_state)
    [ "$state" = alive ] || die "task $ID's resumed agent exited (its endpoint reads '$state')"
    awk -v e="$elapsed" -v t="$LAUNCH_WAIT" 'BEGIN{exit !(e < t)}' \
      || die "task $ID's resumed agent did not confirm its recorded conversation $REVIVE_SESSION within ${LAUNCH_WAIT}s"
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
}

# revive_transaction: the relaunch transaction without an agent to stop. The
# note goes into the instructions unless a pilot resumes its own session.
revive_transaction() {  # <note-into-instructions: 1|0>
  local into=$1 body state note_line="note_file=$NOTE_FILE" why_line='' report
  local -a spawn_args
  body=$(revive_note_body)
  [ -z "$REVIVE_WHY" ] || why_line="fresh_because=$REVIVE_WHY"
  cp -p "$META" "$META_PRIOR" || die "could not preserve task $ID's durable record before reviving"
  RELAUNCH_ACTIVE=1
  journal_write checkpoint "${CHECKPOINT_LINES[@]}" "$note_line" "via=$REVIVE_VIA" ${why_line:+"$why_line"}

  revive_record_note "$body" "$into"
  journal_write noted "${CHECKPOINT_LINES[@]}" "$note_line" "via=$REVIVE_VIA" ${why_line:+"$why_line"}

  rearm_pr_poll "${CHECKPOINT_LINES[@]}" "$note_line" "via=$REVIVE_VIA"

  if [ "$WINDOW_STATE" = missing ]; then
    journal_write reopening "${CHECKPOINT_LINES[@]}" "$note_line" "via=$REVIVE_VIA"
    reopen_endpoint
  elif [ -n "$AGENT_VIEW_ID" ]; then
    fm_agent_view_release_window "$T" \
      || die "task $ID's window $T shows something other than a Claude Code viewer or its shell, so its worker cannot be brought back there"
  fi

  RELAUNCH_TX="${BASHPID:-$$}.$(date -u +%Y%m%dT%H%M%SZ).$RANDOM"
  journal_write launching "${CHECKPOINT_LINES[@]}" "$note_line" "via=$REVIVE_VIA" "relaunch_tx=$RELAUNCH_TX"
  spawn_args=("$ID" --relaunch --harness "$TARGET_HARNESS")
  [ "$TARGET_MODEL" = default ] || spawn_args+=(--model "$TARGET_MODEL")
  [ "$TARGET_EFFORT" = default ] || spawn_args+=(--effort "$TARGET_EFFORT")
  if [ "$REVIVE_VIA" = resume ] && [ -z "$AGENT_VIEW_ID" ]; then
    spawn_args+=(--resume-session "$REVIVE_SESSION" --resume-prompt "$NOTE_FILE")
  fi
  if FM_CONTROL_RELAUNCH_TX="$RELAUNCH_TX" \
      "$SCRIPT_DIR/fm-spawn.sh" "${spawn_args[@]}" >/dev/null; then
    RELAUNCH_META_PUBLISHED=1
  else
    [ "$(fm_meta_get "$META" control_relaunch_tx)" != "$RELAUNCH_TX" ] \
      || RELAUNCH_META_PUBLISHED=1
    die "the worker for $ID could not be launched again on $TARGET_HARNESS"
  fi

  state=$(wait_agent_state "$LAUNCH_WAIT" alive) || {
    die "the worker for $ID did not come up within ${LAUNCH_WAIT}s (it reads '$state')"
  }
  RELAUNCH_AGENT_CONFIRMED=1

  if [ "$REVIVE_VIA" = resume ] && [ -z "$AGENT_VIEW_ID" ]; then
    journal_write resuming "${CHECKPOINT_LINES[@]}" "$note_line" "via=$REVIVE_VIA" "session=$REVIVE_SESSION"
    confirm_resumed
  fi

  journal_write complete "${CHECKPOINT_LINES[@]}" "$note_line" "via=$REVIVE_VIA" ${why_line:+"$why_line"}
  RELAUNCH_ACTIVE=0
  report="revived $ID via=$REVIVE_VIA harness=$TARGET_HARNESS model=$TARGET_MODEL effort=$TARGET_EFFORT backend=$BACKEND endpoint=$T worktree=$WT"
  [ "$REVIVE_VIA" != resume ] || [ -n "$AGENT_VIEW_ID" ] || report="$report session=$REVIVE_SESSION"
  [ -z "$AGENT_VIEW_ID" ] || report="$report agent_view=$(fm_meta_get "$META" agent_view_id)"
  [ "$WINDOW_STATE" != missing ] || report="$report reopened=yes"
  [ -z "$REVIVE_WHY" ] || report="$report fresh_because=\"$REVIVE_WHY\""
  echo "$report"
}

# revive_agent_view: a pilot worker's conversation is its background session.
# A running session that its window shows is already running; one whose window
# or viewer is gone gets a window and a viewer back and nothing durable
# changes; a stopped session is resumed, and only a session that no longer
# exists starts afresh from the instructions and the restart note.
revive_agent_view() {
  local session
  session=$(agent_state)
  case "$session" in
    alive|dead|missing) ;;
    *) die "cannot prove the state of task $ID's background session $AGENT_VIEW_ID (it reads '$session'); refusing to revive alongside an agent that may still own $WT" ;;
  esac
  if [ "$session" = alive ] && [ "$WINDOW_STATE" != missing ] \
     && [ "$(fm_agent_view_viewer_state "$T" "$ID" "$AGENT_VIEW_ID")" = session ]; then
    echo "already-running $ID harness=$HARNESS backend=$BACKEND endpoint=$T worktree=$WT agent_view=$AGENT_VIEW_ID"
    return 0
  fi
  safe_checkpoint
  if [ "$session" = alive ]; then
    [ "$WINDOW_STATE" != missing ] || reopen_endpoint
    agent_view_reattach
    return
  fi
  if [ "$session" = dead ]; then
    REVIVE_VIA=resume
    revive_transaction 0
  else
    REVIVE_VIA=fresh
    REVIVE_WHY="its background session no longer exists"
    revive_transaction 1
  fi
}

do_revive() {
  require_state_verified_backend revive
  case "$KIND" in
    ship|scout) ;;
    secondmate) die "task $ID is a secondmate; the startup secondmate check brings back a secondmate whose agent stopped, so revive leaves it to the secondmate recovery path" ;;
    *) die "task $ID records kind '$KIND', which has no defined revive shape" ;;
  esac
  WINDOW_STATE=$(window_state)
  case "$WINDOW_STATE" in
    alive|dead|missing) ;;
    *) die "task $ID's endpoint $T reads '$WINDOW_STATE' rather than a positively classified state; refusing to revive into an endpoint that may still hold an agent" ;;
  esac
  if [ "$WINDOW_STATE" = alive ] && [ -z "$AGENT_VIEW_ID" ]; then
    echo "already-running $ID harness=$HARNESS backend=$BACKEND endpoint=$T worktree=$WT"
    return 0
  fi
  [ "$WINDOW_STATE" != missing ] || [ "$BACKEND" = tmux ] \
    || die "task $ID's endpoint is gone, and the $BACKEND backend cannot reopen a gone endpoint under its recorded identity; spawn the task afresh from its branch through bin/fm-spawn.sh"
  [ "$RECORDED_HARNESS" = "$HARNESS" ] \
    || die "task $ID records harness '$RECORDED_HARNESS', a raw launch command whose original form cannot be rebuilt from its recorded name, so revive cannot bring it back as itself; spawn the task afresh from its branch through bin/fm-spawn.sh"
  RELAUNCH_BRIEF="$DATA/$ID/brief.md"
  [ -f "$RELAUNCH_BRIEF" ] \
    || die "task $ID has no instructions at $RELAUNCH_BRIEF; refusing to revive a worker with nothing to work from"
  resolve_relaunch_profile
  if [ -n "$AGENT_VIEW_ID" ]; then
    [ "$FRESH" = 0 ] \
      || die "task $ID is an agent-view pilot worker, whose conversation is its own background session; --fresh does not apply to it"
    revive_agent_view
    return
  fi
  safe_checkpoint
  if [ "$FRESH" = 1 ]; then
    REVIVE_VIA=fresh
    REVIVE_WHY="--fresh was passed"
  elif fm_harness_session_resumable "$STATE" "$ID"; then
    REVIVE_VIA=resume
    REVIVE_SESSION=$FM_HARNESS_SESSION_ID
  else
    REVIVE_VIA=fresh
    REVIVE_WHY=$FM_HARNESS_SESSION_REASON
  fi
  revive_transaction 1
}

# --- verbs ------------------------------------------------------------------

case "$VERB" in
  interrupt)
    state=$(agent_state)
    case "$state" in
      alive) ;;
      unverified)
        # No recovery-grade classifier on this backend. Interrupt is
        # non-destructive and its endpoint-existence postcondition is still
        # real, so it proceeds - the printed proof names exactly what was
        # verified rather than implying more.
        ;;
      dead|missing) die "no agent is running at task $ID's recorded endpoint (state: $state); there is nothing to interrupt" ;;
      *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle key into an unattributed endpoint" ;;
    esac
    if [ -n "$AGENT_VIEW_ID" ]; then
      fm_agent_view_input_guard "$ID" "$AGENT_VIEW_ID" "$T" key "$(fm_control_interrupt_key "$HARNESS")" || exit 1
    fi
    proof=$(do_interrupt)
    echo "interrupt-delivered $ID harness=$HARNESS backend=$BACKEND verified=$proof"
    ;;
  exit)
    result=$(do_exit)
    echo "$result $ID harness=$HARNESS backend=$BACKEND endpoint=$T worktree=$WT"
    ;;
  relaunch)
    do_relaunch
    ;;
  revive)
    do_revive
    ;;
esac
