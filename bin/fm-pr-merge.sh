#!/usr/bin/env bash
# Merge a task's PR, recording pr= and any available pr_head= into
# state/<id>.meta first via bin/fm-pr-check.sh, so bin/fm-teardown.sh's
# landed-check has a PR reference to verify a squash merge against.
#
# Why this exists: the normal trigger for running fm-pr-check.sh is the crew's
# `done: PR <url> checks green` line, which no-mistakes only emits once its CI
# step turns green. Repos that intentionally run no CI on PRs (CI only on
# pushes to the default branch) never emit that line, so a merge performed by
# hand-running `gh-axi pr merge` - the common shape of a yolo-authorized merge -
# can skip the recording step entirely. Teardown then has nothing to look up for
# a squash-merge-then-delete-branch flow and false-refuses provably landed work.
# This script makes recording part of the merge itself, so it cannot be skipped
# by omission. Use it for every PR merge (captain-requested or yolo-authorized),
# in place of calling `gh-axi pr merge` directly.
#
# NO META: merge from the PR URL alone. Recording exists to serve a LATER
# teardown, so it is owed only while there is still a crew to tear down - and
# both halves of that debt are settled here. This script used to refuse outright,
# for two reasons that only hold while the meta does: to stop merging a PR the
# fleet never recorded, and to leave teardown a reference to verify a squash
# merge against. No meta means teardown has already run: the task is gone, so
# there is no landed-check left to serve and nothing left to record it into. The
# durable backlog is the record now (AGENTS.md section 10), which is where the
# board reads the url the captain merges from (bin/fm-logbook-compose.sh) - so
# by the time that url reaches this script the PR is recorded, not unknown.
#
# fm-pr-check.sh is not the way to record it: it tolerates a missing meta, but it
# also arms state/<id>.check.sh, and only fm-teardown.sh removes that. Arming a
# merge poll for a task teardown has already swept would strand a check no teardown
# will ever clear again, reporting "merged" - of this very merge - on every watcher
# cycle, forever, to no one.
#
# What IS owed on this path is closing the backlog item, because nothing else will.
# fm-teardown.sh is what normally prompts the "tasks-axi done" that moves a task to
# Done, and it refuses outright without a meta - so on this path it has already run
# and will never run again. Left open, the item keeps its captain hold and its PR in
# the structured link position, which is precisely what the board composes a Merge
# card from (bin/fm-logbook-compose.sh): resolving the card only clears the board
# until the next sync recomposes the identical card from the still-open backlog, and
# offers to re-merge work that already landed. Recording Done is what makes the
# captain's merge stick.
#
# gh-axi pr merge expects a PR number and --repo <owner>/<repo>; it does not
# parse a full https://github.com/<owner>/<repo>/pull/<n> URL. This script
# parses the URL and invokes gh-axi in the form it accepts.
#
# Merge method: defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. An explicit
# caller method is never overridden.
# Extra args must not include --repo or -R because the repo is parsed from the
# PR URL.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID=${1:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]}
URL=${2:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]}
shift 2
[ "${1:-}" = "--" ] && shift

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
META="$STATE/$ID.meta"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

parse_pr_url() {
  local url=$1
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    PR_OWNER="${BASH_REMATCH[1]}"
    PR_REPO="${BASH_REMATCH[2]}"
    PR_NUMBER="${BASH_REMATCH[3]}"
    if [[ "$PR_OWNER" != *- ]]; then
      return 0
    fi
  fi
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: $url)" >&2
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge args must not override --repo parsed from PR URL (got: $arg)" >&2
        return 1
        ;;
    esac
  done
  return 0
}

parse_pr_url "$URL" || exit 1
reject_repo_overrides "$@" || exit 1

# The live crew's record, kept exactly as it was: record, verify, then merge. The
# verification stays hard - while a meta exists, a merge whose pr= did not land is
# the silent-omission failure this script was written to make impossible.
if [ -f "$META" ]; then
  "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
  grep -qxF "pr=$URL" "$META" || { echo "error: fm-pr-check did not record pr=$URL in $META; refusing to merge" >&2; exit 1; }
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" ${merge_args[@]+"${merge_args[@]}"} "$@"

# The torn-down task's own close, owed only where no teardown is left to prompt it (see
# the header). Strictly AFTER the merge, so a refused or failed merge never marks work
# Done that never landed - "set -e" has already exited by here in that case.
#
# BEST-EFFORT, exactly as fm-pr-check.sh's durable half is: closing the backlog must
# never fail a merge that GitHub has already taken, and it cannot be undone by exiting
# non-zero here. It is equally a no-op when tasks-axi is absent, incompatible, or
# config/backlog-backend=manual leaves the backlog to hand-editing, and when the id is
# one the backlog never carried. The shared probe owns "is the tasks-axi backend
# available", so it can never drift from bootstrap's. --file pins the write to THIS
# home's backlog and nowhere else (prime directive 1 holds: never a project).
if [ ! -f "$META" ] && fm_tasks_axi_backend_available "$CONFIG"; then
  # "done" is quoted only to keep it a literal argument rather than the shell keyword.
  tasks-axi "done" "$ID" --pr "$URL" --file "$DATA/backlog.md" >/dev/null 2>&1 || true
fi
