#!/usr/bin/env bash
# Compose the current fleet attention set into a {projects, items} board body.
#
# Usage: fm-logbook-compose.sh
#        fm-logbook-compose.sh | fm-logbook-sync.sh -
#
# Derives the board's declarative-reconcile body from firstmate's OWN state -
# data/projects.md (the project registry), data/backlog.md (the DURABLE task record:
# the item set, titles, and holds), state/*.meta (the live crew, its recorded PR and
# base branch), state/*.status (a live crew's latest phase), and each project clone's
# "origin" remote (the repo its PRs land in) - and prints one {projects, items} JSON
# object on stdout, ready to pipe into fm-logbook-sync.sh.
# This mechanizes the tedious hand-composition that made the session-start sync easy
# to skip. It is a truthful mechanical BASELINE, classed decision > action > fyi,
# with every project from the registry flagged active when it carries a card. Rich,
# captain-facing titles/bodies/options remain firstmate's own composition on top, via
# fm-logbook-push.sh (an upsert keyed by id replaces the baseline card).
#
# The item SET comes from the BACKLOG, never from live crew runtime state. A crew's
# state/<id>.meta exists only while that crew runs, but the documented end-state for
# review-ready work is the opposite: the crew finishes, fm-teardown.sh removes its
# meta AND its status, and the task sits on a captain hold awaiting review (AGENTS.md
# section 7). Keying the board on meta therefore dropped a task at the exact moment it
# started needing the captain - and because POST /api/sync is a declarative full-ITEM
# replace, the next session-start sync then also DELETED any rich fm-logbook-push.sh
# card for it. The backlog is firstmate's durable record (AGENTS.md section 10) and
# survives restarts and teardowns, so it is the item source; meta stays the authority
# on the LIVE crew and only ENRICHES a backlog-derived item.
#
# What earns a card - the board is "what needs the captain", not a backlog mirror:
#   - In flight     live work; an fyi at least, so the captain can see it move.
#   - captain-held  a "(hold-kind: captain)" task is BY DEFINITION waiting on the
#                   captain, in any state, so it earns a card even from Queued; its
#                   "(hold: ...)" prose is already written for a human and is the
#                   card body.
#   - a live crew   never hide running work, even when the backlog has not caught up
#                   yet (the window between fm-spawn and the backlog write) - unless
#                   the backlog says the work is Done.
# Queued work behind no captain gate earns nothing (it is firstmate's to run, not the
# captain's to watch), and neither does Done (it has landed; nothing is owed).
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
# with no base_branch or no match stays ungrouped. base_branch lives only in meta, so
# a torn-down task composes ungrouped until that branch is recorded durably.
# docs/configuration.md ("Logbook" -> "Sub-projects") owns the full declaration
# format, limits, validation, and the base_branch recording path.
#
# Inert by default: a hard no-op (exit 0, no output) unless logbook is opted in via
# a truthy LOGBOOK_ENABLE (config/logbook.env), mirroring the other client scripts.
# Read-only: it only READS fleet state and never posts, so LOGBOOK_DRY_RUN needs no
# branch here - the would-be write lives in fm-logbook-sync.sh, which honors it. Its
# one reach into projects/ (project_remote_repo) is a "git remote get-url" and nothing
# else, so prime directive 1 holds: firstmate never writes to a project. It shells out
# to no backlog tool either, so it composes the same board whether or not tasks-axi is
# on PATH and under config/backlog-backend=manual (AGENTS.md section 10).
# Every dynamic string (id, project, title, body, PR url) is injected into the JSON
# via jq --arg/--argjson, never interpolated into the jq program or a shell word, so
# fleet text can never break out of a shell word or the JSON structure.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS_DIR="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
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

# meta_get <file> <key>: last KEY=value wins; prints nothing when absent. A tiny
# dependency-free reader so compose need not source the backend library. It reads
# both state/<id>.meta and the backlog records below, which are written in the same
# "key=value" shape on purpose.
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

