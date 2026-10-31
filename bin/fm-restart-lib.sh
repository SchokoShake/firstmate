# shellcheck shell=bash
# fm-restart-lib.sh - recognizing that the machine restarted, and the durable
# list of the workers that restart stopped. ONE owner for how a restart is
# detected, for the two records below, and for which tasks count as stopped by
# one. bin/fm-session-start.sh prints its restart section from here, and
# bin/fm-control.sh revive --stopped-by-restart brings back the tasks it lists
# as stopped by the restart.
# Nothing here brings a worker back: a restart is reported, and bringing
# workers back stays a deliberate action.
#
# DETECTION IS A KERNEL FACT, never an uptime heuristic. The kernel's boot id is
# random per boot and fixed within one: /proc/sys/kernel/random/boot_id on
# Linux (WSL included) and kern.bootsessionuuid on macOS. A boot id that differs
# from the recorded one proves a restart; uptime and process ages only guess.
# A host offering neither has no restart detection, and the session-start
# digest still shows each gone endpoint as dead. FM_BOOT_ID_FILE replaces the
# kernel source with a file, so a test can simulate a restart.
#
# state/.boot-id - the boot id the last LOCKED session start saw. A read-only
# session never writes it, so it cannot swallow a restart the lock holder has
# not reported yet.
#
# state/.restart-stopped - written by the locked session start that first sees
# a new boot id, and retired by a later locked start once no task it lists as
# task or unarmed is still stopped:
#   v1
#   detected=<ISO-8601 UTC>
#   previous_boot=<boot id>
#   boot=<boot id>
#   task=<id>                     one per task whose recorded endpoint was gone
#                                 and whose agent's busy generation was still
#                                 armed, so it was not deliberately stopped:
#                                 the restart stopped it
#   stopped_before=<id>           one per task whose recorded endpoint was gone
#                                 and whose agent's busy generation had been
#                                 retired, as a deliberate stop
#                                 (bin/fm-control.sh exit) retires it: it was
#                                 already stopped before the restart
#   unarmed=<id>                  one per task whose recorded endpoint was gone
#                                 and whose agent never had a busy generation
#                                 (its adapter arms none), so which of the two
#                                 it was cannot be told
#   validation.<id>=<run>,<next>  for a no-mistakes ship task listed as task or
#                                 unarmed: the status of the branch's validation
#                                 run attributed to the worktree's code (or
#                                 none), and the branch_sync.next_action code
#                                 no-mistakes reports (or none); `unchecked`
#                                 when the bounded probe below did not reach it
# A listed task counts as still stopped while its metadata exists and its
# recorded endpoint is still gone (bin/fm-backend.sh fm_backend_target_exists).
# Only task= entries are what `revive --stopped-by-restart` brings back; a
# stopped_before or unarmed task comes back only by its own id. A remotely
# placed secondmate's endpoint lives on another host, so it is never listed.
#
# The validation probe runs only when the record is written, once per restart,
# under FM_RESTART_NM_TIMEOUT (default 5 seconds) per `no-mistakes axi status`
# call and FM_RESTART_NM_BUDGET (default 20 seconds) for the whole record, so a
# slow or absent daemon delays one session start by a bounded amount.
#
# Callers source bin/fm-backend.sh, bin/fm-busy-lib.sh, and
# bin/fm-nm-run-lib.sh first.

fm_restart_boot_id() {
  local id=
  if [ -n "${FM_BOOT_ID_FILE:-}" ]; then
    IFS= read -r id < "$FM_BOOT_ID_FILE" 2>/dev/null || true
  elif [ -r /proc/sys/kernel/random/boot_id ]; then
    IFS= read -r id < /proc/sys/kernel/random/boot_id 2>/dev/null || true
  elif command -v sysctl >/dev/null 2>&1; then
    id=$(sysctl -n kern.bootsessionuuid 2>/dev/null) || id=
  fi
  case "$id" in
    ''|*[!A-Za-z0-9-]*) return 1 ;;
  esac
  [ "${#id}" -le 64 ] || return 1
  printf '%s\n' "$id"
}

fm_restart_boot_path() {  # <state-dir>
  printf '%s/.boot-id' "$1"
}

fm_restart_record_path() {  # <state-dir>
  printf '%s/.restart-stopped' "$1"
}

