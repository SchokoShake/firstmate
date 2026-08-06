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
# flag MEANS, and is sourced by every write path that could act on it:
#
#   bin/fm-logbook-compose.sh  withholds the one-click Merge option from the project's
#                              attention-board cards, offering an acknowledgement instead.
#   bin/fm-logbook-push.sh     strips that option back out of the rich card firstmate
#                              composes on top, since the upsert would otherwise restore
#                              exactly what compose withheld.
#   bin/fm-pr-merge.sh         REFUSES the merge outright.
#   bin/fm-merge-local.sh      refuses the local-only merge, firstmate's other merge path.
#
# All of them, because a button the board no longer draws is not a safety property. A card
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
# Set once the process has reported a lookup it could not perform, so a composer asking
# about fifty cards does not repeat one broken-sibling diagnostic fifty times.
FM_MERGE_POLICY_LOOKUP_WARNED=""

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
# The child's stderr is FILTERED, not dropped, and the two kinds of line it writes divide
# on exactly the question this function is asking:
#
#   The registry line is MALFORMED. Re-emitted, both shapes of it: a bracket token past
#   the mode that is none of the posture flags, and a mode that is none of the three
#   delivery modes. Every path where the flag MATTERS reaches the registry through this
#   function, so dropping those wholesale lets a mistyped prohibition merge in silence -
#   the exact failure the warnings were added to catch, and worse than no warning at all,
#   because it manufactures confidence that the typo would have been caught. All three
#   ways of writing "+captain-merge" wrong land in one of the two: "[direct-PR
#   +captainmerge]" and "[direct-PR captain-merge]" as unrecognized posture flags, and
#   "[captain-merge]" as an unknown mode - the first bracket position is the mode, so a
#   posture flag written as the SOLE token is read as one and never reaches the posture
#   diagnostic at all. That last is why the mode warning belongs here too, and it is the
#   easiest of the three to write.
#
#   There is NO line - the project is not in the registry, or there is no registry at
#   all. Suppressed, because asking about such a project is routine here: a card can
#   carry one the registry never listed (compose composes a minimal row for it), and that
#   project is simply not flagged. That noise is the whole reason this is a filter rather
#   than a bare passthrough.
#
# Neither malformed shape is ever HONORED - bin/fm-project-mode.sh reports it and leaves
# the policy exactly as permissive as the line actually reads, because a prohibition
# guessed at from a typo would be its own failure - so the re-emitted warning is the only
# thing standing between a mistyped prohibition and a silent merge. The memo below buys
# one lookup per PROJECT, so the re-emission is bounded per project rather than repeated
# once per card.
#
# The child's EXIT STATUS and its answer are read separately, because "could not ask" is
# not the same fact as "asked, and the project is not flagged". Both stay permissive - a
# missing or unexecutable sibling must never refuse merges fleet-wide, and the permissive
# default is exactly what makes this whole axis a no-op for a fleet that declares none -
# but a failed lookup warns once and is NOT memoized, so it stays visible and is retried
# rather than cached as a verdict for the rest of the process.
fm_merge_policy_project() {
  local fm_root=${1-} fm_home=${2-} project=${3-} rest policy asked err_file line
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
  asked=yes
  # A temp file rather than a pipeline or a process substitution: the answer and the
  # diagnostic both have to come back to THIS shell, and a "$(...)" that carried the
  # stderr would run the assignment in a subshell and lose the answer with it. An
  # unavailable temp file falls back to dropping the stream, never to failing the lookup.
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-merge-policy.XXXXXX" 2>/dev/null) || err_file=/dev/null
  policy=$(FM_HOME="$fm_home" "$fm_root/bin/fm-project-mode.sh" "$project" --merge-policy 2>"$err_file") || asked=no
  while IFS= read -r line; do
    case "$line" in
      'warn: unrecognized posture flag'*|'warn: unknown mode'*) printf '%s\n' "$line" >&2 ;;
    esac
  done < "$err_file"
  [ "$err_file" = /dev/null ] || rm -f "$err_file"
  # An answer that is neither word is no answer either: this script's stdout contract says
  # the policy query prints one of exactly two words, so anything else means the child did
  # not answer the question that was put to it.
  case "$policy" in
    firstmate|captain) ;;
    *) asked=no ;;
  esac
  if [ "$asked" != yes ]; then
    if [ -z "$FM_MERGE_POLICY_LOOKUP_WARNED" ]; then
      FM_MERGE_POLICY_LOOKUP_WARNED=yes
      echo "warn: could not read the merge policy for \"$project\" from $fm_root/bin/fm-project-mode.sh; treating projects as mergeable until it answers" >&2
    fi
    return 0
  fi
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
# A PR url is ".../<owner>/<repo>/pull/<n>" with a NUMERIC <n>, optionally followed by one
# trailing "/" and optionally naming its repo with a ".git" suffix; a remote is
# "https://host/owner/repo[.git]" or "git@host:owner/repo[.git]", whose scp-style shape
# leaves the "host:" prefix on whichever component follows no "/" (the owner here, or the
# repo itself in the owner-less "git@host:repo.git" form, which yields no owner at all).
# An owner that does not resolve leaves the pair unmatchable, which is the right answer:
# half a name identifies nothing.
#
# Those two url tolerances are not cosmetic. This guard must resolve EVERY url the thing it
# guards would act on, or the url it cannot read is exactly the one that walks past it:
# bin/fm-pr-merge.sh's parse_pr_url accepts a trailing "/" (".../pull/7/") and a ".git"
# repo component, and hands the parsed owner/repo straight to "gh-axi pr merge". A slug
# parse that read ".../pull/7/" as a non-numeric PR number returned no owner/repo at all,
# so signal 2 matched no clone and PERMITTED the merge of a "+captain-merge" project - on
# the torn-down, pruned task that is the very case signal 2 exists for, since signal 1 then
# has no meta and no backlog item to read. bin/fm-logbook-push.sh runs no such parse at
# ALL: its urls come off hand-composed cards. So the tolerances live here, in the guard,
# rather than resting on a caller-side parse this library does not run.
#
# NOT the sole owner of this parse: bin/fm-logbook-compose.sh's pr_slug, same_repo_part,
# and project_remote_repo answer the same "do these two name one GitHub repo" question
# for the composer, and the two live in one process because compose sources this file.
# Consolidating them is tracked as fm-merge-slug-one-owner (blocked on the logbook v2
# extraction, which is proving byte-parity against today's compose and so must not move).
# Until then the two are pinned to identical OUTCOMES by a shared input table in
# tests/fm-logbook.test.sh, and this side is the one that yields where they differ:
#
#   - The numeric-<n> requirement above is compose's rule, adopted here. It is a
#     TIGHTENING, so it does loosen this guard for a malformed PR url - ".../pull/abc"
#     now matches no clone and forbids nothing. Nothing reaches a merge through that gap:
#     bin/fm-pr-merge.sh's own parse_pr_url hard-rejects a non-numeric <n> before this is
#     consulted, and bin/fm-logbook-push.sh only ever declines to strip a board button
#     whose merge that same parse would refuse anyway.
#   - The trailing "/" and ".git" tolerances go the OTHER way: this side is deliberately
#     WIDER than compose's pr_slug, which reads either url as unparseable. That divergence
#     is safe in both directions because each side fails CLOSED in its own currency -
#     compose withholds a button it cannot verify, and this refuses a merge it can trace to
#     a flagged clone - whereas making them agree by narrowing this one is what opened the
#     bypass above. compose is not widened to match: bin/fm-logbook-compose.sh's output is
#     pinned byte-for-byte while the logbook v2 extraction proves parity against it, and
#     tolerating either form there would newly offer a Merge button.
#   - The REMOTE side diverges the same way and for the same reason: an origin ending
#     ".git/" resolves here to "acme/guarded" and in compose's project_remote_repo to
#     "acme/guarded.git", which matches no PR url. Order is the whole difference - the
#     trailing "/" has to come off before the ".git" behind it - and getting it wrong on
#     THIS side is fail-open, because an origin the guard cannot resolve is a clone it
#     cannot trace a merge to.
#   - The whitespace blanking below has no counterpart in compose's pr_slug, but it is
#     mechanical rather than behavioural: compose blanks whitespace on the REMOTE side
#     instead (project_remote_repo), and same_repo_part needs both halves, so a
#     whitespace-bearing name matches nothing on either side.
#
# The shared table carries every one of those shapes: the ones both sides read alike are
# pinned as agreements, and each divergence is pinned as a DECLARED one that asserts its
# direction, so narrowing this side back to compose's fails the suite rather than
# silently reopening a bypass. The two wider url forms and the ".git/" origin are pinned
# end to end in tests/fm-pr-merge.test.sh as well, since the refusal is the property that
# actually matters.
FM_MERGE_SLUG_OWNER=""
FM_MERGE_SLUG_REPO=""
fm_merge_slug() {
  local s=${1-} rest owner_rest num
  FM_MERGE_SLUG_OWNER=""
  FM_MERGE_SLUG_REPO=""
  [ -n "$s" ] || return 0
  case "$s" in
    *'/pull/'*)
      num=${s##*'/pull/'}
      # Exactly the one optional trailing "/" parse_pr_url accepts, and no more, so this
      # reads every url that reaches a merge and no url that does not.
      num=${num%/}
      case "$num" in
        ''|*[!0-9]*) return 0 ;;
      esac
      rest=${s%'/pull/'*}
      # The repo half of a PR url, normalized the way the remote branch below already
      # normalizes its own, so ".../acme/guarded.git/pull/7" and the clone origin
      # "https://github.com/acme/guarded.git" resolve to ONE repo rather than to a
      # spurious mismatch that permits the merge.
      rest=${rest%.git}
      ;;
    # The trailing "/" comes off FIRST, or a ".git" sitting behind one is never reached:
    # an origin of "https://github.com/acme/guarded.git/" - what "git clone
    # https://github.com/acme/guarded.git/" records verbatim - would resolve to the repo
    # "guarded.git", which matches no PR url, leaving the clone claiming nothing and the
    # merge permitted.
    *) rest=${s%/}; rest=${rest%.git} ;;
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
# proves nothing. The counterpart of bin/fm-logbook-compose.sh's same_repo_part; see
# fm_merge_slug's header for why both still exist and what pins them together.
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
  # Cleared on entry, not only on a match: the header invites callers to read this
  # unconditionally under "set -u", and a call that matches nothing must not leave the
  # PREVIOUS call's project name behind for a refusal message to name the wrong project.
  FM_MERGE_FORBIDDEN_PROJECT=""
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