# project_remote_repo <project>: sets REMOTE_REPO_OUT to the "<repo>" component of the
# clone's "origin" remote, so the Merge gate can check a PR against the project's REAL
# GitHub repo rather than the local directory name (which AGENTS.md section 6 lets the
# captain choose freely: "git clone <url> projects/<name>"). Empty when the clone is
# absent, is not a git repo, or has no "origin" - a local-only project legitimately has
# none.
#
# The ONLY filesystem/git access in this otherwise pure text composer, deliberately
# confined to this one call site and memoized per PROJECT (not per item) so composing a
# board stays cheap. It answers through REMOTE_REPO_OUT rather than stdout precisely so
# it CAN memoize: a "$(...)" reader would run every call in a subshell and throw the
# cache away with it, silently re-running git once per card. Strictly READ-ONLY inside
# projects/ (prime directive 1): "remote get-url" reads config and touches no ref,
# index, or worktree.
#
# Discovery is BOUNDED at projects/, because git otherwise walks UP from its "-C"
# directory until it finds a repo: a projects/<name> that is not a clone would answer
# with the ENCLOSING repo's origin, and in the shipped layout that enclosure is
# firstmate's own checkout (FM_HOME is a git repo; gitignoring projects/ does not stop
# discovery). Every card would then read "firstmate" as the repo its project pushes to
# and withhold the Merge as a PROVEN mismatch - silently inverting the absent-clone
# fallback below into the exact regression this composer exists to fix. Bounded, a
# non-clone resolves nothing, which is what that fallback reads. The ceiling must be the
# PHYSICAL path (git compares it against its own getcwd, which resolves symlinks) and
# must be absolute (git ignores a relative entry); an unresolvable projects/ leaves it
# empty and skips the lookup, since no clone can live under a dir that will not open.
#
# The cache is a newline-terminated "<project>\t<repo>" string rather than an
# associative array, so this composes on bash 3.2 as well as 4+ (the stance
# bin/fm-classify-lib.sh states and the rest of bin/ keeps); a "declare -A" here would
# abort the whole script under "set -e" on a host whose bash is 3.2, taking the board
# down with it. Neither field can hold whitespace - valid_project_name rejects it in the
# key and the parse below blanks a repo containing any - so the record shape is
# unambiguous, and anchoring the lookup on the leading separator keeps a project name
# that is merely the SUFFIX of another (app vs. myapp) from matching its record.
REMOTE_REPO_SEP=$'\t'
REMOTE_REPO_EOR=$'\n'
REMOTE_REPO_CACHE=$REMOTE_REPO_EOR
REMOTE_REPO_OUT=""
PROJECTS_CEILING=$(cd "$PROJECTS_DIR" 2>/dev/null && pwd -P) || PROJECTS_CEILING=""
project_remote_repo() {
  local project=${1-} url rest repo
  REMOTE_REPO_OUT=""
  valid_project_name "$project" || return 0
  case "$REMOTE_REPO_CACHE" in
    *"$REMOTE_REPO_EOR$project$REMOTE_REPO_SEP"*)
      rest=${REMOTE_REPO_CACHE#*"$REMOTE_REPO_EOR$project$REMOTE_REPO_SEP"}
      REMOTE_REPO_OUT=${rest%%"$REMOTE_REPO_EOR"*}
      return 0
      ;;
  esac
  repo=""
  url=""
  if [ -n "$PROJECTS_CEILING" ]; then
    url=$(GIT_CEILING_DIRECTORIES="$PROJECTS_CEILING" \
      git -C "$PROJECTS_DIR/$project" remote get-url origin 2>/dev/null) || url=""
  fi
  if [ -n "$url" ]; then
    # Both remote forms end in the repo: "https://host/owner/repo[.git]" and
    # "git@host:owner/repo[.git]" (whose owner-less shape leaves the "host:" prefix
    # on the last path component).
    rest=${url%.git}
    rest=${rest%/}
    repo=${rest##*/}
    repo=${repo##*:}
    case "$repo" in
      *[[:space:]]*) repo="" ;;
    esac
  fi
  REMOTE_REPO_CACHE=$REMOTE_REPO_CACHE$project$REMOTE_REPO_SEP$repo$REMOTE_REPO_EOR
  REMOTE_REPO_OUT=$repo
  return 0
}

# pr_url_ok <url>: succeed when the url is one the board will actually turn into a
# link. The board's renderInline does exactly one link substitution -
# /\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g - and nothing else: it does NOT autolink a
# bare url and does NOT render the item's source.pr. So the url must be http(s) and
# free of whitespace and ")", or the markdown would render as dead text. Bounded so
# the link can never crowd out the body inside the tool's 20000-byte field limit.
pr_url_ok() {
  local u=${1-}
  [ -n "$u" ] || return 1
  [ "${#u}" -le 400 ] || return 1
  case "$u" in
    http://*|https://*) ;;
    *) return 1 ;;
  esac
  case "$u" in
    *[[:space:]]*|*')'*) return 1 ;;
  esac
  return 0
}

