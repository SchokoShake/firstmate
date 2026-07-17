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
# What IS owed on this path is the bookkeeping fm-teardown.sh does after a PR-based
# teardown, because nothing else will: it refuses outright without a meta, so on this
# path it has already run and will never run again. Both halves are done here.
#
# Closing the backlog item is the first. fm-teardown.sh is what normally prompts the
# "tasks-axi done" that moves a task to Done. Left open, the item keeps its captain hold
# and its PR in the structured link position, which is precisely what the board composes
# a Merge card from (bin/fm-logbook-compose.sh): resolving the card only clears the board
# until the next sync recomposes the identical card from the still-open backlog, and
# offers to re-merge work that already landed. Recording Done is what makes the
# captain's merge stick. Where the close cannot be performed - it failed, or the backlog is
# hand-maintained and there is no teardown left to prompt the hand-edit - it is REPORTED
# rather than skipped in silence, because an item left open silently is the one that
# recomposes that card. Best-effort means never failing a landed merge, never hiding.
#
# Refreshing the project clone is the second (fm-teardown.sh's own fm-fleet-sync.sh call).
# Left stale, the clone hands an out-of-date base to bin/fm-review-diff.sh and to every
# follow-on dispatch until the next session start syncs the fleet. The project name comes
# from the backlog item's own "(repo: <name>)" marker - the only record of it that
# outlives the meta - read BEFORE the close, because "tasks-axi done" moves the item and
# done_keep prunes it out of the file entirely once Done is full.
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
# Absolute, because the close below runs from the backlog's own home and a relative path
# would then resolve against that cwd instead of the caller's.
BACKLOG="$DATA/backlog.md"
case "$BACKLOG" in /*) ;; *) BACKLOG="$PWD/$BACKLOG" ;; esac
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

# backlog_item_of <id>: THIS home's durable record of <id>, as "<section>\t<project>", or
# nothing at all when the backlog does not carry the id as an item of its own.
#
# One scan, read ONCE and BEFORE the close - which is the only moment both answers exist,
# because closing is what moves the item and done_keep can then prune it out of the file
# entirely. Two callers ask two questions of the same line:
#
#   <section>  the "## " heading the item sits under, normalized as
#              bin/fm-logbook-compose.sh's backlog_parse normalizes it, and empty under a
#              heading that is not a task section (where compose reads no item either).
#              "done" is the one value that means nothing is owed: compose_item returns
#              early on a Done item, so no card can compose from one and there is nothing
#              left to close. This is the same question "code: NOT_FOUND" answers for the
#              tasks-axi path - asked of the file, so the manual backend can answer it too.
#   <project>  the bare project name from the item's "(repo: <name>)" marker, or empty
#              when the item records no project, or one that cannot address a clone.
#              Deliberately NOT gated on section: the clone refresh is owed for the merge
#              that just landed, whatever shape the heading around the item is in.
#
# The file is read directly rather than through "tasks-axi show", for the same reason
# bin/fm-logbook-compose.sh reads it directly: it then serves a backlog hand-maintained
# under config/backlog-backend=manual exactly as it serves the default backend, and needs
# no tool on PATH. ("tasks-axi show" would not help anyway - it reports the marker's raw
# value, trailing content and all.)
#
# The item forms and the marker shape are AGENTS.md section 10's contract, matched as
# bin/fm-logbook-compose.sh's backlog_parse matches them: the id is read from an item
# line's own id position, never from anywhere the id merely appears, so a note line or
# another task's prose citing this id cannot answer for its project. The marker value
# carries trailing content in the combined "(repo: <name>, since <date>)" form section 10
# documents for a hand-maintained backlog, rather than the tasks-axi backend's separate
# "(repo: <name>) (since <date>)", so the name ends at the first "," or ")".
#
# The name is then held to the same rule bin/fm-logbook-compose.sh's valid_project_name
# holds it to (no whitespace, "/", "\", or ".."). fm-fleet-sync.sh falls back to reading
# an unresolvable name as a path, so an item whose marker was hand-edited into something
# that is not a project name must resolve to nothing here rather than point a sanctioned
# write at a directory outside projects/.
backlog_item_of() {
  local id=$1 line rest item repo section=""
  [ -f "$BACKLOG" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      '## In flight'*) section=in_flight; continue ;;
      '## Queued'*)    section=queued;    continue ;;
      '## Done'*)      section='done';    continue ;;   # quoted to stay a literal, not the keyword
      '## '*)          section="";        continue ;;   # some other H2: not a task section
    esac
    item=""
    case "$line" in
      '- [ ] '*) rest=${line#'- [ ] '} ;;
      '- [x] '*) rest=${line#'- [x] '} ;;
      '- [X] '*) rest=${line#'- [X] '} ;;
      '- **'*)
        rest=${line#'- **'}
        case "$rest" in
          *'** - '*) item=${rest%%'** - '*} ;;
          *) continue ;;
        esac
        ;;
      *) continue ;;
    esac
    if [ -z "$item" ]; then
      case "$rest" in
        *' - '*) item=${rest%%' - '*} ;;
        *) continue ;;
      esac
    fi
    [ "$item" = "$id" ] || continue
    repo=""
    case "$line" in
      *' (repo: '*) repo=${line#*' (repo: '} ;;
    esac
    if [ -n "$repo" ]; then
      repo=${repo%%')'*}
      repo=${repo%%,*}
      repo=${repo#"${repo%%[![:space:]]*}"}
      repo=${repo%"${repo##*[![:space:]]}"}
      case "$repo" in
        ''|*[[:space:]]*|*/*|*\\*|*..*) repo="" ;;
      esac
    fi
    printf '%s\t%s' "$section" "$repo"
    return 0
  done < "$BACKLOG"
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

