#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's pr_head=<sha> to
# state/<id>.meta when available, records the PR on the durable backlog, then arms the
# watcher's merge poll by writing state/<id>.check.sh, which prints one line iff the PR
# is merged (the watcher's check contract: output = wake firstmate, silence = keep
# sleeping).
# Usage: fm-pr-check.sh <task-id> <pr-url>
#
# Both records are needed because they outlive each other by design. state/<id>.meta is
# the LIVE crew's record and fm-teardown.sh deletes it with the crew - but the
# documented end-state for review-ready work is exactly that: the crew finishes and is
# torn down, and the task sits on a captain hold awaiting review (AGENTS.md section 7).
# So meta's pr= is gone by the time the captain is the one who needs it. The backlog is
# firstmate's durable record (AGENTS.md section 10) and survives teardown, which is
# where the logbook board reads a torn-down task's PR from (bin/fm-logbook-compose.sh).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BACKLOG="$DATA/backlog.md"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    if command -v gh >/dev/null 2>&1; then
      if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
        PR_HEAD=$REMOTE_HEAD
      fi
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

# The durable half. Explicitly --file'd at this home's own backlog so the record lands
# under FM_HOME and nowhere else (prime directive 1 holds: this is firstmate's backlog,
# never a project). "update --pr" appends the url to the item's title text, which is the
# structured link position compose harvests, and re-recording the same url is a no-op.
#
# BEST-EFFORT: arming the merge poll is this script's job and must still work when
# tasks-axi is absent, incompatible, or config/backlog-backend=manual leaves the backlog
# to hand-editing - as must an id the backlog has not caught up to yet. The shared probe
# owns "is the tasks-axi backend available", so it can never drift from bootstrap's.
#
# Best-effort is not silent, though, and the two are easy to conflate: not failing the arm
# is the point, hiding WHY the record is missing never was. The loss surfaces nowhere near
# here and long after - while the crew lives, compose reads pr= from the meta and the card
# looks right; once fm-teardown.sh sweeps that meta, this record's absence is what silently
# downgrades the card to no PR link and no Merge, which is the exact durability this
# script's second half exists to provide. So every way the record fails to happen is
# reported - including the one that reaches no write at all, where the backend is not in
# use and the record is skipped by design but still owed, with nothing else left to write
# it: fm-teardown.sh's reminder prompts the Done move, never this.
#
# What is NOT owed is a report about an item that carries no card to lose - and there is
# no such item in two shapes, which are one question asked of two sources. "code:
# NOT_FOUND" is the backend's own answer that it does not carry this id (the window
# between fm-spawn and the backlog write, which the header tolerates); an empty or "done"
# section is that same answer read from the FILE, which is the only way to ask a backend
# that is never consulted. Warning on either would send firstmate hand-editing an item
# that is already closed, or one that is not there at all. Everything else is a real loss.
#
# An item that IS open is reported to whoever asked, because this script cannot tell why:
# bin/fm-pr-merge.sh re-runs it for every merge it makes, where the record is not really
# owed (teardown moves that item to Done, and compose_item returns early on one), but an
# in-flight item looks identical at the PR-ready call, where the record is exactly what
# the board will need. Erring toward the report keeps the durable half's own failure the
# loud one; a spurious hand-record on an item about to close costs nothing but the read.
if fm_tasks_axi_backend_available "$CONFIG"; then
  if ! record_err=$(tasks-axi update "$ID" --pr "$URL" --file "$BACKLOG" 2>&1); then
    case "$record_err" in
      *'code: NOT_FOUND'*) ;;
      *) echo "warning: could not record $URL on backlog item $ID; the board will lose this PR once the crew is torn down: ${record_err//$'\n'/ }" >&2 ;;
    esac
  fi
else
  BL_SECTION=$(fm_backlog_item_of "$BACKLOG" "$ID")
  BL_SECTION=${BL_SECTION%%$'\t'*}
  if [ -n "$BL_SECTION" ] && [ "$BL_SECTION" != 'done' ]; then
    echo "warning: the tasks-axi backend is not in use, so $URL is not recorded on backlog item $ID; add it to the item line by hand or the board will lose this PR once the crew is torn down" >&2
  fi
fi

cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
echo "armed: state/$ID.check.sh polls $URL"
