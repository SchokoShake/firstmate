#!/usr/bin/env bash
# fm-backlog-pr.sh - the single firstmate path that writes a task's PR URL into
# the backlog item, and the only supported way to change a title without losing
# that link.
#
# THE CONVENTION. A task's PR URL belongs to the backlog item's `pr` field and
# never to its title text. tasks-axi's markdown backend renders that field
# inside the item line and re-derives it by scanning the line for a pull-request
# URL, so a URL typed into a title and a URL recorded with `--pr` are the same
# bytes on disk and `tasks-axi show` reports both inside `title`. The
# consequence is one-way and silent: a later `tasks-axi update <id> --title
# <text>` replaces the whole title, drops the URL with it, and leaves the item
# with no `pr` link at all. Recording through `--pr` while writing a title that
# carries no URL keeps the link tasks-axi's to place, which is what lets
# `retitle` carry it across a title change in the same call. A scout's report
# link (`--report data/<id>/report.md`) lives in the same line by the same
# mechanism, so every write here carries that one too.
#
# Usage:
#   fm-backlog-pr.sh record <task-id> <pr-url>
#   fm-backlog-pr.sh retitle <task-id> <new-title>
#   fm-backlog-pr.sh repair <task-id>
#
# `record` makes <pr-url> the item's only PR link. It is idempotent, it replaces
# a different or duplicated link rather than appending a second one, and it
# never leaves a URL in the title. bin/fm-pr-check.sh calls it, so an ordinary
# ship task gets its backlog link when the PR is first recorded rather than at
# completion.
#
# `retitle` sets a new title and re-asserts every link the item carries, its
# recorded PR link and its report link, in the same tasks-axi call, so they
# survive. Use it instead of a bare `tasks-axi update <id> --title ...` on any
# task that has, or may later have, a PR or a report. A URL in <new-title> is
# taken as the intended link, stripped out of the title, and recorded through
# the field.
#
# `repair` restores a link that was already lost, from the `pr=` line in this
# home's task metadata - firstmate's own durable record, written by
# bin/fm-pr-check.sh before the backlog is ever touched. It also normalizes an
# item that accumulated more than one PR URL down to that recorded one.
#
# Every subcommand exits 0 without touching the backlog when this home has opted
# out of tasks-axi backlog mutations, when tasks-axi is absent or incompatible,
# or when the task is not an item in this home's backlog, and says which on
# stdout as a `skipped:` line. Those are ordinary conditions for a task that
# firstmate tracks outside the backlog, not failures.
#
# GITLAB. tasks-axi's `--pr` accepts only an http(s) `/pull/<number>` URL, so a
# GitLab merge request cannot be stored in the field at all. Recording one is
# reported as skipped rather than written into the title, which would recreate
# exactly the loss this script exists to prevent.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-backlog-pr: %s\n' "$*" >&2
  exit 1
}