# The torn-down task's own bookkeeping, owed only where no teardown is left to do it (see
# the header). Strictly AFTER the merge, so a refused or failed merge never marks work
# Done that never landed, nor syncs a clone for a merge that never happened - "set -e"
# has already exited by here in that case.
if [ ! -f "$META" ]; then
  # Before the close, which is what moves (and can prune) the item both answers come from.
  BL_ITEM=$(backlog_item_of "$ID")
  BL_SECTION=${BL_ITEM%%$'\t'*}
  PROJECT=${BL_ITEM#*$'\t'}

  # BEST-EFFORT, exactly as fm-pr-check.sh's durable half is: closing the backlog must
  # never fail a merge that GitHub has already taken, and it cannot be undone by exiting
  # non-zero here. The shared probe owns "is the tasks-axi backend available", so it can
  # never drift from bootstrap's. --file pins the write to THIS home's backlog and nowhere
  # else (prime directive 1 holds: never a project).
  #
  # Best-effort is not silent, though: an item this path leaves open is the very one the
  # next sync recomposes the captain's just-answered Merge card from, offering to re-merge
  # landed work. Reporting it is what lets firstmate close the item by hand instead of
  # meeting that card again - so every way the close can fail to happen is reported, and
  # the two ways it can be rightly SKIPPED are the only silence:
  #
  #   - the item is not there to close. "code: NOT_FOUND" is the backlog answering that it
  #     does not carry this id at all (or has no such file); an empty or "done" section is
  #     the same answer read from the file, for a backend that is not asked. Either way no
  #     open item exists, so no card can compose from one, and warning would send firstmate
  #     hunting for an item that is not there.
  #   - the merge itself never happened. "set -e" has already exited above.
  #
  # Everything else is reported, including the case that reaches NEITHER branch's write:
  # tasks-axi absent, incompatible, or config/backlog-backend=manual leaving the backlog to
  # hand-editing (AGENTS.md section 10). The close is skipped there by design, but it is
  # still owed - and no teardown is left to prompt the hand-edit, because a missing meta is
  # what says teardown has already run.
  if fm_tasks_axi_backend_available "$CONFIG"; then
    # Run from the backlog's own home. --file pins WHICH backlog is written, but not the
    # .tasks.toml that governs HOW: tasks-axi reads it from its own cwd (0.2.2 reads that
    # directory only, without walking up), so a foreign cwd closes the item by the tool's
    # defaults - Done grows past the 10 section 10 caps it at, "do not hand-prune" leaves
    # nobody to trim it, and data/done-archive.md never receives the pruned entry. A cwd
    # that carries a .tasks.toml of its own is worse: it would prune by a stranger's rules,
    # into a stranger's archive. AGENTS.md section 2 sanctions invoking bin/ from any cwd,
    # so this cannot rest on the caller standing in the right one.
    # "done" is quoted only to keep it a literal argument rather than the shell keyword.
    if ! close_err=$({ cd "$DATA/.." && tasks-axi "done" "$ID" --pr "$URL" --file "$BACKLOG"; } 2>&1); then
      case "$close_err" in
        *'code: NOT_FOUND'*) ;;
        *) echo "warning: merged $URL but could not close backlog item $ID; close it by hand or the board will re-offer the merge: ${close_err//$'\n'/ }" >&2 ;;
      esac
    fi
  elif [ -n "$BL_SECTION" ] && [ "$BL_SECTION" != 'done' ]; then
    echo "warning: merged $URL but the tasks-axi backend is not in use, so backlog item $ID is still open; move it to Done by hand or the board will re-offer the merge" >&2
  fi

  # The clone refresh teardown would have done, best-effort on the same terms and for the
  # same reason: a landed merge must not fail on bookkeeping. A project the backlog never
  # named is simply nothing to sync - the next session start's fleet sweep still gets it.
  if [ -n "$PROJECT" ]; then
    "$SCRIPT_DIR/fm-fleet-sync.sh" "$PROJECT" || true
  fi
fi
