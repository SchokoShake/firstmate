#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the code-identity rules that decide whether a no-mistakes run
# belongs to a given worktree. fm-teardown.sh's pre-teardown run abort (see its
# "Fix 1" header comment) uses the local-history rule,
# fm_nm_head_matches_worktree. fm-crew-state.sh's read-only current-state report
# uses fm_nm_status_run_matches_worktree, which extends that rule with
# no-mistakes' own push provenance so a live run whose head the pipeline moved
# still binds. Getting this wrong in either direction is unsafe: a false
# negative hides a genuinely parked run, and a false positive lets teardown act
# on a run it does not own, or lets a report present another run's outcome.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# Scalar value at an exact dotted key path in captured TOON output $1, such as
# run.head or branch_sync.pipeline.submitted_head. Nesting is read from
# indentation, so a same-named key in another object (run.head versus
# branch_sync.local.head) never answers; tabular-array headers and rows are not
# keys. Values keep their TOON quoting (see fm_nm_strip_quotes).
fm_nm_path_field() {  # <toon-output> <dotted-path>
  printf '%s\n' "$1" | awk -v want="$2" '
    /^ *[A-Za-z_][A-Za-z0-9_]*:$/ || /^ *[A-Za-z_][A-Za-z0-9_]*: / {
      indent = match($0, /[^ ]/) - 1
      rest = substr($0, indent + 1)
      key = substr(rest, 1, index(rest, ":") - 1)
      value = substr(rest, length(key) + 2)
      sub(/^ +/, "", value)
      sub(/ +$/, "", value)
      while (depth > 0 && indents[depth] >= indent) depth--
      path = key
      for (i = depth; i >= 1; i--) path = keys[i] "." path
      if (value == "") {
        depth++
        indents[depth] = indent
        keys[depth] = key
      } else if (path == want) {
        print value
        exit
      }
    }'
}

# 0 if run head $2 matches worktree $1's code identity by local history alone:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# 0 if the run in captured `axi status` output $2 belongs to worktree $1's
# current code. The run's head must be present, and then either:
#   - it passes fm_nm_head_matches_worktree, or
#   - no-mistakes' push provenance for that same run (branch_sync.pipeline, whose
#     run id equals run.id) names the worktree HEAD as the commit the run was
#     submitted from. While the pipeline owns the branch, its review fixes and
#     rebase live only in the no-mistakes gate until they are pushed and synced,
#     so a live run's head often neither resolves in the worktree nor descends
#     from its HEAD; the submitted head is what binds it. Provenance naming
#     another submission, or recorded for another run, binds nothing.
# Branch match is a precondition (caller).
fm_nm_status_run_matches_worktree() {  # <worktree> <axi-status-output>
  local wt=$1 out=$2 run_head run_id sync_run submitted local_full submitted_full
  run_head=$(fm_nm_strip_quotes "$(fm_nm_path_field "$out" run.head)")
  [ -n "$run_head" ] || return 1
  fm_nm_head_matches_worktree "$wt" "$run_head" && return 0
  run_id=$(fm_nm_strip_quotes "$(fm_nm_path_field "$out" run.id)")
  sync_run=$(fm_nm_strip_quotes "$(fm_nm_path_field "$out" branch_sync.pipeline.run)")
  [ -n "$run_id" ] && [ "$sync_run" = "$run_id" ] || return 1
  submitted=$(fm_nm_strip_quotes "$(fm_nm_path_field "$out" branch_sync.pipeline.submitted_head)")
  [ -n "$submitted" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  submitted_full=$(git -C "$wt" rev-parse --verify "${submitted}^{commit}" 2>/dev/null) || return 1
  [ "$submitted_full" = "$local_full" ]
}
