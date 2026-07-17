# shellcheck shell=bash
# Shared read of one item line out of THIS home's durable backlog (AGENTS.md
# section 10), for the two scripts that read that file directly rather than through
# tasks-axi: bin/fm-pr-check.sh's durable PR record and bin/fm-pr-merge.sh's no-meta
# bookkeeping.
# Usage: . bin/fm-backlog-lib.sh
#
# One contract, one owner. Both callers ask the same two questions of the same line,
# and both answers govern writes - a close, a clone refresh, and whether a skipped
# record is reported. Two parses that drifted apart would not disagree loudly; they
# would each fall silent on the item the other still sees, which is exactly the
# failure both callers exist to prevent.
#
# The file is read directly, for the same reason bin/fm-logbook-compose.sh reads it
# directly: it then serves a backlog hand-maintained under
# config/backlog-backend=manual exactly as it serves the default backend, and needs no
# tool on PATH. ("tasks-axi show" would not help anyway - it reports the marker's raw
# value, trailing content and all.)
#
# This file is sourced, never executed. It defines:
#   fm_backlog_item_of <backlog-file> <id>  - "<section>\t<project>" for the item the
#                                             backlog carries under <id>, or nothing at
#                                             all when it carries no such item

# fm_backlog_item_of <backlog-file> <id>: <id>'s durable record as
# "<section>\t<project>", or nothing at all when the backlog does not carry the id as an
# item of its own.
#
# One scan, because a caller that closes the item has exactly one moment where both
# answers still exist: closing is what moves the item, and done_keep can then prune it
# out of the file entirely. Two questions of that one line:
#
#   <section>  the "## " heading the item sits under, normalized as
#              bin/fm-logbook-compose.sh's backlog_parse normalizes it, and empty under a
#              heading that is not a task section (where compose reads no item either).
#              "done" is the one value that means nothing is owed: compose_item returns
#              early on a Done item, so no card can compose from one - nothing to close,
#              and no card left to lose a PR link it was never given. This is the same
#              question "code: NOT_FOUND" answers for the tasks-axi path - asked of the
#              file, so a backend that is never consulted can answer it too.
#   <project>  the bare project name from the item's "(repo: <name>)" marker, or empty
#              when the item records no project, or one that cannot address a clone.
#              Deliberately NOT gated on section: fm-pr-merge.sh's clone refresh is owed
#              for the merge that just landed, whatever shape the heading around the item
#              is in.
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
# holds it to (no whitespace, "/", "\", or ".."), so a marker hand-edited into something
# that is not a project name stays a plain component: it can address nothing but a
# directory sitting directly under projects/, and cannot traverse out of the dir a caller
# joins it onto. That bound is all this rule gives - a name that cannot escape. It is no
# evidence that a clone is there, or that a directory that IS there is one; a caller that
# hands the joined path to a write proves that itself, on the path it built.
fm_backlog_item_of() {
  local backlog=$1 id=$2 line rest item repo section=""
  [ -f "$backlog" ] || return 0
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
  done < "$backlog"
  return 0
}
