# shellcheck shell=bash
# fm-merge-policy-lib.sh - the one owner of "may firstmate merge this project's work?"
# Usage: . bin/fm-merge-policy-lib.sh
#
# Some projects are the captain's to merge and no one else's. The zeigmal repos are the
# standing case: they open PRs as drafts, the captain converts them to ready after their
# own review, and the captain merges them personally. firstmate must never perform that
# merge - not on a board tap, not under yolo, not on its own judgment.
#
# That posture is declared per project as a "+captain-merge" flag on the data/projects.md
# registry line, which bin/fm-project-mode.sh parses (and whose header says why it needs a
# flag of its own rather than a reading of "mode" or "+yolo"). This library owns what the
# flag MEANS, and is sourced by both sides of it:
#
#   bin/fm-logbook-compose.sh  withholds the one-click Merge option from the project's
#                              attention-board cards, offering an acknowledgement instead.
#   bin/fm-pr-merge.sh         REFUSES the merge outright.
#
# Both, because a button the board no longer draws is not a safety property. A card
# composed before the flag was set, an answer replayed off a stale board, or a request
# hand-typed at the shell all reach fm-pr-merge.sh with the option gone and the merge
# still one call away. The refusal is what makes the rule hold; withholding the option is
# what keeps the captain from being offered something firstmate would then refuse.
#
# The default is permissive - a project without the flag is exactly as mergeable as it was
# before the flag existed - so this changes nothing for a fleet that declares none.
#
# The flag is a STANDING rule, so it is changed by changing the registry line and not by a
# one-off "merge it": a prohibition a single instruction could wave through is not the rule
# the captain asked for, and the refusal cannot tell that instruction apart from a stale
# card replaying one. To let firstmate merge one of these, drop the flag.
#
# The refusal reads TWO independent signals, either of which forbids, the fail-closed
# shape bin/fm-gate-refuse-lib.sh already sets in this repo:
#
#   1. The project NAME the task records (its meta's project=, or the backlog item's
#      "(repo: <name>)" marker). The normal path, and it works with no clone on disk.
#   2. The PR URL itself, matched against the "origin" of every clone under projects/.
#      The backstop: it derives from the thing actually being merged rather than from
#      bookkeeping that a torn-down, pruned, or hand-crafted request may not carry at all.
#
# Signal 2 answers "which project does this PR belong to" the way bin/fm-logbook-compose.sh
# answers it - the clone's own origin - because a project's directory name is the captain's
# free choice (AGENTS.md section 6) and only incidentally the repo's. It is deliberately
# NOT a registry scan: bin/fm-project-mode.sh stays the sole parser of registry lines, and
# this asks it about a name rather than re-deriving one from the file.
#
# This file is sourced, never executed. It defines:
#   fm_merge_policy_project <fm-root> <fm-home> <project>
#       -> sets FM_MERGE_POLICY_OUT to firstmate|captain (memoized per project)
#   fm_merge_forbidden_project <fm-root> <fm-home> <project>
#       -> 0 when firstmate must NOT merge that project, 1 otherwise
#   fm_merge_forbidden_url <fm-root> <fm-home> <projects-dir> <pr-url>
#       -> 0 when the url names a clone whose project firstmate must NOT merge, 1 otherwise

FM_MERGE_POLICY_OUT=""
# The project fm_merge_forbidden_url matched, so a refusal can name what it is protecting.
# Initialized here rather than only on a match, so a caller under "set -u" can read it
# unconditionally.
FM_MERGE_FORBIDDEN_PROJECT=""

# The memo is a newline-terminated "<project>\t<policy>" string rather than an associative
# array, for the reason bin/fm-logbook-compose.sh states for its own: bash 3.2 has no
# "declare -A", and under "set -e" that would abort the sourcing script outright. Anchoring
# the lookup on the leading separator keeps a name that is merely the SUFFIX of another
# (app vs. myapp) from matching its record.
FM_MERGE_POLICY_SEP=$'\t'
FM_MERGE_POLICY_EOR=$'\n'
FM_MERGE_POLICY_CACHE=$FM_MERGE_POLICY_EOR