fm_restart_record_get() {  # <state-dir> <key>
  local rec
  rec=$(fm_restart_record_path "$1")
  [ -f "$rec" ] || return 0
  grep "^$2=" "$rec" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# fm_restart_check: compare the kernel boot id with the recorded one. Sets
# FM_RESTART_BOOT (current, empty when unknown), FM_RESTART_PREVIOUS (recorded,
# possibly empty), and FM_RESTART_VERDICT:
#   unknown    this host offers no kernel boot id
#   first      nothing is recorded yet, so no claim either way
#   same       no restart since the recorded boot
#   restarted  the machine restarted since the recorded boot
FM_RESTART_BOOT=
FM_RESTART_PREVIOUS=
FM_RESTART_VERDICT=unknown
fm_restart_check() {  # <state-dir>
  local recorded
  FM_RESTART_PREVIOUS=
  FM_RESTART_BOOT=$(fm_restart_boot_id) || FM_RESTART_BOOT=
  recorded=$(fm_restart_boot_path "$1")
  if [ -f "$recorded" ]; then
    IFS= read -r FM_RESTART_PREVIOUS < "$recorded" 2>/dev/null || FM_RESTART_PREVIOUS=
  fi
  if [ -z "$FM_RESTART_BOOT" ]; then
    FM_RESTART_VERDICT=unknown
  elif [ -z "$FM_RESTART_PREVIOUS" ]; then
    FM_RESTART_VERDICT=first
  elif [ "$FM_RESTART_PREVIOUS" = "$FM_RESTART_BOOT" ]; then
    FM_RESTART_VERDICT=same
  else
    FM_RESTART_VERDICT=restarted
  fi
}

fm_restart_write_boot() {  # <state-dir> <boot-id>
  local path tmp
  path=$(fm_restart_boot_path "$1")
  tmp="$path.tmp.${BASHPID:-$$}"
  if printf '%s\n' "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$path" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# fm_restart_task_stopped: 0 when task <id> still has its metadata and its
# recorded endpoint is gone.
fm_restart_task_stopped() {  # <state-dir> <id>
  local meta="$1/$2.meta" window target backend
  case "$2" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -f "$meta" ] || return 1
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 1
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] || return 1
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  ! fm_backend_target_exists "$backend" "${target:-$window}" "fm-$2"
}

# fm_restart_validation_read: ask no-mistakes, bounded, about the validation
# run on a task worktree's branch. Sets FM_RESTART_NM_RUN (the status of the
# branch's run when it is attributed to the worktree's current code, or none),
# FM_RESTART_NM_NEXT (branch_sync.next_action.code, or none), and
# FM_RESTART_NM_COMMAND (the exact branch_sync.next_action.command, or empty
# when absent or not a plain command line). Returns 1 with all three empty when
# no-mistakes could not answer. bin/fm-control.sh revive reads the same answer
# to tell a revived worker what to run first.
FM_RESTART_NM_RUN=
FM_RESTART_NM_NEXT=
FM_RESTART_NM_COMMAND=
fm_restart_validation_read() {  # <worktree> <timeout-seconds>
  local wt=$1 timeout=$2 out branch run_branch
  FM_RESTART_NM_RUN=
  FM_RESTART_NM_NEXT=
  FM_RESTART_NM_COMMAND=
  [ -n "$wt" ] && [ -d "$wt" ] && command -v no-mistakes >/dev/null 2>&1 || return 1
  out=$(fm_nm_run_checked "$wt" "$timeout" axi status) || return 1
  FM_RESTART_NM_RUN=none
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_path_field "$out" run.branch)")
  if [ -n "$branch" ] && [ "$run_branch" = "$branch" ] \
     && fm_nm_status_run_matches_worktree "$wt" "$out"; then
    FM_RESTART_NM_RUN=$(fm_nm_strip_quotes "$(fm_nm_path_field "$out" run.status)")
  fi
  FM_RESTART_NM_NEXT=$(fm_nm_strip_quotes "$(fm_nm_path_field "$out" branch_sync.next_action.code)")
  FM_RESTART_NM_COMMAND=$(fm_nm_strip_quotes "$(fm_nm_path_field "$out" branch_sync.next_action.command)")
  case "$FM_RESTART_NM_RUN" in ''|*[!A-Za-z0-9_-]*) FM_RESTART_NM_RUN=none ;; esac
  case "$FM_RESTART_NM_NEXT" in ''|*[!A-Za-z0-9_-]*) FM_RESTART_NM_NEXT=none ;; esac
  case "$FM_RESTART_NM_COMMAND" in
    'no-mistakes '*) ;;
    *) FM_RESTART_NM_COMMAND= ;;
  esac
  case "$FM_RESTART_NM_COMMAND" in
    *[!A-Za-z0-9\ ._=/-]*) FM_RESTART_NM_COMMAND= ;;
  esac
  return 0
}

