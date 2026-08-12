#!/usr/bin/env bash
# Render the primary-harness supervision operating block for session start and
# the short repair line used by guards and turn-end hooks.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$REPO_ROOT}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DOC_DIR="$REPO_ROOT/docs/supervision-protocols"

HARNESS=
READ_ONLY=0
AFK=0
X_MODE=0
REPAIR_LINE=0
QUEUE_PENDING=0

usage() {
  cat <<'EOF'
Usage: fm-supervision-instructions.sh [--harness <name>] [--read-only 0|1] [--afk 0|1] [--x-mode 0|1] [--repair-line] [--queue-pending 0|1]

Print the current primary harness's supervision operating instructions.
With --repair-line, print one concise repair instruction for guard and hook messages.

Watcher cadence is carried by config/x-mode.env plus any config/check-cadence.d/*.env
an out-of-tree feature installed; they are sourced smallest-interval-last so the
snappiest cadence wins.
EOF
}

bool_value() {
  case "$1" in
    1|true|TRUE|yes|YES) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness)
      [ "$#" -gt 1 ] || { echo "error: --harness requires a value" >&2; exit 2; }
      HARNESS=$2
      shift 2
      ;;
    --read-only)
      [ "$#" -gt 1 ] || { echo "error: --read-only requires 0 or 1" >&2; exit 2; }
      READ_ONLY=$(bool_value "$2")
      shift 2
      ;;
    --afk)
      [ "$#" -gt 1 ] || { echo "error: --afk requires 0 or 1" >&2; exit 2; }
      AFK=$(bool_value "$2")
      shift 2
      ;;
    --x-mode)
      [ "$#" -gt 1 ] || { echo "error: --x-mode requires 0 or 1" >&2; exit 2; }
      X_MODE=$(bool_value "$2")
      shift 2
      ;;
    --queue-pending)
      [ "$#" -gt 1 ] || { echo "error: --queue-pending requires 0 or 1" >&2; exit 2; }
      QUEUE_PENDING=$(bool_value "$2")
      shift 2
      ;;
    --repair-line)
      REPAIR_LINE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$HARNESS" ]; then
  HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
fi

case "$HARNESS" in
  claude|codex|opencode|pi|grok) SNIPPET="$DOC_DIR/$HARNESS.md" ;;
  pi-signed) SNIPPET="$DOC_DIR/pi.md" ;;
  *) HARNESS=unknown; SNIPPET="$DOC_DIR/unknown.md" ;;
esac
[ -f "$SNIPPET" ] || SNIPPET="$DOC_DIR/unknown.md"

checkpoint_seconds=${FM_CODEX_WATCH_CHECKPOINT:-180}
pi_ext="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
pi_turnend_ext="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
x_mode_env="$CONFIG/x-mode.env"
# The extension seam for watcher cadence: any out-of-tree feature that needs a
# faster (or slower) poll drops its own generated `export FM_CHECK_INTERVAL=<n>`
# file here instead of this file learning that feature's name. Local and
# gitignored like the rest of config/, and carried into the arm command by the
# same allowlist bin/fm-arm-command-policy.mjs applies to x-mode.env.
cadence_dir="$CONFIG/check-cadence.d"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

x_mode_env_sh=$(shell_quote "$x_mode_env")

if [ "$X_MODE" -eq 0 ] && [ -f "$x_mode_env" ]; then
  X_MODE=1
fi

# The interval a carrier declares, or 0 when it declares none. Read by PATTERN,
# never by sourcing: rendering an operating block must not execute config.
cadence_interval() {  # <file>
  local n
  n=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}FM_CHECK_INTERVAL=\([0-9]\{1,\}\).*$/\2/p' "$1" 2>/dev/null | tail -1)
  printf '%s' "${n:-0}"
}

# Every active cadence carrier, ordered so the SMALLEST interval is sourced LAST.
# They all export the same variable, so last-sourced wins, and the snappiest
# cadence is the one a home running several of them must inherit - a board answer
# that waits on a slower feature's poll is the regression this ordering prevents.
# Ties and undeclared intervals fall back to reverse filename order, so the render
# is deterministic. Prints one absolute path per line.
cadence_files() {
  local f
  {
    # X mode is included whenever the caller declared it active, even if bootstrap
    # has not written the file yet: the clause is `[ -f X ] && . X`, so carrying it
    # for a not-yet-generated carrier is a no-op, while dropping it would silently
    # lose the cadence of a home that generates it between render and arm.
    [ "$X_MODE" -eq 1 ] || [ -f "$x_mode_env" ] \
      && printf '%s\t%s\n' "$(cadence_interval "$x_mode_env")" "$x_mode_env"
    if [ -d "$cadence_dir" ]; then
      for f in "$cadence_dir"/*.env; do
        [ -f "$f" ] || continue
        printf '%s\t%s\n' "$(cadence_interval "$f")" "$f"
      done
    fi
    return 0
  } | LC_ALL=C sort -t"$(printf '\t')" -k1,1nr -k2,2r | cut -f2-
}

# The shell prelude an arm command carries so the watcher process it launches
# inherits the cadence. Each clause is the `[ -f X ] && . X;` shape
# bin/fm-arm-command-policy.mjs recognizes; empty when no carrier is active.
cadence_prelude() {
  local f out=
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    out="${out}[ -f $(shell_quote "$f") ] && . $(shell_quote "$f"); "
  done <<EOF
$(cadence_files)
EOF
  printf '%s' "$out"
}

cadence_prelude_sh=$(cadence_prelude)

render_snippet() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    # Every replacement is DOUBLE-QUOTED. Bash 5.2 enables patsub_replacement by
    # default, which expands an unquoted `&` in the replacement to the matched
    # text - so the `&&` in the cadence prelude would come back out as the
    # placeholder itself and emit a corrupt arm command.
    line=${line//__FM_PI_EXT__/"$pi_ext"}
    line=${line//__FM_PI_TURNEND_EXT__/"$pi_turnend_ext"}
    line=${line//__FM_CADENCE_PRELUDE__/"$cadence_prelude_sh"}
    line=${line//__FM_X_MODE_ENV_SH__/"$x_mode_env_sh"}
    line=${line//__FM_X_MODE_ENV__/"$x_mode_env"}
    printf '%s\n' "$line"
  done < "$SNIPPET"
}

repair_line() {
  if [ "$READ_ONLY" -eq 1 ]; then
    printf '%s\n' 'Watcher repair belongs to the session holding the fleet lock; do not drain, arm, or repair from this read-only session.'
    return 0
  fi
  if [ "$AFK" -eq 1 ]; then
    printf '%s\n' 'Away mode owns watcher supervision; load /afk and ensure the daemon is running instead of starting normal supervision directly.'
    return 0
  fi

  prefix=
  if [ "$QUEUE_PENDING" -eq 1 ]; then
    prefix='After draining queued wakes, '
  fi
  local f cadence_list=
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    cadence_list="${cadence_list:+$cadence_list then }$(shell_quote "$f")"
  done <<EOF
$(cadence_files)
EOF
  if [ -n "$cadence_list" ]; then
    prefix="${prefix}source ${cadence_list} first, then "
  fi

  case "$HARNESS" in
    claude)
      printf '%s%s\n' "$prefix" 'watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn.'
      ;;
    codex)
      printf '%s%s%s%s\n' "$prefix" 'repair missing watcher supervision with a foreground checkpoint: bin/fm-watch-checkpoint.sh --seconds ' "$checkpoint_seconds" '.'
      ;;
    pi|pi-signed)
      printf '%s%s%s%s%s%s\n' "$prefix" 'repair a missing or failed watcher cycle with the Pi tool fm_watch_arm_pi, or restart Pi with -e ' "$pi_turnend_ext" ' -e ' "$pi_ext" ' if the extensions are not loaded.'
      ;;
    opencode)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision by letting the OpenCode TUI plugin arm after idle; use bin/fm-watch-arm.sh only as a manual recovery probe if the plugin reports failure.'
      ;;
    grok)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision with bin/fm-watch-arm.sh as its own Grok tracked background task, never shell &.'
      ;;
    *)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision according to the session-start block for this harness; do not use shell &.'
      ;;
  esac
}

ordinary_wake_line() {
  case "$HARNESS" in
    claude)
      printf '%s\n' '- Ordinary wake: the Stop-owned auto-arm (bin/fm-claude-stop-autoarm.sh) already owns watcher continuity; drain and handle the wake, and do not arm another cycle yourself.'
      ;;
    codex)
      printf '%s\n' '- Ordinary wake: take the next foreground bin/fm-watch-checkpoint.sh checkpoint as directed below.'
      ;;
    pi|pi-signed)
      printf '%s\n' '- Ordinary wake: the Pi extension already owns watcher continuity; do not arm another cycle.'
      ;;
    opencode)
      printf '%s\n' '- Ordinary wake: the OpenCode TUI plugin already owns watcher continuity; do not arm manually.'
      ;;
    grok)
      printf '%s\n' '- Ordinary wake: re-arm exactly one bin/fm-watch-arm.sh Grok tracked background task as directed below.'
      ;;
    *)
      printf '%s\n' '- Ordinary wake: follow the continuation in the harness protocol below; do not use shell &.'
      ;;
  esac
}

if [ "$REPAIR_LINE" -eq 1 ]; then
  repair_line
  exit 0
fi

RULE='================================================================================'
printf '%s\n' "$RULE"
printf 'SUPERVISION OPERATING INSTRUCTIONS - primary harness: %s\n' "$HARNESS"
printf '%s\n' "$RULE"
printf 'Current state:\n'
if [ "$READ_ONLY" -eq 1 ]; then
  printf '%s\n' '- Lock: read-only; do not drain, arm, spawn, steer, merge, or repair fleet state here.'
else
  printf '%s\n' '- Lock: held by this session; this session owns normal supervision unless away mode says otherwise.'
fi
if [ "$AFK" -eq 1 ]; then
  printf '%s\n' '- Away mode: active; load /afk and keep normal harness supervision paused while the daemon owns the watcher.'
else
  printf '%s\n' '- Away mode: inactive.'
fi
if [ "$X_MODE" -eq 1 ]; then
  printf '%s%s%s\n' '- X mode: active; source ' "$x_mode_env" ' before launching any watcher process so the 30s cadence is inherited.'
else
  printf '%s\n' '- X mode: inactive; use the default watcher cadence.'
fi
cadence_extra=$(cadence_files | grep -Fxv "$x_mode_env" || true)
if [ -n "$cadence_extra" ]; then
  printf '%s\n' '- Watcher cadence: extra carriers active; source them in this order before launching any watcher process, so the snappiest interval is the one inherited:'
  printf '%s\n' "$cadence_extra" | sed 's/^/    /'
fi
ordinary_wake_line
printf '\n'
render_snippet
printf '\n'
