#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# MERGE POLICY: some projects are the captain's to merge and no one else's
# (bin/fm-merge-policy-lib.sh owns the contract and the "+captain-merge" registry flag).
# This is the enforcement point, and it comes BEFORE the recording step: a refused merge
# must leave no trace of having been half-performed.
#
# It reads two independent signals, either of which refuses. Signal 1 is the project this
# task records, its meta's project=. Signal 2 is the PR URL itself, matched against the
# origin of every clone under projects/ - the fail-closed backstop, because it derives from
# the thing actually being merged rather than from bookkeeping a hand-typed or mistaken
# request may name wrongly.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-merge-policy-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-merge-policy-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

merge_policy_refuse() {
  local project=$1 why=$2
  echo "error: refusing to merge $URL: project \"$project\" is +captain-merge in data/projects.md" >&2
  echo "       ($why). The captain merges this project's PRs personally; firstmate must not." >&2
  exit 1
}

# The meta's project= is the PROJECT CLONE's path, recorded by bin/fm-spawn.sh beside the
# separate worktree= the crew actually works in; its last component is the projects/<name>
# the registry lists. "tail -n1" because last-key-wins is how every other reader of a meta
# reads it.
POLICY_PATH=$(grep -E '^project=' "$META" 2>/dev/null | tail -n1) || POLICY_PATH=""
POLICY_PATH=${POLICY_PATH#project=}
POLICY_PATH=${POLICY_PATH%/}
POLICY_PROJECT=""
[ -n "$POLICY_PATH" ] && POLICY_PROJECT=${POLICY_PATH##*/}
if [ -n "$POLICY_PROJECT" ] &&
  fm_merge_forbidden_project "$FM_ROOT" "$FM_HOME" "$POLICY_PROJECT"; then
  merge_policy_refuse "$POLICY_PROJECT" "the task records this project"
fi
if fm_merge_forbidden_url "$FM_ROOT" "$FM_HOME" "$PROJECTS" "$URL"; then
  merge_policy_refuse "$FM_MERGE_FORBIDDEN_PROJECT" "this PR's repo is that project's own origin"
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
