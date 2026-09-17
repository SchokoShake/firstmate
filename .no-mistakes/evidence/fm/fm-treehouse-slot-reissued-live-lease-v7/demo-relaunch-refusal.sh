#!/usr/bin/env bash
# Evidence driver: runs the real bin/fm-control.sh relaunch against throwaway fixture
# homes built with the fixture helpers of tests/fm-control-relaunch.test.sh.
set -u
unset FM_HOME
W=/home/metoo/.no-mistakes/worktrees/5f97ed91bec6/01M2QADV2DSYRTHX599Y924792
HELPERS=$(mktemp)
sed -n '1,273p' "$W/tests/fm-control-relaunch.test.sh" | sed "s|^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"|. $W/tests/lib.sh|" > "$HELPERS"
. "$HELPERS"
rm -f "$HELPERS"
say() { printf '\n########## %s\n' "$*"; }
show() {  # <case> <id>
  local dir=$1 id=$2
  printf -- '--- agent in endpoint: %s   keys sent: %s bytes   journal: %s\n' "$(cat "$dir/fake/command")" \
    "$(cat "$dir/fake/literal" "$dir/fake/keys" | wc -c)" \
    "$([ -e "$dir/home/state/$id.control-relaunch" ] && echo present || echo none)"
  printf -- '--- record cksum: %s   brief cksum: %s\n' "$(cksum < "$dir/home/state/$id.meta")" "$(cksum < "$dir/home/data/$id/brief.md")"
}
relaunch() {  # <case> <id>
  local dir=$1 id=$2
  printf '\n$ bin/fm-control.sh %s relaunch --note "x"\n' "$id"
  run_control "$dir" "$id" relaunch --note "x" | sed "s|$dir|<case>|g; s|$W|<repo>|g"
  printf '[exit %s]\n' "${PIPESTATUS[0]}"
}

say "R1: a record with no recorded lease claim (every pre-lease record) reads unproven"
D=$(new_case ev-noclaim evd47); add_ship_task "$D" evd47 claude; write_ship_record "$D" evd47 claude
show "$D" evd47; relaunch "$D" evd47; show "$D" evd47

say "R2: a claimed record whose slot the pool now leases to another record's claim reads released"
D=$(new_case ev-released evd48); add_ship_task "$D" evd49 claude
write_ship_record "$D" evd48 claude "lease_holder=$(ship_claim evd48)"
show "$D" evd48; relaunch "$D" evd48; show "$D" evd48

say "R3: a record the pool leases to its own claim still relaunches"
D=$(new_case ev-own evd50); add_ship_task "$D" evd50 claude
show "$D" evd50; relaunch "$D" evd50
printf -- '--- agent in endpoint: %s   journal: %s\n' "$(cat "$D/fake/command")" \
  "$([ -e "$D/home/state/evd50.control-relaunch" ] && echo present || echo none)"