# fm_merge_policy_project <fm-root> <fm-home> <project>: sets FM_MERGE_POLICY_OUT to the
# project's merge policy, memoized so a composer asking once per card pays for the lookup
# once per PROJECT. Answers through a global rather than stdout precisely so it CAN
# memoize: a "$(...)" reader runs in a subshell and throws the cache away with it.
#
# A name that cannot key the memo unambiguously - empty, or carrying the separator or a
# record terminator - is answered "firstmate" without a lookup and without caching. It
# cannot address a registry line either, so there is no policy to find; refusing to cache
# it is what keeps a crafted name from writing a record another name would then read.
#
# stderr is dropped because fm-project-mode.sh warns on a project it does not know, and
# asking about one is routine here: a card can carry a project the registry never listed
# (compose composes a minimal row for it), and that project is simply not flagged.
fm_merge_policy_project() {
  local fm_root=${1-} fm_home=${2-} project=${3-} rest policy
  FM_MERGE_POLICY_OUT=firstmate
  [ -n "$project" ] || return 0
  case "$project" in
    *"$FM_MERGE_POLICY_SEP"*|*"$FM_MERGE_POLICY_EOR"*) return 0 ;;
  esac
  case "$FM_MERGE_POLICY_CACHE" in
    *"$FM_MERGE_POLICY_EOR$project$FM_MERGE_POLICY_SEP"*)
      rest=${FM_MERGE_POLICY_CACHE#*"$FM_MERGE_POLICY_EOR$project$FM_MERGE_POLICY_SEP"}
      FM_MERGE_POLICY_OUT=${rest%%"$FM_MERGE_POLICY_EOR"*}
      return 0
      ;;
  esac
  # FM_HOME is passed explicitly rather than left to inheritance: a caller that derived it
  # from FM_ROOT_OVERRIDE (or from its own location) holds it in a shell variable the child
  # would never see, and the child would then read a DIFFERENT home's registry.
  policy=$(FM_HOME="$fm_home" "$fm_root/bin/fm-project-mode.sh" "$project" --merge-policy 2>/dev/null) || policy=""
  case "$policy" in
    captain) ;;
    *) policy=firstmate ;;
  esac
  FM_MERGE_POLICY_CACHE=$FM_MERGE_POLICY_CACHE$project$FM_MERGE_POLICY_SEP$policy$FM_MERGE_POLICY_EOR
  FM_MERGE_POLICY_OUT=$policy
  return 0
}

# fm_merge_forbidden_project <fm-root> <fm-home> <project>: succeed when firstmate must
# not merge that project's work.
fm_merge_forbidden_project() {
  fm_merge_policy_project "${1-}" "${2-}" "${3-}"
  [ "$FM_MERGE_POLICY_OUT" = captain ]
}

# fm_merge_slug <url-or-remote>: sets FM_MERGE_SLUG_OWNER and FM_MERGE_SLUG_REPO to the
# "<owner>" and "<repo>" a GitHub PR url or a clone remote names; both empty when neither
# parses that way. One parse for both sides of the match below, so the url and the origin
# it is compared against can never be read by two rules that drifted apart.
#
# A PR url is ".../<owner>/<repo>/pull/<n>"; a remote is "https://host/owner/repo[.git]"
# or "git@host:owner/repo[.git]", whose scp-style shape leaves the "host:" prefix on
# whichever component follows no "/" (the owner here, or the repo itself in the owner-less
# "git@host:repo.git" form, which yields no owner at all). An owner that does not resolve
# leaves the pair unmatchable, which is the right answer: half a name identifies nothing.
FM_MERGE_SLUG_OWNER=""
FM_MERGE_SLUG_REPO=""
fm_merge_slug() {
  local s=${1-} rest owner_rest
  FM_MERGE_SLUG_OWNER=""
  FM_MERGE_SLUG_REPO=""
  [ -n "$s" ] || return 0
  case "$s" in
    *'/pull/'*) rest=${s%'/pull/'*} ;;
    *) rest=${s%.git}; rest=${rest%/} ;;
  esac
  FM_MERGE_SLUG_REPO=${rest##*/}
  FM_MERGE_SLUG_REPO=${FM_MERGE_SLUG_REPO##*:}
  owner_rest=${rest%/*}
  # An unchanged strip means there was no further "/" and so no owner component at all,
  # which must never be read as the repo standing in for its own owner.
  if [ "$owner_rest" != "$rest" ]; then
    FM_MERGE_SLUG_OWNER=${owner_rest##*/}
    FM_MERGE_SLUG_OWNER=${FM_MERGE_SLUG_OWNER##*:}
  fi
  case "$FM_MERGE_SLUG_REPO" in *[[:space:]]*) FM_MERGE_SLUG_REPO="" ;; esac
  case "$FM_MERGE_SLUG_OWNER" in *[[:space:]]*) FM_MERGE_SLUG_OWNER="" ;; esac
  return 0
}

