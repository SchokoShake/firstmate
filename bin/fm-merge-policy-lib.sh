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
#   bin/fm-pr-merge.sh         REFUSES the merge outright.
#   bin/fm-merge-local.sh      refuses the local-only merge, firstmate's other merge path.
#
# Both, because a prohibition that held on one of firstmate's two merge paths and not the
# other is the kind of rule that quietly stops being true.
#
# An out-of-tree surface that OFFERS a merge - an attention board's one-click Merge, say -
# should source this file and withhold that offer for a forbidden project, but withholding
# it is never the safety property: an offer composed before the flag was set, an answer
# replayed off a stale surface, or a request hand-typed at the shell all reach
# bin/fm-pr-merge.sh with the button long gone and the merge still one call away. The
# refusal here is what makes the rule hold; withholding the offer only keeps the captain
# from being handed something firstmate would then refuse.
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
# Signal 2 answers "which project does this PR belong to" from the clone's own origin,
# never from its directory name, because a project's directory name is the captain's
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
#   fm_merge_policy_warn <text>
#       -> writes one policy diagnostic to stderr, marked with FM_MERGE_POLICY_DIAG_MARKER

# The marker every diagnostic this library writes carries, and the ONE thing a caller has
# to know to pick those diagnostics out of a stream it otherwise drops. Only
# bin/fm-bootstrap.sh's session-start board sync needs that today - the other callers let
# this stderr through untouched - and it needs it badly, because that sync is the only read
# of the policy that runs unattended.
#
# It exists because the caller-side alternative failed exactly once and in the worst way: a
# filter that enumerated the message TEXTS worth keeping had to be re-edited every time a
# diagnostic was added or reworded, and the one it silently lost was the failed-lookup line
# below - the one that means the policy could not be read at ALL, so every project in the
# fleet fell open to mergeable. Selecting on the marker instead means a diagnostic added
# here later reaches the captain with no caller-side edit at all.
FM_MERGE_POLICY_DIAG_MARKER='fm-merge-policy:'

# fm_merge_policy_warn <text>: the single writer of this library's stderr, so the marker
# cannot be forgotten on a line added later. Everything below reports through it.
fm_merge_policy_warn() {
  printf '%s %s\n' "$FM_MERGE_POLICY_DIAG_MARKER" "${1-}" >&2
}

FM_MERGE_POLICY_OUT=""
# The project fm_merge_forbidden_url matched, so a refusal can name what it is protecting.
# Initialized here rather than only on a match, so a caller under "set -u" can read it
# unconditionally.
FM_MERGE_FORBIDDEN_PROJECT=""