# pr_repo <url>: the "<repo>" path component of a .../<owner>/<repo>/pull/<n> url;
# empty when the url does not parse that way. The single owner of this parse: both
# the label the captain reads and the repo the Merge gate checks are the same two
# halves of one safety story, so they must never drift apart.
pr_repo() {
  local url=${1-} rest num
  case "$url" in
    *'/pull/'*) ;;
    *) return 0 ;;
  esac
  num=${url##*'/pull/'}
  case "$num" in
    ''|*[!0-9]*) return 0 ;;
  esac
  rest=${url%'/pull/'*}
  printf '%s' "${rest##*/}"
}

# pr_link <url>: the url as a markdown link - "[<repo> #<n>](<url>)" when it parses
# as .../<owner>/<repo>/pull/<n>, else a plain "[PR](<url>)". The label is derived
# from the URL itself rather than the registry's project name so it can never
# disagree with where the link actually goes. A standing captain rule: a board card
# referencing a PR (draft included) must carry the full url as a markdown link in the
# card BODY, because a bare "#N" is dead text to the board's renderer.
pr_link() {
  local url=$1 repo
  repo=$(pr_repo "$url")
  # The label sits inside "[...]", which the board's link regex reads as [^\]]+, so a
  # "]" in it would break the link; an unparseable url has no label to use at all.
  case "$repo" in
    ''|*']'*|*'['*) printf '[PR](%s)' "$url"; return 0 ;;
  esac
  printf '[%s #%s](%s)' "$repo" "${url##*'/pull/'}" "$url"
}