# fm_merge_same_part <a> <b>: succeed when two owner or repo names name the same thing on
# GitHub, which folds their case - "acme/Alpha" and "ACME/alpha" are one repo, not two.
# The two sides are written by different hands (an origin as the captain typed it at clone
# time, a PR url as the GitHub API returned it), so a byte-exact "=" would read a
# case-only difference as a mismatch and let a forbidden merge through. Folding cannot
# loosen it the other way: case-folded owner/repo names are unique on GitHub, so two that
# fold alike ARE the same repo. An empty half never matches - it is unresolved, which
# proves nothing.
fm_merge_same_part() {
  local a=${1-} b=${2-}
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  [ "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')" ]
}

# fm_merge_forbidden_url <fm-root> <fm-home> <projects-dir> <pr-url>: succeed when the url
# names the repo a clone under <projects-dir> pushes to AND that clone's project is one
# firstmate must not merge. Fails (permits) when the url parses to no owner/repo, when no
# clone claims it, or when the clone that does is not flagged - an unmatched url is simply
# a repo this home cannot speak for, not a licence, and signal 1 has already had its say.
#
# Discovery is BOUNDED at <projects-dir>, because git otherwise walks UP from its "-C"
# directory until it finds a repo: a projects/<name> that is not a clone would answer with
# the ENCLOSING repo's origin, and in the shipped layout that enclosure is firstmate's own
# checkout (FM_HOME is a git repo; gitignoring projects/ does not stop discovery). Every
# non-clone directory would then answer with firstmate's own repo - so were firstmate
# itself flagged, one stray directory would refuse every merge in the fleet. The ceiling
# must be the PHYSICAL path (git compares it against its own getcwd, which resolves
# symlinks) and must be absolute (git ignores a relative entry); an unresolvable
# projects/ leaves it empty and skips the scan, since no clone can live under a dir that
# will not open. Strictly READ-ONLY inside projects/ (prime directive 1): "remote get-url"
# reads config and touches no ref, index, or worktree.
fm_merge_forbidden_url() {
  local fm_root=${1-} fm_home=${2-} projects_dir=${3-} url=${4-}
  local ceiling dir name origin want_owner want_repo
  fm_merge_slug "$url"
  want_owner=$FM_MERGE_SLUG_OWNER
  want_repo=$FM_MERGE_SLUG_REPO
  [ -n "$want_owner" ] && [ -n "$want_repo" ] || return 1
  [ -n "$projects_dir" ] && [ -d "$projects_dir" ] || return 1
  ceiling=$(cd "$projects_dir" 2>/dev/null && pwd -P) || return 1
  [ -n "$ceiling" ] || return 1
  for dir in "$projects_dir"/*; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    origin=$(GIT_CEILING_DIRECTORIES="$ceiling" git -C "$dir" remote get-url origin 2>/dev/null) || continue
    [ -n "$origin" ] || continue
    fm_merge_slug "$origin"
    fm_merge_same_part "$want_owner" "$FM_MERGE_SLUG_OWNER" || continue
    fm_merge_same_part "$want_repo" "$FM_MERGE_SLUG_REPO" || continue
    if fm_merge_forbidden_project "$fm_root" "$fm_home" "$name"; then
      FM_MERGE_POLICY_OUT=captain
      # shellcheck disable=SC2034 # Read by callers (fm-pr-merge.sh) after this returns.
      FM_MERGE_FORBIDDEN_PROJECT=$name
      return 0
    fi
  done
  return 1
}