# A condition under which there is deliberately nothing to write. Reported, not
# silent, and never an error: it exits the script from the top-level command
# body, so it is never called from inside a command substitution.
skip() {  # <reason>
  printf 'skipped: %s\n' "$1"
  exit 0
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

# The pull-request URL shape tasks-axi itself recognizes inside an item line.
PR_URL_RE='https?://[^[:space:]]*/pull/[0-9][0-9]*'

# Drop every pull-request URL, and the item's report path when it has one, from
# a title and normalize the whitespace that removing them leaves behind, so the
# rewritten title is the human sentence alone.
strip_links() {  # <title> <report-path>
  local title=$1
  [ -z "$2" ] || title=${title//"$2"/}
  printf '%s' "$title" |
    sed -E -e "s#$PR_URL_RE##g" -e 's/[[:space:]]+/ /g' -e 's/^ //' -e 's/ $//'
}

show_field() {  # <show-output> <field>
  printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1
}

# tasks-axi quotes a field that needs it and backslash-escapes inside the quotes.
# Titles are single-line, so unescaping every `\<char>` to `<char>` covers the
# `\\` and `\"` it can emit.
unquoted_field() {  # <raw-field-value>
  local raw=$1
  case "$raw" in
    '"'*'"')
      raw=${raw#\"}
      raw=${raw%\"}
      printf '%s' "$raw" | awk '{
        out = ""
        i = 1
        n = length($0)
        while (i <= n) {
          c = substr($0, i, 1)
          if (c == "\\" && i < n) {
            i++
            out = out substr($0, i, 1)
          } else {
            out = out c
          }
          i++
        }
        printf "%s", out
      }'
      ;;
    *) printf '%s' "$raw" ;;
  esac
}

# The item's recorded links of one kind (`pr` or `report`), newline separated,
# in the order tasks-axi reports them. Empty when the item carries none.
item_links() {  # <show-output> <kind>
  local links
  links=$(unquoted_field "$(show_field "$1" links)")
  [ -n "$links" ] && [ "$links" != none ] || return 0
  printf '%s\n' "$links" | tr ',' '\n' | sed -n "s/^$2://p"
}

# The URL firstmate itself recorded for the task, from the task metadata
# bin/fm-pr-check.sh owns. Empty when there is none or it does not validate.
meta_pr_url() {  # <task-id>
  local meta="$STATE/$1.meta" value
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  value=$(grep '^pr=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$value" ] || return 0
  fm_pr_url_parse "$value" || return 0
  printf '%s' "$FM_PR_URL"
}

require_backlog_backend() {
  fm_tasks_axi_backend_available "$CONFIG" \
    || skip "this home does not use tasks-axi for routine backlog mutations"
}

# Loads the item's `tasks-axi show <id> --full` output into ITEM_SHOW, or skips
# when the task is not an item in this home's backlog. Assigning through a global
# keeps `skip` out of a command substitution, where exiting would only leave the
# subshell and the caller would carry on with the skip message as data.
ITEM_SHOW=
load_item() {  # <task-id>
  # Validated before it reaches tasks-axi as an argument. The shared path-safe
  # class allows "-" inside an id, so a leading one is refused separately: an id
  # like "--full" would otherwise be re-read as a flag by tasks-axi itself.
  case "$1" in -*) fail "not a task id: $1" ;; esac
  fm_pr_task_id_valid "$1" || fail "not a task id: $1"
  ITEM_SHOW=$(tasks_axi show "$1" --full 2>/dev/null) \
    || skip "$1 is not an item in this home's backlog"
  [ -n "$ITEM_SHOW" ] || skip "$1 is not an item in this home's backlog"
}

# tasks-axi stores only a GitHub pull-request URL in the field. Sets FM_PR_URL
# to the canonical form when true.
storable_url() {  # <raw-url>
  fm_pr_url_parse "$1" && [ "$FM_PR_PROVIDER" = github ]
}

# Anything else is reported rather than written somewhere it would be lost.
require_storable_url() {  # <raw-url>
  fm_pr_url_parse "$1" || fail "not a pull request or merge request URL: $1"
  storable_url "$1" \
    || skip "tasks-axi stores only a GitHub pull request URL in the pr field, not $FM_PR_URL"
}

# The one write. <title> is always a title with no link text in it, and every
# link reaches the item through its own flag, in a single call so no
# intermediate state has one missing. Either link may be empty.
write_item() {  # <task-id> <title> <pr-url> <report-path>
  local -a args
  args=(update "$1" --title "$2")
  [ -z "$3" ] || args+=(--pr "$3")
  [ -z "$4" ] || args+=(--report "$4")
  tasks_axi "${args[@]}" >/dev/null || fail "could not update $1 in the backlog"
}

# The PR link to carry for an item when the caller named none, in CARRIED_PR_URL
# (empty when there is nothing to carry). Firstmate's own durable record wins
# when tasks-axi can store it; otherwise the newest of the item's own links, so
# an item that accumulated several settles on the current PR rather than the
# stale one. An item link this script cannot parse is refused rather than
# silently dropped: a link it cannot reason about is not one it may lose.
CARRIED_PR_URL=
load_carried_pr_url() {  # <task-id>
  local url
  CARRIED_PR_URL=
  url=$(meta_pr_url "$1")
  if [ -n "$url" ] && storable_url "$url"; then
    CARRIED_PR_URL=$FM_PR_URL
    return 0
  fi
  url=$(item_links "$ITEM_SHOW" pr | tail -1)
  [ -n "$url" ] || return 0
  storable_url "$url" || fail "not a GitHub pull request URL, so it cannot be carried in the pr field: $url"
  CARRIED_PR_URL=$FM_PR_URL
}

cmd_record() {  # <task-id> <pr-url>
  local id=$1 url title clean links report
  fm_pr_url_parse "$2" || fail "not a pull request or merge request URL: $2"
  require_backlog_backend
  load_item "$id"
  require_storable_url "$2"
  url=$FM_PR_URL
  links=$(item_links "$ITEM_SHOW" pr | paste -sd, -)
  report=$(item_links "$ITEM_SHOW" report | head -1)
  title=$(unquoted_field "$(show_field "$ITEM_SHOW" title)")
  clean=$(strip_links "$title" "$report")
  if [ "$links" = "$url" ]; then
    printf 'unchanged: %s pr=%s\n' "$id" "$url"
    return 0
  fi
  [ -n "$clean" ] || fail "$id has no title left once its links are removed"
  write_item "$id" "$clean" "$url" "$report"
  printf 'recorded: %s pr=%s\n' "$id" "$url"
}

cmd_retitle() {  # <task-id> <new-title>
  local id=$1 title=$2 clean pasted url report carried=
  case "$title" in
    ''|*$'\n'*|*$'\r'*) fail "a title must be one non-empty line" ;;
  esac
  require_backlog_backend
  load_item "$id"
  report=$(item_links "$ITEM_SHOW" report | head -1)
  clean=$(strip_links "$title" "$report")
  [ -n "$clean" ] || fail "the new title has no text left once its links are removed"
  # A URL the caller wrote into the new title is the link they meant to keep, so
  # it wins outright. Otherwise the item carries whatever `repair` would settle
  # on, and a record tasks-axi cannot store (a merge request) with no item link
  # behind it simply means there is no PR link to carry: the title still
  # changes, with the item's other links intact.
  pasted=$(printf '%s' "$title" | grep -Eo "$PR_URL_RE" | head -1)
  if [ -n "$pasted" ]; then
    storable_url "$pasted" || fail "not a GitHub pull request URL, so it cannot be kept in the pr field: $pasted"
    url=$FM_PR_URL
  else
    load_carried_pr_url "$id"
    url=$CARRIED_PR_URL
  fi
  [ -z "$url" ] || carried="pr=$url"
  [ -z "$report" ] || carried="${carried:+$carried }report=$report"
  write_item "$id" "$clean" "$url" "$report"
  printf 'retitled: %s %s\n' "$id" "${carried:-(no links)}"
}

cmd_repair() {  # <task-id>
  local id=$1 url
  require_backlog_backend
  load_item "$id"
  load_carried_pr_url "$id"
  url=$CARRIED_PR_URL
  [ -n "$url" ] || url=$(meta_pr_url "$id")
  [ -n "$url" ] || skip "no PR URL is recorded for $id"
  cmd_record "$id" "$url"
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
COMMAND=$1
shift
case "$COMMAND" in
  record) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; cmd_record "$1" "$2" ;;
  retitle) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; cmd_retitle "$1" "$2" ;;
  repair) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_repair "$1" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