# fm_restart_validation_probe: "<run>,<next>" for a task's branch (see the
# record format above), or `unchecked` when no-mistakes could not answer.
fm_restart_validation_probe() {  # <meta-file> <timeout-seconds>
  if fm_restart_validation_read "$(fm_meta_get "$1" worktree)" "$2"; then
    printf '%s,%s' "$FM_RESTART_NM_RUN" "$FM_RESTART_NM_NEXT"
  else
    printf 'unchecked'
  fi
}

# fm_restart_record_write: list every task whose recorded endpoint is gone
# under the key its busy generation decides (see the format above), probe each
# no-mistakes ship task the restart may have stopped within the bounds above,
# and publish the record atomically. Locked callers only.
fm_restart_record_write() {  # <state-dir> <previous-boot> <boot>
  local state=$1 previous=$2 boot=$3 path tmp meta id key entry entries=() per budget start value
  path=$(fm_restart_record_path "$state")
  tmp="$path.tmp.${BASHPID:-$$}"
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_restart_task_stopped "$state" "$id" || continue
    if [ -z "$(fm_meta_get "$meta" busy_gen)" ]; then
      key=unarmed
    elif fm_busy_current_gen "$state" "$id" >/dev/null 2>&1; then
      key=task
    else
      key=stopped_before
    fi
    entries+=("$key=$id")
  done
  per=${FM_RESTART_NM_TIMEOUT:-5}
  budget=${FM_RESTART_NM_BUDGET:-20}
  start=$SECONDS
  {
    printf 'v1\n'
    printf 'detected=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'previous_boot=%s\n' "$previous"
    printf 'boot=%s\n' "$boot"
    for entry in "${entries[@]+"${entries[@]}"}"; do
      printf '%s\n' "$entry"
    done
    for entry in "${entries[@]+"${entries[@]}"}"; do
      case "$entry" in stopped_before=*) continue ;; esac
      id=${entry#*=}
      meta="$state/$id.meta"
      [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
      [ "$(fm_meta_get "$meta" mode)" = no-mistakes ] || continue
      if [ $((SECONDS - start)) -lt "$budget" ]; then
        value=$(fm_restart_validation_probe "$meta" "$per")
      else
        value=unchecked
      fi
      printf 'validation.%s=%s\n' "$id" "$value"
    done
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# fm_restart_stopped_tasks: the ids the record lists under <key> (task, the
# ones the restart stopped, by default) that are still stopped, one per line,
# in record order.
fm_restart_stopped_tasks() {  # <state-dir> [task|stopped_before|unarmed]
  local rec id key=${2:-task}
  rec=$(fm_restart_record_path "$1")
  [ -f "$rec" ] || return 0
  while IFS= read -r id; do
    fm_restart_task_stopped "$1" "$id" && printf '%s\n' "$id"
  done < <(sed -n "s/^$key=//p" "$rec")
  return 0
}

# fm_restart_observe: the session-start step. Compares boot ids and, only when
# <locked> is 1, records the current boot, writes the stopped list when the
# machine restarted, and retires a list in which no task the restart stopped,
# or may have stopped, is still stopped. A read-only session observes and
# writes nothing. Leaves fm_restart_check's variables set for the caller.
fm_restart_observe() {  # <state-dir> <locked>
  local state=$1 locked=$2
  fm_restart_check "$state"
  [ "$locked" = 1 ] || return 0
  case "$FM_RESTART_VERDICT" in
    first)
      fm_restart_write_boot "$state" "$FM_RESTART_BOOT" || true
      ;;
    restarted)
      fm_restart_record_write "$state" "$FM_RESTART_PREVIOUS" "$FM_RESTART_BOOT" || true
      fm_restart_write_boot "$state" "$FM_RESTART_BOOT" || true
      return 0
      ;;
  esac
  if [ -f "$(fm_restart_record_path "$state")" ] \
     && [ -z "$(fm_restart_stopped_tasks "$state")" ] \
     && [ -z "$(fm_restart_stopped_tasks "$state" unarmed)" ]; then
    rm -f "$(fm_restart_record_path "$state")" 2>/dev/null || true
  fi
  return 0
}
