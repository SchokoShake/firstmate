#!/usr/bin/env bash
# Compose the current fleet attention set into a {projects, items} board body.
#
# Usage: fm-logbook-compose.sh
#        fm-logbook-compose.sh | fm-logbook-sync.sh -
#
# Derives the board's declarative-reconcile body from firstmate's OWN state -
# data/projects.md (the project registry), data/backlog.md (task one-liners),
# state/*.meta (the in-flight task set + any recorded PR), and state/*.status (the
# latest phase) - and prints one {projects, items} JSON object on stdout, ready to
# pipe into fm-logbook-sync.sh. This mechanizes the tedious hand-composition that
# made the session-start sync easy to skip. It is a truthful mechanical BASELINE:
# one card per in-flight task, classed decision > action > fyi, and every project
# from the registry flagged active when it carries a card. Rich, captain-facing
# titles/bodies/options remain firstmate's own composition on top, via
# fm-logbook-push.sh (an upsert keyed by id replaces the baseline card).
#
# Inert by default: a hard no-op (exit 0, no output) unless logbook is opted in via
# a truthy LOGBOOK_ENABLE (config/logbook.env), mirroring the other client scripts.
# Read-only: it only READS fleet state and never posts, so LOGBOOK_DRY_RUN needs no
# branch here - the would-be write lives in fm-logbook-sync.sh, which honors it.
# Every dynamic string (id, project, title, body, PR url) is injected into the JSON
# via jq --arg/--argjson, never interpolated into the jq program or a shell word, so
# fleet text can never break out of a shell word or the JSON structure.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-logbook-lib.sh
. "$SCRIPT_DIR/fm-logbook-lib.sh"

case "${1:-}" in
  --help|-h) echo "Compose the fleet attention set into a {projects, items} board body on stdout (pipe into fm-logbook-sync.sh). No-op unless opted in."; exit 0 ;;
esac

logbook_load_config
# Inert unless opted in: keeps this a safe no-op for non-adopters (compose | sync
# then reconciles nothing).
logbook_enabled || exit 0
command -v jq >/dev/null 2>&1 || { echo "fm-logbook-compose: jq not found" >&2; exit 1; }

PROJECTS_MD="$DATA/projects.md"
BACKLOG_MD="$DATA/backlog.md"

# --- helpers ---------------------------------------------------------------

# meta_get <meta-file> <key>: last KEY=value wins; prints nothing when absent. A
# tiny dependency-free reader so compose need not source the backend library.
meta_get() {
  local file=$1 key=$2 line
  [ -f "$file" ] || return 0
  line=$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  printf '%s' "${line#*=}"
}

