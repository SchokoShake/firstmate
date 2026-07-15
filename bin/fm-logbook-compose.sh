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
# Sub-projects (a DISPLAY-only grouping level below a project) let a monorepo's
# integration-branch features group on the board. They are firstmate-declared per
# project in data/projects.md as ORDERED { key, name, branch } triples, one per
# non-dash "sub" continuation line indented under the project's registry line:
#     sub placement-tool | Placement Tool | feat/placement-tool
# The leading token is "sub", never "-", so the "$1==\"-\"" registry parsers
# (fm-project-mode.sh, fm-home-seed.sh) skip these lines and a project with none
# composes exactly as before. This script reads them into each project's ordered
# "subprojects" array, and tags each item with an optional "subproject" by mapping
# the item's "base_branch=" meta field (the branch its PR targets, recorded by
# firstmate at dispatch) to the parent project's matching sub-project key; an item
# with no base_branch or no match stays ungrouped. docs/configuration.md ("Logbook"
# -> "Sub-projects") owns the full declaration format, limits, validation, and the
# base_branch recording path.
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

# trim <string>: strip leading and trailing ASCII whitespace. Used to normalize the
# " | "-split sub-project fields so stray spacing in a declaration never leaks into a
# key, display name, or branch.
trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

ITEMS_JSONL=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-compose-items.XXXXXX") || { echo "fm-logbook-compose: cannot create temp file" >&2; exit 1; }
REG_JSONL=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-compose-reg.XXXXXX") || { echo "fm-logbook-compose: cannot create temp file" >&2; exit 1; }
SUB_JSONL=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-compose-sub.XXXXXX") || { echo "fm-logbook-compose: cannot create temp file" >&2; exit 1; }
trap 'rm -f "$ITEMS_JSONL" "$REG_JSONL" "$SUB_JSONL"' EXIT

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
  # The item's sub-project is resolved from its base/integration branch (the branch
  # its PR targets) against the parent project's declarations, in the combine step
  # below; carried as the internal _base_branch helper and stripped before output.
  base_branch=$(meta_get "$meta" base_branch)
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
    --arg base_branch "$base_branch" \
    '{
       id: $id,
       project: $project,
       kind: $kind,
       title: $title,
       body: $body,
       options: $options,
       source: ({ task: $id } + (if $pr == "" then {} else { pr: $pr } end)),
       _base_branch: $base_branch
     }' >> "$ITEMS_JSONL" || { echo "fm-logbook-compose: failed to compose item $id" >&2; exit 1; }
done

# --- projects: the registry, each flagged active when it carries a card ---------
# Each project line composes a { name, repo, mode } row; the non-dash "sub"
# continuation lines beneath it compose that project's ordered sub-project records
# (attached to the row in the combine step). cur_project tracks which project the
# sub lines belong to, and resets to "" under an unusable project so orphan sub
# lines are dropped rather than misattributed.
if [ -f "$PROJECTS_MD" ]; then
  cur_project=""
  while IFS= read -r line; do
    case "$line" in
      '- '*)
        entry=${line#- }
        name=${entry%% *}
        if ! valid_project_name "$name"; then
          cur_project=""
          continue
        fi
        cur_project="$name"
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
        ;;
      *)
        # A non-dash "sub <key> | <name> | <branch>" continuation line declares a
        # sub-project of the current project (leading indentation is cosmetic). The
        # leading token is never "-", so the "$1==\"-\"" registry parsers skip it.
        trimmed=$(trim "$line")
        case "$trimmed" in
          'sub '*) ;;
          *) continue ;;   # not a sub declaration (header, blank, or free-form note)
        esac
        [ -n "$cur_project" ] || continue
        content=$(trim "${trimmed#sub }")
        # Require the three " | "-separated fields; drop a malformed line loudly.
        case "$content" in
          *' | '*' | '*) ;;
          *) echo "fm-logbook-compose: skipping malformed sub-project line under $cur_project: $trimmed" >&2; continue ;;
        esac
        sp_key=$(trim "${content%% | *}")     # first field
        sp_branch=$(trim "${content##* | }")  # last field
        sp_name=${content#*" | "}; sp_name=$(trim "${sp_name%" | "*}")   # middle field(s)
        # Only a valid, declared key can ever be emitted, so an item can never map to
        # a bad key: the key must be the tool's safe slug and name/branch non-empty.
        if ! logbook_valid_id "$sp_key"; then
          echo "fm-logbook-compose: skipping sub-project with invalid key \"$sp_key\" under $cur_project" >&2
          continue
        fi
        if [ -z "$sp_name" ] || [ -z "$sp_branch" ]; then
          echo "fm-logbook-compose: skipping sub-project \"$sp_key\" under $cur_project (empty name or branch)" >&2
          continue
        fi
        sp_name=$(clip "$sp_name" 200)
        jq -nc --arg project "$cur_project" --arg key "$sp_key" --arg name "$sp_name" --arg branch "$sp_branch" \
          '{ project: $project, key: $key, name: $name, branch: $branch }' >> "$SUB_JSONL" \
          || { echo "fm-logbook-compose: failed to compose sub-project $sp_key under $cur_project" >&2; exit 1; }
        ;;
    esac
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
  --slurpfile subs "$SUB_JSONL" \
  '
  ($items // []) as $its0
  | ($reg // []) as $regs
  | ($subs // []) as $sps
  # Tag each item by base/integration branch: map its _base_branch to the parent
  # project s matching sub-project key, then strip the helper. No base_branch, or no
  # match, leaves the item ungrouped (no subproject key at all).
  | ($its0 | map(
      ._base_branch as $bb
      | del(._base_branch)
      | . as $it
      | if ($bb // "") == "" then $it
        else
          ( $sps | map(select(.project == $it.project and .branch == $bb)) ) as $m
          | if ($m | length) > 0 then $it + { subproject: $m[0].key } else $it end
        end
    )) as $its
  | ([ $its[].project | select(. != "") ] | unique) as $active
  | ($active | map({ key: ., value: true }) | from_entries) as $activeSet
  # Attach each project s ordered (declaration-order) sub-project array, capped at the
  # tool s 100-per-project limit; a project with none emits an empty array.
  | ([ $regs[] | . as $p
       | { name: $p.name, repo: $p.repo, mode: $p.mode,
           active: ($activeSet[$p.name] // false),
           subprojects: ([ $sps[] | select(.project == $p.name) | { key, name, branch } ] | .[0:100]) } ]) as $regProjects
  | ($regProjects | map(.name)) as $regNames
  | ([ $active[] | select([ $regNames[] == . ] | any | not)
       | { name: ., repo: ., mode: "", active: true, subprojects: [] } ]) as $extra
  | { projects: ($regProjects + $extra), items: $its }
  '
