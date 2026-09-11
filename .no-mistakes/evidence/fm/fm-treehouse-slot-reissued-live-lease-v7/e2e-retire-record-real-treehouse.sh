#!/usr/bin/env bash
# End-to-end demonstration for fm-treehouse-slot-reissued-live-lease-v7.
#
# Uses the REAL treehouse binary against an isolated pool under a temp root, so
# the ownership verdict reads treehouse's genuine treehouse-state.json. Builds
# the live defect shape (two task records naming one pool slot, the pool
# leasing that slot to the later record, the later record holding uncommitted
# work in it), then drives bin/fm-teardown.sh from the change under test and,
# for contrast, from the base commit.
set -u
ROOT=${ROOT:?}
BASE_SHA=${BASE_SHA:?}
SCEN=$(mktemp -d /tmp/fm-retire-e2e.XXXX)
OLD_LABEL=fm-task:old-r1:l1788765990.150863.30112
NEW_LABEL=fm-task:new-r1:l1789026480.244338.3761
STATE=$SCEN/home/state

step() { printf '\n\n===== %s =====\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; "$@"; printf '[exit %d]\n' "$?"; }
th() { HOME=$SCEN/fakehome treehouse "$@"; }

step "1. A project repo with its own treehouse pool under $SCEN/th"
mkdir -p "$SCEN/fakehome" "$SCEN/project" "$STATE" "$SCEN/home/data" "$SCEN/home/config" "$SCEN/fakebin"
cd "$SCEN/project" || exit 1
git init -q -b main .
printf 'base\n' > README.md
git -c user.name=t -c user.email=t@example.invalid add README.md
git -c user.name=t -c user.email=t@example.invalid commit -qm initial
printf 'max_trees = 4\nroot = "%s"\n' "$SCEN/th" > treehouse.toml
cat treehouse.toml

step "2. The finished task old-r1 held slot 1 under a durable lease; its lease was released without its record being retired"
P=$(th get --lease --lease-holder "$OLD_LABEL" 2>/dev/null)
echo "old-r1 leased: $P"
run th status
run th return --force "$P"

step "3. The pool re-leases the same slot to the next spawn, new-r1, which starts uncommitted work in it"
P2=$(th get --lease --lease-holder "$NEW_LABEL" 2>/dev/null)
echo "new-r1 leased: $P2"
[ "$P2" = "$P" ] && echo "same slot reissued: yes" || echo "same slot reissued: NO"
POOL=$(dirname "$(dirname "$P")")
printf 'live uncommitted work of new-r1\n' > "$P/live-work.txt"
printf 'edited by new-r1, not yet committed\n' >> "$P/README.md"
run th status
printf '\n$ cat %s/treehouse-state.json\n' "$POOL"; cat "$POOL/treehouse-state.json"

step "4. Both firstmate records name that slot; every kind of per-task state record exists for both"
write_record() {  # <id> <label>
  local id=$1 label=$2
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$P" \
    "project=$SCEN/project" "harness=claude" "kind=ship" "tasktmp=$SCEN/tasktmp-$id" \
    "spawn_gen=s1788765996.150863.30112" "mode=direct-PR" "yolo=off" \
    "lease_holder=$label" > "$STATE/$id.meta"
}
populate() {  # <id>
  local id=$1 marker gen
  printf 'done: PR merged\n' > "$STATE/$id.status"
  : > "$STATE/$id.turn-ended"
  printf 'version=4\noffset=0\nident=1:1\n' > "$STATE/.$id.open-decisions-cursor"
  for marker in hash count stale paused paused-rechecked paused-resurfaced; do
    printf 'x\n' > "$STATE/.$marker-firstmate_fm-$id"
  done
  printf 'x\n' > "$STATE/.seen-${id}_status"
  printf 'x\n' > "$STATE/.seen-${id}_turn-ended"
  printf 'x\n' > "$STATE/.hb-surfaced-$id"
  printf 'x\n' > "$STATE/.subsuper-paused-$id"
  mkdir -p "$STATE/.pr-check-quarantine"; chmod 700 "$STATE/.pr-check-quarantine"
  (umask 077 && printf 'neutralized\n' > "$STATE/.pr-check-quarantine/$id.diagnostic.ambiguous")
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$id") || echo "could not arm busy state for $id"
  printf 'busy_gen=%s\n' "$gen" >> "$STATE/$id.meta"
}
write_record old-r1 "$OLD_LABEL"
printf 'pr=https://github.com/example/repo/pull/829\n' >> "$STATE/old-r1.meta"
write_record new-r1 "$NEW_LABEL"
populate old-r1
populate new-r1
printf 'old-r1\t1:1\t0\nnew-r1\t1:2\t0\n' > "$STATE/.status-presentation-cursor"
run cat "$STATE/old-r1.meta"
printf '\n$ ls -A %s\n' "$STATE"; ls -A "$STATE" | sort

# Logging fakes: tmux answers as an endpoint with no such window; treehouse
# logs every call and then runs the real binary, so any pool touch by
# teardown is both recorded and real.
cat > "$SCEN/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "${FM_RUNTIME_LOG:?}"
case "${1:-}" in list-windows) printf '%s\n' unrelated-window ;; esac
exit 0
SH
cat > "$SCEN/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf 'treehouse %s\n' "\$*" >> "\${FM_RUNTIME_LOG:?}"
HOME=$SCEN/fakehome exec $(command -v treehouse) "\$@"
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCEN/fakebin/no-mistakes"
chmod +x "$SCEN/fakebin"/*
: > "$SCEN/runtime.log"

fingerprint() {  # <out-file>
  {
    printf 'HEAD %s\n' "$(git -C "$P" rev-parse HEAD)"
    printf 'git status --porcelain:\n'; git -C "$P" status --porcelain
    printf 'files:\n'; (cd "$P" && find . -type f -not -path './.git/*' | sort | xargs sha256sum)
    printf 'pool record: %s\n' "$(cksum < "$POOL/treehouse-state.json")"
  } > "$1"
}
teardown() {  # <root> <args...>
  local root=$1; shift
  FM_HOME="$SCEN/home" FM_ROOT_OVERRIDE="$root" FM_TEARDOWN_GUARD_DONE=1 FM_GATE_REFUSE_BYPASS=1 \
    FM_RUNTIME_LOG="$SCEN/runtime.log" PATH="$SCEN/fakebin:$PATH" \
    "$root/bin/fm-teardown.sh" "$@"
}

step "5. Working-copy and pool fingerprint before any teardown"
fingerprint "$SCEN/fp-before.txt"; cat "$SCEN/fp-before.txt"

step "6. CHANGE UNDER TEST: dry run of the record-only retirement of old-r1"
run teardown "$ROOT" old-r1 --retire-record --dry-run

step "7. CHANGE UNDER TEST: ordinary teardown of old-r1, plain and --force, must refuse"
run teardown "$ROOT" old-r1
run teardown "$ROOT" old-r1 --force

step "8. CHANGE UNDER TEST: retiring the record of the CURRENT holder new-r1 must refuse"
run teardown "$ROOT" new-r1 --retire-record --dry-run

step "9. CHANGE UNDER TEST: real record-only retirement of old-r1"
run teardown "$ROOT" old-r1 --retire-record

step "10. After: state/ holds only new-r1's records; working copy and pool are byte-identical"
printf '\n$ ls -A %s\n' "$STATE"; ls -A "$STATE" | sort
printf '\n$ cat %s/.status-presentation-cursor\n' "$STATE"; cat "$STATE/.status-presentation-cursor"
fingerprint "$SCEN/fp-after.txt"
printf '\n$ diff fp-before.txt fp-after.txt\n'; diff "$SCEN/fp-before.txt" "$SCEN/fp-after.txt" && echo "(no difference: HEAD, dirty status, every file hash, and the pool record are unchanged)"
run th status
printf '\n$ cat runtime.log (every tmux/treehouse call teardown made)\n'; cat "$SCEN/runtime.log"
printf 'treehouse calls by teardown: %s\n' "$(grep -c '^treehouse' "$SCEN/runtime.log")"
printf 'tmux kill-window calls by teardown: %s\n' "$(grep -c 'kill-window' "$SCEN/runtime.log")"

step "11. BASE COMMIT ${BASE_SHA:0:7} for contrast: the same shape, ordinary teardown --force of the dead record"
mkdir -p "$SCEN/base"
git -C "$ROOT" archive "$BASE_SHA" | tar -x -C "$SCEN/base"
write_record old-r1 "$OLD_LABEL"
printf 'done: PR merged\n' > "$STATE/old-r1.status"
: > "$SCEN/runtime.log"
run teardown "$SCEN/base" old-r1 --force
fingerprint "$SCEN/fp-after-base.txt"
printf '\n$ diff fp-before.txt fp-after-base.txt\n'; diff "$SCEN/fp-before.txt" "$SCEN/fp-after-base.txt" && echo "(no difference)"
run th status
printf '\n$ cat runtime.log\n'; cat "$SCEN/runtime.log"
[ -f "$P/live-work.txt" ] && echo "new-r1's live-work.txt: still present" || echo "new-r1's live-work.txt: DESTROYED by the base commit's teardown"

step "cleanup"
th return --force "$P" >/dev/null 2>&1 || true
cd / && rm -rf "$SCEN"
echo "removed $SCEN"
