#!/usr/bin/env bash
# Evidence driver: runs the real bin/fm-teardown.sh against throwaway fixture homes
# built with the fixture helpers of tests/fm-teardown-retire-record.test.sh.
set -u
unset FM_HOME
W=/home/metoo/.no-mistakes/worktrees/5f97ed91bec6/01M2QADV2DSYRTHX599Y924792
HELPERS=$(mktemp)
{ sed -n '1,199p' "$W/tests/fm-teardown-retire-record.test.sh" | sed "s|^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"|. $W/tests/lib.sh|"
  sed -n '606,636p' "$W/tests/fm-teardown-retire-record.test.sh"; } > "$HELPERS"
. "$HELPERS"
rm -f "$HELPERS"
say() { printf '\n########## %s\n' "$*"; }
run() {  # <case> <id> [args...]
  local dir=$1; shift
  printf '\n$ bin/fm-teardown.sh %s\n' "$*"
  run_teardown "$dir" "$@" 2>&1 | sed "s|$dir|<case>|g; s|$W|<repo>|g"
  printf '[exit %s]\n' "${PIPESTATUS[0]}"
}
snapshot() {  # <case>
  local dir=$1
  printf -- '--- state/ files: %s\n' "$(find "$dir/home/state" -type f | wc -l)"
  (cd "$dir/home/state" && find . -type f | sort | sed 's|^\./||' | paste -sd' ' | fold -s -w 150)
  printf -- '--- status-presentation rows: %s\n' "$(cut -f1 "$dir/home/state/.status-presentation-cursor" | paste -sd, )"
  printf -- '--- working copy sentinel: %s\n' "$(cat "$dir/pool/1/repo/sentinel")"
  printf -- '--- pool record cksum: %s\n' "$(cksum < "$dir/pool/treehouse-state.json")"
  printf -- '--- treehouse calls: %s   endpoint kills: %s\n' \
    "$(grep -c '^treehouse' "$dir/runtime.log")" "$(grep -c 'kill-window' "$dir/runtime.log")"
}

say "SCENARIO A: slot re-leased. old-r1 and new-r1 both name pool slot 1; the pool leases it to new-r1's recorded claim"
A=$(make_superseded_case demo-released)
printf 'pool: %s\n' "$(sed "s|$A|<case>|g" "$A/pool/treehouse-state.json")"
grep -H '^lease_holder=' "$A/home/state/old-r1.meta" "$A/home/state/new-r1.meta" | sed "s|$A|<case>|g"
snapshot "$A"
say "A1: ordinary teardown of the superseded record refuses, with and without --force"
run "$A" old-r1
run "$A" old-r1 --force
say "A2: --retire-record refuses the record that still owns the slot"
run "$A" new-r1 --retire-record
say "A3: --retire-record --dry-run on the superseded record changes nothing"
run "$A" old-r1 --retire-record --dry-run
snapshot "$A"
say "A4: --retire-record retires only old-r1's record"
run "$A" old-r1 --retire-record
snapshot "$A"

say "SCENARIO B: pre-lease pair. stale-r1 and holder-r1 name one working copy, neither carries a recorded claim"
B=$(make_claimless_pair_case demo-claimless)
printf 'pool: %s\n' "$(sed "s|$B|<case>|g" "$B/pool/treehouse-state.json")"
snapshot "$B"
say "B1: ordinary teardown refuses BOTH records, with and without --force"
run "$B" stale-r1
run "$B" stale-r1 --force
run "$B" holder-r1
say "B2: --retire-record alone refuses an unproven record"
run "$B" stale-r1 --retire-record
say "B3: --unproven-confirmed is valid only with --retire-record; --force never implies it"
run "$B" stale-r1 --unproven-confirmed
run "$B" stale-r1 --force --unproven-confirmed
run "$B" stale-r1 --retire-record --force
printf '\n(next command runs with FM_UNPROVEN_CONFIRMED=1 UNPROVEN_CONFIRMED=1 FM_FORCE=1 exported: no environment variable stands in for the flag)'
FM_UNPROVEN_CONFIRMED=1 UNPROVEN_CONFIRMED=1 FM_FORCE=1 run "$B" stale-r1 --retire-record
say "B4: the deliberate acknowledgement, dry run first"
run "$B" stale-r1 --retire-record --unproven-confirmed --dry-run
snapshot "$B"
say "B5: the deliberate acknowledgement, real run"
run "$B" stale-r1 --retire-record --unproven-confirmed
snapshot "$B"