# pr_token <token> / report_token <token>: succeed when the token is one tasks-axi
# APPENDS to an item's title text as a link, which is the only thing the peel below
# may eat. There are exactly two, and the backend validates both shapes itself:
# "--pr <url>" ("an http(s) pull request URL ending in /pull/<number>") and
# "--report <path>" ("a data/<id>/report.md path"). Anything else trailing the title
# is the captain's own words - an issue link, a doc reference - so it stays in the
# title, where the board still shows it, rather than vanishing with nothing rendered
# in its place.
pr_token() {
  printf '%s' "${1-}" | grep -qE '^https?://[^[:space:]<>()]+/pull/[0-9]+$'
}
report_token() {
  local t=${1-} inner
  case "$t" in
    data/*/report.md) ;;
    *) return 1 ;;
  esac
  inner=${t#data/}
  inner=${inner%/report.md}
  logbook_valid_id "$inner"
}

# append_pr <body> <url> <max>: <body> with the PR's markdown link as its own trailing
# paragraph, the whole within <max> bytes; the body alone (still within <max>) when
# there is no usable url. The BODY yields the room, never the link: clipping a link
# mid-way strands a "[alpha #42](https://..." that the board renders as dead text,
# which is the very failure rendering it as a link exists to avoid. So the room is
# measured from the rendered link rather than guessed at with a fixed margin, which a
# runaway body could out-grow.
append_pr() {
  local body=$1 url=${2-} max=$3 link room
  if ! pr_url_ok "$url"; then
    clip "$body" "$max"
    return 0
  fi
  link=$(pr_link "$url")
  room=$(( max - ${#link} - 2 ))    # the 2 is the blank line between them
  if [ "$room" -lt 1 ]; then
    clip "$link" "$max"
    return 0
  fi
  body=$(clip "$body" "$room")
  if [ -n "$body" ]; then
    printf '%s\n\n%s' "$body" "$link"
  else
    printf '%s' "$link"
  fi
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

# before_marker_tail <text>: <text> up to the marker tail - everything before the first
# marker the backend appends to an item line. The single owner of where that tail
# BEGINS: both readers of it below (the title, and the hold reason inside the tail) must
# agree on that boundary, or one silently mis-parses the other's field.
# Stripping at "(repo: " alone would leak the whole tail into a captain-facing title
# whenever an item carries no repo, which is the normal shape of the captain-gated
# thread AGENTS.md section 10 recommends ("tasks-axi hold <id> --reason ... --kind
# captain"), so every marker the backend emits ends the title.
before_marker_tail() {
  local seg=${1-} m
  for m in ' (repo: ' ' (kind: ' ' (priority: ' ' (since ' ' (merged ' ' (reported ' \
           ' (hold: ' ' (hold-kind: ' ' (hold-until: '; do
    case "$seg" in
      *"$m"*) seg=${seg%%"$m"*} ;;
    esac
  done
  printf '%s' "$seg"
}

ITEMS_JSONL=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-compose-items.XXXXXX") || { echo "fm-logbook-compose: cannot create temp file" >&2; exit 1; }
REG_JSONL=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-compose-reg.XXXXXX") || { echo "fm-logbook-compose: cannot create temp file" >&2; exit 1; }
SUB_JSONL=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-compose-sub.XXXXXX") || { echo "fm-logbook-compose: cannot create temp file" >&2; exit 1; }
BL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-logbook-compose-backlog.XXXXXX") || { echo "fm-logbook-compose: cannot create temp dir" >&2; exit 1; }
trap 'rm -f "$ITEMS_JSONL" "$REG_JSONL" "$SUB_JSONL"; rm -rf "$BL_DIR"' EXIT

# --- the durable backlog: the item set --------------------------------------

# backlog_parse: read data/backlog.md ONCE into one record per task under $BL_DIR,
# named by task id and written in the same "key=value" shape meta_get already reads:
#   state=in_flight|queued|done  title=  repo=  held=yes|no  hold_kind=  hold_reason=
#   blocked_by=  pr=
# The "## In flight / ## Queued / ## Done" layout, the item forms, and "blocked-by:"
# are AGENTS.md section 10's stated contract, kept byte-exact by both backends. The
# trailing "(repo: ...)", "(kind: ...)", "(priority: ...)", "(since ...)",
# "(hold: ...)", "(hold-kind: ...)", "(hold-until: ...)" markers are NOT documented
# there: they are the form the tasks-axi backend actually emits, which this parses.
# So reading the file directly needs no tasks-axi on PATH and serves both backends -
# a backlog hand-maintained under config/backlog-backend=manual composes its layout
# and titles, and contributes captain-held cards wherever it carries those markers.
#
# A hold carrying a "(hold-until: <date>)" gate that has ARRIVED is not an active
# hold - the gate is "inactive on and after that date", which is exactly what
# tasks-axi itself reports as "held: no" - so an expired gate can never pin a card on
# the board forever, and compose can never disagree with the store it reads. ISO-8601
# dates compare correctly with the separators stripped, so no date parsing is needed.
#
# The PR url is read ONLY from the structured position "tasks-axi update <id> --pr
# <url>" appends it to - the trailing link run at the end of an item's OWN title text,
# before "blocked-by:" and the marker tail - which is what survives teardown.
# bin/fm-pr-check.sh is what writes it, at the same PR-ready moment it arms the merge
# poll, so the durable record is there before the crew that produced it is torn down.
# That run holds link tokens of both kinds the backend appends, in either order, so a
# promoted scout's "--report" path never hides the PR behind it (see
# pr_token/report_token).
# Everything else on the line is free-form prose: a "(hold: ...)" reason routinely
# cites ANOTHER task's PR ("blocked until <url> lands"), as do note lines under a
# task. A card's PR drives a Merge option, and per the logbook-respond skill a "merge"
# answer on the board is genuine captain authorization, so harvesting a url out of
# prose would offer to merge an unrelated repo's PR - irreversibly. A url outside the
# structured position is therefore not this task's PR, full stop.
#
# By that same logic the position alone is not proof: a captain who ends their own
# one-liner with another repo's PR-shaped url hands the structured position a url that
# is not this task's PR either. So the Merge option needs a VERIFIED PR - harvested
# here AND naming the repo this task's project actually pushes to, read from the
# clone's own "origin" remote (compose_item, project_remote_repo). Only the one-click
# merge is withheld when it is not; the url still renders as a link.
backlog_parse() {
  local line section="" rest own id title repo held hold_kind hold_reason hold_until pr today word
  local blocked_by
  [ -f "$BACKLOG_MD" ] || return 0
  today=$(date +%Y-%m-%d 2>/dev/null) || today=""
  while IFS= read -r line; do
    case "$line" in
      '## In flight'*) section=in_flight; continue ;;
      '## Queued'*)    section=queued;    continue ;;
      '## Done'*)      section='done';    continue ;;
      '## '*)          section="";        continue ;;   # some other H2: not a task section
    esac
    [ -n "$section" ] || continue

    # The item forms AGENTS.md section 10 keeps: the checkbox forms and the bold
    # in-flight form. Anything else (an indented note, a blank line) is not an item.
    id=""
    case "$line" in
      '- [ ] '*) rest=${line#'- [ ] '} ;;
      '- [x] '*) rest=${line#'- [x] '} ;;
      '- [X] '*) rest=${line#'- [X] '} ;;
      '- **'*)
        rest=${line#'- **'}
        case "$rest" in
          *'** - '*) id=${rest%%'** - '*}; rest=${rest#*'** - '} ;;
          *) continue ;;
        esac
        ;;
      *) continue ;;
    esac
    if [ -z "$id" ]; then
      case "$rest" in
        *' - '*) id=${rest%%' - '*}; rest=${rest#*' - '} ;;
        *) continue ;;
      esac
    fi
    logbook_valid_id "$id" || continue

    # The human one-liner: the title text with the trailing bookkeeping dropped. The
    # marker tail, the "blocked-by:" dependency record, and the appended link run are
    # all firstmate's own records, not something to read to the captain.
    #
    # "blocked-by:" is dropped from the title but RECORDED, not discarded: like a hold,
    # it is firstmate's own record that the work is not ready, and compose_item's Merge
    # gate has to see it. Both documented placements have to count - AGENTS.md section
    # 10 writes it AFTER the "(repo: ...)" marker, while the tasks-axi backend emits it
    # BEFORE the marker tail - so the record is read from the WHOLE item line while the
    # title is cut from the pre-marker text. Reading it from the title alone would gate
    # the tasks-axi backend and silently never gate the hand-maintained one this
    # composer explicitly serves. The value is only ever used as a yes/no, so the
    # documented form's trailing " - <reason>" needs no further parsing.
    #
    # Erring eager here is the safe direction: the worst a false positive (a hold reason
    # quoting the literal string) can do is withhold one Merge click, while a miss offers
    # the captain an irreversible merge on work the fleet recorded as not-ready.
    own=$(before_marker_tail "$rest")
    blocked_by=""
    case "$rest" in
      *' blocked-by:'*) blocked_by=$(trim "$(before_marker_tail "${rest#*' blocked-by:'}")") ;;
    esac
    title=${own%%' blocked-by:'*}

    # The PR, harvested from that structured link run ONLY (see the header): peel the
    # trailing link tokens off the title, stopping at the first token that is not one
    # the backend appends, and keep the FIRST PR-shaped url among them. Peeling
    # right-to-left means the last assignment is the leftmost url.
    pr=""
    while :; do
      word=${title##* }
      if pr_token "$word"; then
        pr=$word
      elif ! report_token "$word"; then
        break
      fi
      case "$title" in
        *' '*) title=${title% *} ;;
        *) title=""; break ;;
      esac
    done
    title=$(trim "$title")

    # The BARE project name. The marker carries trailing content in the form
    # AGENTS.md section 10 documents for a hand-maintained backlog - one combined
    # "(repo: <name>, since <date>)" rather than the tasks-axi backend's separate
    # "(repo: <name>) (since <date>)" - and the whole value would then be neither a
    # usable project name nor a repo any url could match.
    repo=""
    case "$line" in
      *' (repo: '*)
        repo=${line#*' (repo: '}
        repo=${repo%%')'*}
        repo=${repo%%,*}
        repo=$(trim "$repo")
        ;;
    esac

    held=no; hold_kind=""; hold_reason=""; hold_until=""
    case "$line" in
      *' (hold: '*)
        # The one marker value that can itself contain ")": the reason is free-form
        # human prose, and compose_item makes it a captain-facing card body verbatim.
        # The tasks-axi backend rejects a "--reason" containing parentheses for exactly
        # this reason ("Parentheses are reserved for markdown hold tags"), but a backlog
        # hand-maintained under config/backlog-backend=manual has no such gate, and
        # ending the reason at the FIRST ")" would silently drop everything the captain
        # wrote after their own parenthetical - the actionable half of the note. So end
        # it where the marker tail resumes (or at end-of-line), then drop the marker's
        # own closing ")" - the LAST one, never the first. The other marker values need
        # none of this: repo, hold-kind, and hold-until cannot contain ")".
        hold_reason=$(before_marker_tail "${line#*' (hold: '}")
        hold_reason=${hold_reason%')'*}
        held=yes
        ;;
    esac
    case "$line" in
      *' (hold-kind: '*) hold_kind=${line#*' (hold-kind: '}; hold_kind=${hold_kind%%')'*} ;;
    esac
    case "$line" in
      *' (hold-until: '*) hold_until=${line#*' (hold-until: '}; hold_until=${hold_until%%')'*} ;;
    esac
    case "$hold_until" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) hold_until="" ;;   # absent, or the "-" placeholder: no gate
    esac
    if [ "$held" = yes ] && [ -n "$hold_until" ] && [ -n "$today" ]; then
      if [ "${today//-/}" -ge "${hold_until//-/}" ]; then
        # The gate arrived: this is not a hold any more, so drop its prose with it
        # rather than let a lapsed reason read as live context on a card.
        held=no; hold_kind=""; hold_reason=""
      fi
    fi

    {
      printf 'state=%s\n' "$section"
      printf 'title=%s\n' "$title"
      printf 'repo=%s\n' "$repo"
      printf 'held=%s\n' "$held"
      printf 'hold_kind=%s\n' "$hold_kind"
      printf 'hold_reason=%s\n' "$hold_reason"
      printf 'blocked_by=%s\n' "$blocked_by"
      printf 'pr=%s\n' "$pr"
    } > "$BL_DIR/$id" || { echo "fm-logbook-compose: cannot record backlog task $id" >&2; return 1; }
  done < "$BACKLOG_MD"
  return 0
}

# compose_item <id>: emit this task's card to $ITEMS_JSONL, or nothing when it does
# not earn one. The backlog record decides whether there is a card at all; the live
# crew's meta only enriches it.
compose_item() {
  local id=$1
  local rec="$BL_DIR/$id" meta="$STATE/$id.meta"
  local bstate title repo held hold_kind hold_reason blocked_by bl_pr captain_held live
  local not_ready proj_path project pr pr_ok pr_name remote_name base_branch last kind detail
  local body options note

  bstate=$(meta_get "$rec" state)
  title=$(meta_get "$rec" title)
  repo=$(meta_get "$rec" repo)
  held=$(meta_get "$rec" held)
  hold_kind=$(meta_get "$rec" hold_kind)
  hold_reason=$(meta_get "$rec" hold_reason)
  blocked_by=$(meta_get "$rec" blocked_by)
  bl_pr=$(meta_get "$rec" pr)

  live=""
  if [ -f "$meta" ]; then
    # A persistent supervisor is infrastructure, not an attention item.
    if [ "$(meta_get "$meta" kind)" = secondmate ]; then return 0; fi
    live=yes
  fi

  captain_held=no
  if [ "$held" = yes ] && [ "$hold_kind" = captain ]; then captain_held=yes; fi

  # NOT-READY: firstmate's own durable record that this work cannot land yet, in either
  # form AGENTS.md section 10 gives it - an ACTIVE hold that is not a captain hold
  # (external, parked, future), or an uncleared "blocked-by: <id>" dependency. One
  # concept, read once, so the Merge gate below can never guard one form and miss the
  # other. A captain hold is deliberately NOT not-ready: it is the captain themself the
  # work waits on, which is the whole point of the card.
  not_ready=no
  if [ -n "$blocked_by" ]; then not_ready=yes; fi
  if [ "$held" = yes ] && [ "$captain_held" != yes ]; then not_ready=yes; fi

  # What earns a card (see the header): In flight, captain-held in any state, or a
  # live crew the backlog has not recorded yet. Done never does, even while a
  # not-yet-torn-down meta lingers - the work landed, so nothing is owed.
  case "$bstate" in
    done) return 0 ;;
    in_flight) ;;
    *)
      if [ "$captain_held" != yes ] && [ -z "$live" ]; then return 0; fi
      ;;
  esac

  # The live crew's recorded project wins (it is the path it actually works in);
  # otherwise the backlog's own "(repo: ...)", which is what outlives the crew.
  project=""
  if [ -n "$live" ]; then
    proj_path=$(meta_get "$meta" project)
    if [ -n "$proj_path" ]; then project=$(basename "$proj_path"); fi
  fi
  if [ -z "$project" ]; then project=$repo; fi
  valid_project_name "$project" || project=""

  # The PR: fm-pr-check records it into the live crew's meta, so that wins while the
  # crew exists; the backlog line's own url is what remains after teardown.
  pr=""
  if [ -n "$live" ]; then pr=$(meta_get "$meta" pr); fi
  if [ -z "$pr" ]; then pr=$bl_pr; fi

  # A VERIFIED PR is one that is demonstrably THIS task's: its url names the repo this
  # task's project actually pushes to (see the header). Only a verified PR earns the
  # Merge option a "merge" answer would irreversibly authorize. The match is on the
  # repo alone, never owner/repo: the fallback marker records the project name with no
  # owner, so requiring one would withhold every merge there is.
  #
  # The clone's own "origin" is the authority, because the local directory name is the
  # captain's free choice (AGENTS.md section 6) and only incidentally equals the repo.
  # When no remote resolves - no clone, not a repo, or a local-only project with no
  # remote at all - fall back to the marker rather than withhold: silently hiding the
  # Merge because infrastructure is ABSENT would be the very regression this composer
  # exists to fix, whereas a resolved remote that disagrees is a PROVEN mismatch and is
  # correctly withheld. Unverifiable either way (no remote AND no marker) means no
  # Merge; the card still carries the link, so the captain loses only the one click.
  pr_ok=""
  if [ -n "$pr" ]; then
    pr_name=$(pr_repo "$pr")
    if [ -n "$pr_name" ]; then
      project_remote_repo "$project"      # answers in REMOTE_REPO_OUT; see its header
      remote_name=$REMOTE_REPO_OUT
      if [ -n "$remote_name" ]; then
        if [ "$pr_name" = "$remote_name" ]; then pr_ok=$pr; fi
      elif [ -n "$repo" ] && [ "$pr_name" = "$repo" ]; then
        pr_ok=$pr
      fi
    fi
  fi

  # Both of these describe a RUNNING crew, so they are only read when one exists.
  # fm-teardown removes the status log with the meta, and a status line is a wake
  # EVENT rather than current-state truth, so it must never outlive its crew here.
  base_branch=""
  last=""
  if [ -n "$live" ]; then
    base_branch=$(meta_get "$meta" base_branch)
    last=$(status_last "$id")
  fi

  # Classify by urgency, preserving decision > action > fyi: a live crew's open
  # question outranks a captain hold, which outranks a plain ready PR, which outranks
  # in-progress work. A captain hold WITH a verified PR is an action - there is a
  # concrete thing to do, review and merge it - while one without is a question to
  # answer, which is how firstmate actually writes hold reasons.
  #
  # NOT-READY work is never offered for merge, however ready the url looks - whether the
  # record is an active non-captain hold or a "blocked-by: <id>" dependency. A Merge
  # button captioned by the very reason the work is blocked is a contradiction, and the
  # board must never invite the captain to merge work firstmate has recorded as
  # not-ready: acting on it would land a change over the fleet's own objection, and
  # merging is irreversible. Such a task falls through to the fyi branch (or, when the
  # captain is also holding it, stays the question that hold already poses), which
  # reports why it is sitting still rather than offering a button.
  kind=fyi
  detail=""
  case "$last" in
    needs-decision:*)
      kind=decision
      detail=${last#needs-decision:}
      detail=${detail# }
      ;;
    *)
      if [ "$captain_held" = yes ]; then
        if [ -n "$pr_ok" ] && [ "$not_ready" != yes ]; then kind=action; else kind=decision; fi
      elif [ -n "$pr_ok" ] && [ "$not_ready" != yes ]; then
        kind=action
      fi
      ;;
  esac

  # Plain, non-jargony baseline text (firstmate rewrites these richly on push); the
  # human title comes from the backlog one-liner, never the internal task id. A
  # captain hold's "(hold: ...)" prose is already written for a human, and is exactly
  # the "why this is waiting on you" the card needs, so it IS the body. Only a captain
  # hold can reach the action branch still holding, so the reason it captions a Merge
  # with is always the captain's own "review and merge this", never a blocker.
  case "$kind" in
    decision)
      title=${title:-A decision is waiting}
      if [ -n "$detail" ]; then
        body=$detail
      else
        body=${hold_reason:-This needs your decision.}
      fi
      options='[]'
      ;;
    action)
      title=${title:-Work is ready for your review}
      body=${hold_reason:-Ready for your review.}
      options='[{"label":"Merge","value":"merge"},{"label":"Hold","value":"hold"}]'
      ;;
    *)
      title=${title:-Work in progress}
      if [ -n "$last" ]; then
        note=${last#*: }          # drop a leading "<verb>: " status prefix
        body=${note:-Work is underway.}
      else
        # No running crew to report a phase. A non-captain hold (external, parked,
        # future) still explains why this is sitting still, which beats saying
        # nothing; an unheld task with no crew has only the plain fallback.
        body=${hold_reason:-Work is underway.}
      fi
      options='[]'
      ;;
  esac

  title=$(clip "$title" 500)
  body=$(append_pr "$body" "$pr" 19000)

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
     }' >> "$ITEMS_JSONL" || { echo "fm-logbook-compose: failed to compose item $id" >&2; return 1; }
  return 0
}

# --- items: one card per task the captain could need to act on ---------------
backlog_parse || exit 1

for rec in "$BL_DIR"/*; do
  [ -f "$rec" ] || continue
  compose_item "$(basename "$rec")" || exit 1
done

# A live crew whose task is not in the backlog at all still gets a card, so a
# bookkeeping gap can never hide running work. This is the ONLY case where runtime
# state adds an item rather than enriching one.
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  logbook_valid_id "$id" || continue
  [ -f "$BL_DIR/$id" ] && continue
  compose_item "$id" || exit 1
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
