#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
# With --merge-policy, prints ONE word instead: firstmate|captain.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#   - <name> [<mode> +captain-merge] - <desc> ...      -> <mode> off, merge policy captain
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#   AGENTS.md section 7 is the single owner of authority exceptions, including
#   ask-user contract expansion and stronger captain boundaries.
# +captain-merge (orthogonal to BOTH) = firstmate must never merge this project's work
#   at all; the captain merges it personally. See bin/fm-merge-policy-lib.sh, which owns
#   what the policy MEANS and enforces it - this script only reads the registry.
#
# The three axes are genuinely independent, which is why the posture needs a flag of its
# own rather than a reading of the other two. "mode" says HOW a change reaches main, and
# every one of its values ends in a merge; "yolo" says WHO decides, among the approvals
# firstmate is permitted to make. Neither says whether firstmate may merge at all. And a
# prohibition cannot be expressed as a yolo setting, because yolo is a relaxation: a
# +captain-merge project stays forbidden however yolo is set.
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate. The merge policy defaults the other
# way round from the gate's perspective - to "firstmate", the behavior every project had
# before the flag existed - so adding the flag changes nothing for a project that does not
# carry it, and no project becomes unmergeable by accident.
#
# A bracket token past the first position that is neither posture flag warns to stderr
# too. A typo in the FIRST position is already caught as an unknown mode, but
# "[direct-PR +captainmerge]" parses cleanly as an unflagged project - so the one flag
# whose whole point is a prohibition would be the one that goes silently missing. The
# check is not limited to "+"-prefixed tokens, because dropping the "+" entirely
# ("[direct-PR captain-merge]") reaches the same silent-prohibition failure by an easier
# route: the first position is the mode and every later one is a posture flag, so there is
# no other legal token there to mistake a malformed one for. A malformed token is REPORTED
# and never honored - a prohibition guessed at from a typo would be its own failure - so
# stdout stays exactly as it was: an unrecognized token is a diagnostic, not a failure,
# and callers that interpolate or string-compare this output must not see it.
# Usage: fm-project-mode.sh [--raw] <project-name> [--merge-policy]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
if [ "${1:-}" = "--raw" ]; then
  RAW=1
  shift
fi
NAME=${1:?usage: fm-project-mode.sh [--raw] <project-name> [--merge-policy]}
QUERY=${2:-}
case "$QUERY" in
  ''|--merge-policy) ;;
  *) echo "usage: fm-project-mode.sh [--raw] <project-name> [--merge-policy]" >&2; exit 2 ;;
esac

# emit: the single stdout point, so every fallback below answers the SAME question the
# caller asked. A fallback that printed the default mode line while --merge-policy was
# asked for would hand the merge gate the word "no-mistakes" to test against
# "firstmate"/"captain" - a mismatch that reads as neither, silently.
emit() {
  case "$QUERY" in
    --merge-policy) echo "$merge" ;;
    *) echo "$mode $yolo" ;;
  esac
}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  mode=no-mistakes; yolo=off; merge=firstmate
  emit
  exit 0
fi

# awk emits "<mode> <yolo> <merge> [<unrecognized token>...]" (one line) or nothing if the
# project is absent. Unrecognized posture tokens ride along so the caller can report them
# without awk deciding what they mean.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; merge="firstmate"; bad="";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo" && a[1] != "+captain-merge") mode = a[1];
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") yolo="on";
        else if (a[j]=="+captain-merge") merge="captain";
        else if (j > 1 && a[j] != "") bad = bad " " a[j];
      }
    }
    print mode, yolo, merge bad; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  mode=no-mistakes; yolo=off; merge=firstmate
  emit
  exit 0
fi

# shellcheck disable=SC2086
set -- $parsed
mode=$1
yolo=$2
merge=$3
shift 3
if [ "$#" -gt 0 ]; then
  echo "warn: unrecognized posture flag(s) \"$*\" for $NAME; only +yolo and +captain-merge are posture flags" >&2
fi
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
case "$merge" in firstmate|captain) ;; *) merge=firstmate ;; esac
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
emit