# valid_project_name <name>: the tool's rule (no whitespace, / , \, control, or
# "..") - succeed when usable as an item's project or a project row's name.
valid_project_name() {
  local n=${1-}
  [ -n "$n" ] || return 1
  case "$n" in
    *[[:space:]]*|*/*|*\\*|*..*) return 1 ;;
  esac
  return 0
}

# backlog_oneliner <id>: the plain human one-liner for an in-flight task, with the
# trailing " (repo: ...)" bookkeeping stripped; empty when not found. Both the
# tasks-axi bold form and the checkbox form are matched by literal prefix (task ids
# are safe slugs, so no glob metacharacters leak into the pattern).
backlog_oneliner() {
  local id=$1 line rest
  [ -f "$BACKLOG_MD" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "- [ ] $id - "*) rest=${line#"- [ ] $id - "} ;;
      "- **$id** - "*) rest=${line#"- **$id** - "} ;;
      *) continue ;;
    esac
    rest=${rest%% (repo:*}
    printf '%s' "$rest"
    return 0
  done < <(sed -n '/^## In flight/,/^## /p' "$BACKLOG_MD" 2>/dev/null)
  return 0
}

# status_last <id>: the last non-empty line of the task's status log; empty when
# there is no status file yet.
status_last() {
  local id=$1
  local f="$STATE/$id.status"
  [ -f "$f" ] || return 0
  awk 'NF { last = $0 } END { if (last != "") printf "%s", last }' "$f" 2>/dev/null || true
}

# clip <string> <max>: truncate to <max> bytes so a runaway one-liner can never
# breach the tool's field limits (title <= 500, body <= 20000).
clip() {
  local s=$1 max=$2
  if [ "${#s}" -gt "$max" ]; then
    printf '%s' "${s:0:$max}"
  else
    printf '%s' "$s"
  fi
}

ITEMS_JSONL=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-compose-items.XXXXXX") || { echo "fm-logbook-compose: cannot create temp file" >&2; exit 1; }
REG_JSONL=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-compose-reg.XXXXXX") || { echo "fm-logbook-compose: cannot create temp file" >&2; exit 1; }
trap 'rm -f "$ITEMS_JSONL" "$REG_JSONL"' EXIT

# --- items: one card per in-flight task (persistent secondmates are not cards) --
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  logbook_valid_id "$id" || continue

  mkind=$(meta_get "$meta" kind)
  if [ "$mkind" = secondmate ]; then
    continue   # a persistent supervisor is infrastructure, not an attention item
  fi

  proj_path=$(meta_get "$meta" project)
  project=""
  if [ -n "$proj_path" ]; then
    project=$(basename "$proj_path")
    valid_project_name "$project" || project=""
  fi

  pr=$(meta_get "$meta" pr)
  last=$(status_last "$id")
  oneliner=$(backlog_oneliner "$id")

  # Classify by urgency: an open decision outranks a ready PR outranks plain
  # in-progress. This yields one card per in-flight task, with the PR-ready and
  # needs-decision ones raised to their proper kind.
  kind=fyi
  detail=""
  case "$last" in
    needs-decision:*)
      kind=decision
      detail=${last#needs-decision:}
      detail=${detail# }
      ;;
    *)
      if [ -n "$pr" ]; then kind=action; fi
      ;;
  esac

  # Plain, non-jargony baseline text (firstmate rewrites these richly on push); the
  # human title comes from the backlog one-liner, never the internal task id.
  case "$kind" in
    decision)
      title=${oneliner:-A decision is waiting}
      body=${detail:-This needs your decision.}
      options='[]'
      ;;
    action)
      title=${oneliner:-Work is ready for your review}
      if [ -n "$pr" ]; then
        body="Ready for your review.

PR: $pr"
      else
        body="Ready for your review."
      fi
      options='[{"label":"Merge","value":"merge"},{"label":"Hold","value":"hold"}]'
      ;;
    *)
      title=${oneliner:-Work in progress}
      if [ -n "$last" ]; then
        note=${last#*: }          # drop a leading "<verb>: " status prefix
        body=${note:-Work is underway.}
      else
        body="Work is underway."
      fi
      options='[]'
      ;;
  esac

  title=$(clip "$title" 500)
  body=$(clip "$body" 19000)

  jq -nc \
    --arg id "$id" \
    --arg project "$project" \
    --arg kind "$kind" \
    --arg title "$title" \
    --arg body "$body" \
    --argjson options "$options" \
    --arg pr "$pr" \
    '{
       id: $id,
       project: $project,
       kind: $kind,
       title: $title,
       body: $body,
       options: $options,
       source: ({ task: $id } + (if $pr == "" then {} else { pr: $pr } end))
     }' >> "$ITEMS_JSONL" || { echo "fm-logbook-compose: failed to compose item $id" >&2; exit 1; }
done

# --- projects: the registry, each flagged active when it carries a card ---------
if [ -f "$PROJECTS_MD" ]; then
  while IFS= read -r line; do
    case "$line" in
      '- '*) ;;
      *) continue ;;   # the header and blank lines are not registry entries
    esac
    entry=${line#- }
    name=${entry%% *}
    valid_project_name "$name" || continue
    rest=${entry#"$name"}
    rest=${rest# }
    mode=""
    case "$rest" in
      '['*)
        mode=${rest#\[}
        mode=${mode%%\]*}
        mode=${mode%% *}   # drop a trailing "+yolo" posture flag
        ;;
    esac
    jq -nc --arg name "$name" --arg mode "$mode" \
      '{ name: $name, repo: $name, mode: $mode }' >> "$REG_JSONL" \
      || { echo "fm-logbook-compose: failed to compose project $name" >&2; exit 1; }
  done < "$PROJECTS_MD"
fi

# --- combine: registry projects (+ any card-only project) with the active flag --
# Active = carries at least one card, matching the board's own semantics ("active
# projects feed the main needs-you column"). A card whose project is not in the
# registry (e.g. a firstmate-repo self-task) still gets a minimal active row so no
# card is orphaned.
jq -n \
  --slurpfile items "$ITEMS_JSONL" \
  --slurpfile reg "$REG_JSONL" \
  '
  ($items // []) as $its
  | ($reg // []) as $regs
  | ([ $its[].project | select(. != "") ] | unique) as $active
  | ($active | map({ key: ., value: true }) | from_entries) as $activeSet
  | ([ $regs[] | { name, repo, mode, active: ($activeSet[.name] // false) } ]) as $regProjects
  | ($regProjects | map(.name)) as $regNames
  | ([ $active[] | select([ $regNames[] == . ] | any | not) | { name: ., repo: ., mode: "", active: true } ]) as $extra
  | { projects: ($regProjects + $extra), items: $its }
  '
