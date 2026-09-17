#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url>, the forge's
# exact pr_head=<sha> and pr_base=<branch> when available, atomically arm a
# static merge poll, and record the same URL on the backlog item through
# bin/fm-backlog-pr.sh.
# pr_base is the branch the PR merges into - the parent of this task's branch -
# and every rerun re-reads it, because a restack moves a PR's base.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
# A task that ships as a native GitHub stack is recorded with every PR, bottom
# to top. Nothing is recorded or armed unless bin/fm-stack-check.sh proves that
# GitHub reports exactly those PRs as one stack in that order; its proof line is
# printed. pr=, pr_head=, pr_base=, the merge poll, and the backlog link then
# follow the top PR, because a stack merges bottom-up, so the top PR merging
# means every layer has landed. A task whose brief carries the stacked-chain
# contract line from bin/fm-brief.sh --stack is refused with a single PR URL,
# unless that URL is the pr= already recorded, which the first record proved:
# that is how bin/fm-control.sh relaunch re-arms the poll.
# Usage: fm-pr-check.sh <task-id> <pr-url>
#        fm-pr-check.sh <task-id> <bottom-pr-url> [<pr-url>...] <top-pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
shift
if ! fm_pr_task_id_valid "$ID"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
for RAW_URL in "$@"; do
  if ! fm_pr_url_parse "$RAW_URL"; then
    echo "error: invalid PR check request" >&2
    exit 2
  fi
done
# The last URL parsed above is the one recorded: the only PR, or a stack's top.
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Prove a stack before any side effect, and never let a stacked-chain task be
# recorded as a lone PR.
if [ "$#" -gt 1 ]; then
  "$SCRIPT_DIR/fm-stack-check.sh" "$@" || {
    echo "error: not recorded: GitHub does not report these PRs as one native stack in this order" >&2
    exit 1
  }
elif grep -q '^Delivery contract: mode=[^ ]* stack=native$' "$DATA/$ID/brief.md" 2>/dev/null \
  && ! grep -qxF "pr=$URL" "$META"; then
  echo "error: $ID ships as a native stack; record every PR bottom to top so bin/fm-stack-check.sh can prove it" >&2
  exit 1
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

# Neutralize any pre-fix poll before recording or arming this task. The
# migration never executes legacy artifacts and holds watcher exclusion while
# it quarantines or rebuilds them.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head and pr_base are recorded only when the forge's CLI can supply them. gh
# exposes both as selectable fields; plain glab exposes them only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records neither. Every consumer already treats them as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded,
# and an absent pr_base leaves the fleet snapshot's field empty.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
PR_BASE=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
  # Asked separately from the head so one unreadable field never costs the
  # other, and so the head's exact query and its multiline guard stay untouched.
  if REMOTE_BASE=$(cd "$WT" && gh pr view "$URL" --json baseRefName -q .baseRefName 2>/dev/null) \
    && fm_pr_branch_valid "$REMOTE_BASE"; then
    PR_BASE=$REMOTE_BASE
  fi
fi

META_TMP=
META_LOCK=
META_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*|pr_base=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
[ -z "$PR_BASE" ] || printf 'pr_base=%s\n' "$PR_BASE" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}

# The backlog item's own PR link, recorded now rather than at completion, so the
# link exists from the moment the PR does. bin/fm-backlog-pr.sh owns the
# convention that keeps it in the `pr` field and out of the title; it reports its
# own skips. The metadata above is the durable record, and arming the merge poll
# is what this script must not lose, so a backlog write that cannot happen is
# noted and never fails the arming.
"$SCRIPT_DIR/fm-backlog-pr.sh" record "$ID" "$URL" \
  || echo "note: the backlog PR link was not recorded for $ID" >&2

printf 'armed: state/%s.check.sh\n' "$ID"
