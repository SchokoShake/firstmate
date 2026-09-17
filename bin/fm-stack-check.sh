#!/usr/bin/env bash
# Prove that pull requests form ONE native GitHub stack, in the given order.
# A native stack is a server-side object that GitHub creates through `gh stack
# link`, `gh stack submit`, or its stacks API. Pull requests whose bases merely
# point at each other are a chain, not a stack, and this check refuses them.
# Nothing may be called a stack unless this check passes against it.
#
# Usage: fm-stack-check.sh <bottom-pr-url> [<pr-url>...] <top-pr-url>
#
# Each PR is read from GitHub's REST pull request resource at API version
# 2026-03-10, whose `stack` field carries the stack's number, the PR's position
# in it, the stack's size, and the stack's base branch. The check passes only
# when every given PR:
#   - reports a stack, and the same stack number as every other given PR;
#   - sits at the position its argument order names, counting the bottom as 1;
#   - reports a stack size equal to the number of PRs given, so no layer is
#     missing from, or extra to, the command line;
#   - targets the right base: the bottom targets the stack's base branch, and
#     every other PR targets the head branch of the PR below it. Once the PR
#     below has merged, GitHub retargets the PRs above onto the stack's base
#     branch, so that branch is accepted too above a merged PR.
# At least two PRs are required, because a GitHub stack holds two or more.
# Every URL must be a github.com pull request URL, all in one repository.
#
# Exit 0 prints one proof line on stdout, fit to quote in a done line:
#   stack ok: #<number> base=<branch> size=<n>: <bottom-url> ... <top-url>
# Exit 1 means not proven: stderr carries one `error:` line per problem, each
# naming the PR and what GitHub reports for it, then a closing summary line.
# Exit 2 is a usage error, reported before any GitHub call.
# Read-only; requires gh authenticated for the repository.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

API_VERSION=2026-03-10

if [ "$#" -lt 2 ]; then
  echo "error: a stack needs at least two PR URLs, given bottom to top" >&2
  exit 2
fi

REPO_PATH=
for url in "$@"; do
  if ! fm_pr_url_parse "$url" || [ "$FM_PR_PROVIDER" != github ]; then
    echo "error: not a github.com pull request URL: $url" >&2
    exit 2
  fi
  if [ -z "$REPO_PATH" ]; then
    REPO_PATH=$FM_PR_PATH
  elif [ "$FM_PR_PATH" != "$REPO_PATH" ]; then
    echo "error: every PR in a stack must be in one repository; $url is not in $REPO_PATH" >&2
    exit 2
  fi
done

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh is required to read stack membership from GitHub" >&2
  exit 1
fi

SIZE=$#
# One line per PR: stack number, position, size, stack base branch, the PR's
# own base branch, its head branch, and whether it merged. An absent stack
# renders its four fields empty. Fields are joined by the ASCII unit separator,
# which git forbids in branch names; a tab would not do, because bash collapses
# runs of whitespace separators and an empty field would shift the rest.
FIELD_SEP=$'\x1f'
FIELDS='[(.stack.number // ""), (.stack.position // ""), (.stack.size // ""), (.stack.base.ref // ""), (.base.ref // ""), (.head.ref // ""), (.merged // false)] | map(tostring) | join("")'

problems=0
problem() {
  printf 'error: %s\n' "$1" >&2
  problems=$((problems + 1))
}

is_count() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

ref_number=
ref_url=
stack_base=
prev_url=
prev_head=
prev_merged=
position=0
for url in "$@"; do
  position=$((position + 1))
  fm_pr_url_parse "$url"
  label="$url (given position $position of $SIZE)"
  if ! line=$(gh api -H "X-GitHub-Api-Version: $API_VERSION" \
      "repos/$FM_PR_OWNER/$FM_PR_REPO/pulls/$FM_PR_NUMBER" --jq "$FIELDS" 2>/dev/null) \
      || [ -z "$line" ]; then
    problem "$label: could not read the PR from GitHub"
    prev_url=$url
    prev_head=
    prev_merged=
    continue
  fi
  IFS=$FIELD_SEP read -r s_number s_position s_size s_base base head merged <<EOF
$line
EOF

  if [ -z "$s_number" ]; then
    problem "$label: GitHub reports no stack for this PR"
  elif ! is_count "$s_number" || ! is_count "$s_position" || ! is_count "$s_size"; then
    problem "$label: GitHub returned an unreadable stack record"
  else
    if [ -z "$ref_number" ]; then
      ref_number=$s_number
      ref_url=$url
      stack_base=$s_base
    elif [ "$s_number" != "$ref_number" ]; then
      problem "$label: in stack #$s_number, but $ref_url is in stack #$ref_number"
    fi
    [ "$s_position" = "$position" ] \
      || problem "$label: GitHub places it at position $s_position of stack #$s_number"
    [ "$s_size" = "$SIZE" ] \
      || problem "$label: stack #$s_number holds $s_size PRs, but $SIZE were given"
  fi

  if [ "$position" = 1 ]; then
    if [ -n "$s_number" ] && [ "$base" != "$s_base" ]; then
      problem "$label: targets '$base', not the stack base '$s_base'"
    fi
  elif [ -n "$prev_head" ] && [ "$base" != "$prev_head" ]; then
    if [ "$prev_merged" = true ] && [ -n "$s_base" ] && [ "$base" = "$s_base" ]; then
      :
    else
      problem "$label: targets '$base', not '$prev_head', the branch of $prev_url below it"
    fi
  fi

  prev_url=$url
  prev_head=$head
  prev_merged=$merged
done

if [ "$problems" -gt 0 ]; then
  echo "not proven: GitHub does not report these $SIZE PRs as one native stack in this order" >&2
  exit 1
fi

printf 'stack ok: #%s base=%s size=%s: %s\n' "$ref_number" "$stack_base" "$SIZE" "$*"
