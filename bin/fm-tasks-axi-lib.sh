# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap,
# teardown, and secondmate backlog handoff.
# Usage: . bin/fm-tasks-axi-lib.sh
#
# Compatible means tasks-axi --version reports FM_TASKS_AXI_MIN or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs, and `tasks-axi list --help` offers held, hold_kind and
# hold_until as --fields extras, which is what lets bin/fm-captain-hold-lib.sh
# tell a lapsed captain hold from a dispatchable row. Without that last one the
# only sanctioned reader of dispatchable work has no way to withhold an
# unanswered captain question, so the build is refused rather than degraded.
# FM_TASKS_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
# The feature probes are a separate concern and stay as defense in depth for
# stripped or forked builds that advertise a current version without those flags.
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, but validated secondmate handoffs always use `tasks-axi mv`.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.
#
# This file is the single owner of FM_TASKS_AXI_MIN. bin/fm-bootstrap.sh turns a
# failing check into the operator-facing MISSING diagnostic. It is also the single
# owner of reading one field out of `tasks-axi show --full`, so two callers cannot
# decode the same encoded value differently.
#
# COMPATIBILITY VERDICT REUSE. fm_tasks_axi_compatible costs three tasks-axi
# subprocesses, and one session start needs the same verdict twice: once in
# bin/fm-session-start.sh's backlog listing and once in the bin/fm-bootstrap.sh
# child it runs. Two reuse layers collapse that to a single probe:
#   - Within a process the first probe's answer is memoised.
#   - Across ONE process hop, a parent that already holds the verdict passes it
#     in FM_TASKS_AXI_COMPATIBLE=0|1. Sourcing this file CONSUMES that variable
#     (it is unset from the environment and kept only as a private shell
#     variable), so the verdict reaches the child that needs it and never leaks
#     onward into a spawned agent's environment, where it could outlive a
#     tasks-axi upgrade. Any value other than exactly 0 or 1 is ignored and the
#     probe runs normally.
# Both layers are bounded by process lifetime, so a tasks-axi install or upgrade
# is picked up by the next process rather than being cached to disk.

FM_TASKS_AXI_MIN=0.2.4

FM_TASKS_AXI_COMPATIBLE_MEMO=${FM_TASKS_AXI_COMPATIBLE:-}
unset FM_TASKS_AXI_COMPATIBLE
case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
  0|1) ;;
  *) FM_TASKS_AXI_COMPATIBLE_MEMO= ;;
esac

fm_tasks_axi_version_parts() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_tasks_axi_compatible() {
  case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  if fm_tasks_axi_compatible_probe; then
    FM_TASKS_AXI_COMPATIBLE_MEMO=1
    return 0
  fi
  FM_TASKS_AXI_COMPATIBLE_MEMO=0
  return 1
}

fm_tasks_axi_compatible_probe() {
  fm_tasks_axi_meets_floor || return 1
  fm_tasks_axi_update_has_archive_body \
    && fm_tasks_axi_mv_has_multi_id \
    && fm_tasks_axi_list_has_hold_fields
}

fm_tasks_axi_meets_floor() {
  local parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(fm_tasks_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_TASKS_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

fm_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

# `tasks-axi show <id> --full` prints TOON: a value that needs it is wrapped in
# quotes, with `\\`, `\"`, `\n`, `\r` and `\t` escaped inside them. The value is
# returned decoded, so a comparison against the text that was written matches.
fm_tasks_axi_show_field() {  # <show-output> <field>
  local value
  value=$(printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1)
  case "$value" in
    '"'*'"')
      value=${value#\"}
      value=${value%\"}
      value=$(printf '%s' "$value" | awk '{
        out = ""
        n = length($0)
        i = 1
        while (i <= n) {
          c = substr($0, i, 1)
          if (c == "\\" && i < n) {
            i++
            c = substr($0, i, 1)
            if (c == "n") c = "\n"
            else if (c == "r") c = "\r"
            else if (c == "t") c = "\t"
          }
          out = out c
          i++
        }
        printf "%s", out
      }')
      ;;
  esac
  printf '%s' "$value"
}

# The --fields extras `tasks-axi list --help` advertises, read from its own
# parenthesised list rather than from the whole help text, because `held` also
# appears there as a --state value and would match a build that has the state but
# not the field.
fm_tasks_axi_list_has_hold_fields() {
  local output fields want
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi list --help 2>&1) || return 1
  fields=$(printf '%s\n' "$output" | sed -n 's/.*(extra:[[:space:]]*\([^)]*\)).*/\1/p' | head -1 | tr -d '[:space:]')
  [ -n "$fields" ] || return 1
  for want in held hold_kind hold_until; do
    case ",$fields," in
      *",$want,"*) ;;
      *) return 1 ;;
    esac
  done
}

# fm_tasks_axi_capability_reject
#   Prints a one-line reason naming the first capability the installed tasks-axi
#   is missing, and nothing when it has them all, so a caller that has already
#   seen fm_tasks_axi_compatible fail can say which capability failed instead of
#   only that some did. Runs the probes again, which only costs anything on the
#   failure path.
fm_tasks_axi_capability_reject() {
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf '%s\n' "tasks-axi is not installed"
  elif ! fm_tasks_axi_meets_floor; then
    printf '%s\n' "tasks-axi is older than $FM_TASKS_AXI_MIN; upgrade it"
  elif ! fm_tasks_axi_update_has_archive_body; then
    printf '%s\n' "tasks-axi does not expose 'update --archive-body'"
  elif ! fm_tasks_axi_mv_has_multi_id; then
    printf '%s\n' "tasks-axi does not expose a multi-id 'mv'"
  elif ! fm_tasks_axi_list_has_hold_fields; then
    printf '%s\n' "tasks-axi does not offer held, hold_kind and hold_until as list fields, so a lapsed captain hold cannot be told apart from dispatchable work; upgrade it"
  fi
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}