# The memo is a newline-terminated "<project>\t<policy>" string rather than an associative
# array because bash 3.2 has no "declare -A", and under "set -e" that would abort the
# sourcing script outright. Anchoring
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
# The child's stderr is FILTERED, not dropped, and the filter defaults to KEEPING: it
# names the lines it drops and re-emits everything else through fm_merge_policy_warn.
#
#   SUPPRESSED, and only these two: there is no registry line for the project, or no
#   registry at all. Asking about such a project is routine here - a card can carry one
#   the registry never listed (compose composes a minimal row for it), and that project is
#   simply not flagged. That noise is the whole reason this is a filter rather than a bare
#   passthrough.
#
#   RE-EMITTED: everything else bin/fm-project-mode.sh says, including a shape this
#   library has never seen. The two that matter today both mean the registry line is
#   MALFORMED - a bracket token past the mode that is none of the posture flags, and a
#   mode that is none of the three delivery modes. Every path where the flag MATTERS
#   reaches the registry through this function, so dropping those lets a mistyped
#   prohibition merge in silence - the exact failure the warnings were added to catch, and
#   worse than no warning at all, because it manufactures confidence that the typo would
#   have been caught. All three ways of writing "+captain-merge" wrong land in one of the
#   two: "[direct-PR +captainmerge]" and "[direct-PR captain-merge]" as unrecognized
#   posture flags, and "[captain-merge]" as an unknown mode - the first bracket position
#   is the mode, so a posture flag written as the SOLE token is read as one and never
#   reaches the posture diagnostic at all. That last is why the mode warning belongs here
#   too, and it is the easiest of the three to write.
#
# The filter names its drops rather than its keeps for the same reason the caller selects
# on a marker rather than on message texts: a keep-list silently loses every diagnostic
# the child GAINS, and the loss is invisible until a prohibition has already been merged
# past. Naming the drops fails the other way - an unfamiliar line is surfaced, not eaten.
#
# Neither malformed shape is ever HONORED - bin/fm-project-mode.sh reports it and leaves
# the policy exactly as permissive as the line actually reads, because a prohibition
# guessed at from a typo would be its own failure - so the re-emitted warning is the only
# thing standing between a mistyped prohibition and a silent merge. The memo below buys
# one lookup per PROJECT, so the re-emission is bounded per project rather than repeated
# once per card; a lookup that FAILED is not memoized, so its stderr is bounded instead by
# the same once-per-process flag its own warning uses.
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
  # An answer that is neither word is no answer either: this script's stdout contract says
  # the policy query prints one of exactly two words, so anything else means the child did
  # not answer the question that was put to it. Read BEFORE the stderr is re-emitted, so
  # the re-emission can be bounded by which of the two cases this is.
  case "$policy" in
    firstmate|captain) ;;
    *) asked=no ;;
  esac
  # An answered lookup is memoized below, so its diagnostics cost one re-emission per
  # PROJECT. A failed one deliberately is not, so what it wrote - an exec error rather than
  # a registry diagnostic - is bounded by the same once-per-process flag its own warning
  # uses, instead of repeating that error once per card on a board.
  if [ "$asked" = yes ] || [ -z "$FM_MERGE_POLICY_LOOKUP_WARNED" ]; then
    while IFS= read -r line; do
      case "$line" in
        ''|'warn: no registry at '*|'warn: project "'*'" not in registry'*) ;;
        *) fm_merge_policy_warn "${line#warn: }" ;;
      esac
    done < "$err_file"
  fi
  [ "$err_file" = /dev/null ] || rm -f "$err_file"
  if [ "$asked" != yes ]; then
    if [ -z "$FM_MERGE_POLICY_LOOKUP_WARNED" ]; then
      FM_MERGE_POLICY_LOOKUP_WARNED=yes
      fm_merge_policy_warn "could not read the merge policy for \"$project\" from $fm_root/bin/fm-project-mode.sh; treating projects as mergeable until it answers"
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
# guards would act on, or the url it cannot read is exactly the one that walks past it.
# bin/fm-pr-lib.sh's fm_pr_url_parse is what decides which urls reach a merge, and it hands
# the parsed owner/repo straight to "gh-axi pr merge". It accepts a ".git" repo component
# today (".../acme/guarded.git/pull/7" parses, repo and all) and rejects a trailing "/" -
# but which side of that line a given shape falls on is fm_pr_url_parse's to change, not
# this library's to depend on. A slug parse that read ".../pull/7/" as a non-numeric PR
# number returned no owner/repo at all, so signal 2 matched no clone and PERMITTED the
# merge of a "+captain-merge" project - on the torn-down, pruned task that is the very case
# signal 2 exists for, since signal 1 then has no meta and no backlog item to read. So the
# tolerances live HERE, in the guard, and stay strictly WIDER than the merge path's own
# parse rather than tracking it, because a later widening there must not be able to open a
# bypass here. tests/fm-pr-slug-contract.test.sh asserts that composition directly.
#
# The tolerances are deliberately asymmetric, and each direction fails CLOSED:
#
#   - A non-numeric <n> (".../pull/abc") matches no clone and forbids nothing. Nothing
#     reaches a merge through that gap: fm_pr_url_parse hard-rejects a non-numeric PR
#     number before bin/fm-pr-merge.sh ever consults this.
#   - The trailing "/" and ".git" tolerances go the other way and are deliberately WIDE,
#     because a url this could not parse is a merge this could not trace to a flagged
#     clone - and narrowing them is exactly what opened the bypass above.
#   - The REMOTE side diverges the same way and for the same reason: an origin ending
#     ".git/" resolves here to "acme/guarded" and in compose's project_remote_repo to
#     "acme/guarded.git", which matches no PR url. Order is the whole difference - the
#     trailing "/" has to come off before the ".git" behind it - and getting it wrong on
#     THIS side is fail-open, because an origin the guard cannot resolve is a clone it
#     cannot trace a merge to.
#   - The whitespace blanking below has no counterpart in the connector's pr_slug, but it is
#     mechanical rather than behavioural: compose blanks whitespace on the REMOTE side
#     instead (project_remote_repo), and same_repo_part needs both halves, so a
#     whitespace-bearing name matches nothing on either side.
#
# Every one of those shapes is stated once, as DATA, in tests/fixtures/pr-slug/, and
# docs/architecture.md ("Cross-repo contracts are stated as fixtures") owns why the two
# implementations share a fixture instead of being consolidated. What matters HERE is the
# direction: each declared divergence asserts the connector's differing value, so narrowing
# this side back to the connector's parse fails tests/fm-pr-slug-contract.test.sh rather
# than silently reopening a bypass. The forms fm_pr_url_parse actually admits are pinned
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
      # bin/fm-pr-lib.sh's fm_pr_url_parse decides which urls reach a merge, and it REJECTS
      # a trailing "/" today. This strips exactly one anyway, and no more, because the guard
      # stays deliberately WIDER than the merge path's own parse rather than tracking it: a
      # later widening there must not be able to open a bypass here (see the header).
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
# proves nothing.
fm_merge_same_part() {
  local a=${1-} b=${2-}
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  [ "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')" ]
}

# The scanned clones, as newline-terminated "<project>\t<owner>\t<repo>" records, and the
# resolved projects/ they were read from. A process asking about several urls would
# otherwise ask git for the same origins once per url, when what an origin names cannot
# change under it mid-run. Memoized for the same reason fm_merge_policy_project is, in the
# same shape and for the same bash 3.2 reason: no "declare -A", which would abort a
# sourcing script under "set -e". The ceiling doubles as the cache key, so a caller passing
# a different projects/ rescans rather than reading another directory's answers; empty
# means nothing has been scanned yet, which no resolved ceiling ever is.
FM_MERGE_ORIGIN_SEP=$'\t'
FM_MERGE_ORIGIN_EOR=$'\n'
FM_MERGE_ORIGIN_CEILING=""
FM_MERGE_ORIGIN_CACHE=""

