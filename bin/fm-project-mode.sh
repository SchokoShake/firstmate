#!/usr/bin/env bash
# Resolve a project's delivery mode, yolo flag, and merge policy from the
# data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
# With --merge-policy, prints ONE word instead: firstmate|captain.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#   - <name> [<mode> +captain-merge] - <desc> ...      -> <mode> off, merge policy captain
#
# mode = how a finished change reaches main:
#   no-mistakes  full pipeline -> PR -> captain merge (default)
#   direct-PR    push + PR via gh-axi, no pipeline -> captain merge
#   local-only   local branch, no remote/PR -> firstmate review -> captain approve -> local merge
# yolo (orthogonal) = when on, firstmate makes approval decisions itself (PR merges,
#   ask-user findings, local-only merge approval) without checking the captain - except
#   anything destructive/irreversible/security-sensitive, which still escalates.
# +captain-merge (orthogonal to BOTH) = firstmate must never merge this project's work
#   at all; the captain merges it personally. See bin/fm-merge-policy-lib.sh, which owns
#   what the policy MEANS and enforces it - this script only reads the registry.
#
# The three axes are genuinely independent, which is why the posture needs a flag of its
# own rather than a reading of the other two. "mode" says HOW a change reaches main, and
# all three of its values end in a merge; "yolo" says WHO decides, among the approvals
# firstmate is permitted to make. Neither says whether firstmate may merge at all. And a
# prohibition cannot be expressed as a yolo setting, because yolo is a relaxation: a
# +captain-merge project stays forbidden however yolo is set.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate. The merge policy defaults the other
# way round from the gate's perspective - to "firstmate", the behavior every project had
# before the flag existed - so adding the flag changes nothing for a project that does not
# carry it, and no project becomes unmergeable by accident.
# Usage: fm-project-mode.sh <project-name> [--merge-policy]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
NAME=${1:?usage: fm-project-mode.sh <project-name> [--merge-policy]}
QUERY=${2:-}
case "$QUERY" in
  ''|--merge-policy) ;;
  *) echo "usage: fm-project-mode.sh <project-name> [--merge-policy]" >&2; exit 2 ;;
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
  exit 0
}

mode=no-mistakes
yolo=off
merge=firstmate

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  emit
fi

# awk emits "<mode> <yolo> <merge>" (one line) or nothing if the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; merge="firstmate";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo" && a[1] != "+captain-merge") mode = a[1];
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") yolo="on";
        if (a[j]=="+captain-merge") merge="captain";
      }
    }
    print mode, yolo, merge; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  emit
fi

mode=${parsed%% *}
rest=${parsed#* }
yolo=${rest%% *}
merge=${rest##* }
case "$mode" in
  no-mistakes|direct-PR|local-only) ;;
  # A typo in the mode says nothing about the posture flags, and the merge policy is the
  # one axis where guessing costs something irreversible: resetting it here would hand a
  # "[direct-PRR +captain-merge]" line back as mergeable. So the reset stays exactly as
  # wide as it was - mode and yolo - and never reaches a prohibition the line does state.
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
case "$merge" in firstmate|captain) ;; *) merge=firstmate ;; esac
emit