# fm_merge_origin_scan <projects-dir> <ceiling>: fill FM_MERGE_ORIGIN_CACHE with one record
# per clone under <projects-dir> whose "origin" resolves, unless it already holds that
# directory's scan.
#
# Discovery is BOUNDED at the ceiling, because git otherwise walks UP from its "-C"
# directory until it finds a repo: a projects/<name> that is not a clone would answer with
# the ENCLOSING repo's origin, and in the shipped layout that enclosure is firstmate's own
# checkout (FM_HOME is a git repo; gitignoring projects/ does not stop discovery). Every
# non-clone directory would then answer with firstmate's own repo - so were firstmate
# itself flagged, one stray directory would refuse every merge in the fleet. Strictly
# READ-ONLY inside projects/ (prime directive 1): "remote get-url" reads config and touches
# no ref, index, or worktree.
#
# A directory name carrying the record separators cannot be stored unambiguously and is
# skipped. That loses nothing: such a name is one fm_merge_policy_project already answers
# "firstmate" without a lookup, precisely because it cannot key the memo either, so a
# record for it could never have forbidden anything.
fm_merge_origin_scan() {
  local projects_dir=${1-} ceiling=${2-} dir name origin
  [ "$FM_MERGE_ORIGIN_CEILING" != "$ceiling" ] || return 0
  FM_MERGE_ORIGIN_CACHE=""
  for dir in "$projects_dir"/*; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    case "$name" in
      ''|*"$FM_MERGE_ORIGIN_SEP"*|*"$FM_MERGE_ORIGIN_EOR"*) continue ;;
    esac
    origin=$(GIT_CEILING_DIRECTORIES="$ceiling" git -C "$dir" remote get-url origin 2>/dev/null) || continue
    [ -n "$origin" ] || continue
    # Parsed once here rather than per lookup: fm_merge_slug blanks any owner or repo
    # carrying whitespace, and the separators are whitespace, so the stored fields can
    # never break the record shape they are written into.
    fm_merge_slug "$origin"
    FM_MERGE_ORIGIN_CACHE=$FM_MERGE_ORIGIN_CACHE$name$FM_MERGE_ORIGIN_SEP$FM_MERGE_SLUG_OWNER$FM_MERGE_ORIGIN_SEP$FM_MERGE_SLUG_REPO$FM_MERGE_ORIGIN_EOR
  done
  FM_MERGE_ORIGIN_CEILING=$ceiling
  return 0
}

# fm_merge_forbidden_url <fm-root> <fm-home> <projects-dir> <pr-url>: succeed when the url
# names the repo a clone under <projects-dir> pushes to AND that clone's project is one
# firstmate must not merge. Fails (permits) when the url parses to no owner/repo, when no
# clone claims it, or when the clone that does is not flagged - an unmatched url is simply
# a repo this home cannot speak for, not a licence, and signal 1 has already had its say.
#
# The ceiling must be the PHYSICAL path (git compares it against its own getcwd, which
# resolves symlinks) and must be absolute (git ignores a relative entry); an unresolvable
# projects/ leaves it empty and skips the scan, since no clone can live under a dir that
# will not open.
fm_merge_forbidden_url() {
  local fm_root=${1-} fm_home=${2-} projects_dir=${3-} url=${4-}
  local ceiling rest record fields name owner repo want_owner want_repo
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
  fm_merge_origin_scan "$projects_dir" "$ceiling"
  rest=$FM_MERGE_ORIGIN_CACHE
  while [ -n "$rest" ]; do
    # Every record the scan writes is terminated, so an unterminated tail is not a record
    # at all; stopping keeps a malformed cache from spinning here forever.
    case "$rest" in
      *"$FM_MERGE_ORIGIN_EOR"*) ;;
      *) break ;;
    esac
    record=${rest%%"$FM_MERGE_ORIGIN_EOR"*}
    rest=${rest#*"$FM_MERGE_ORIGIN_EOR"}
    [ -n "$record" ] || continue
    name=${record%%"$FM_MERGE_ORIGIN_SEP"*}
    fields=${record#*"$FM_MERGE_ORIGIN_SEP"}
    owner=${fields%%"$FM_MERGE_ORIGIN_SEP"*}
    repo=${fields##*"$FM_MERGE_ORIGIN_SEP"}
    fm_merge_same_part "$want_owner" "$owner" || continue
    fm_merge_same_part "$want_repo" "$repo" || continue
    if fm_merge_forbidden_project "$fm_root" "$fm_home" "$name"; then
      FM_MERGE_POLICY_OUT=captain
      # shellcheck disable=SC2034 # Read by callers (fm-pr-merge.sh) after this returns.
      FM_MERGE_FORBIDDEN_PROJECT=$name
      return 0
    fi
  done
  return 1
}
