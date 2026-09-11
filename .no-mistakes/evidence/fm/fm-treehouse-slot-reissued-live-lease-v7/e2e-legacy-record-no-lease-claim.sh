#!/usr/bin/env bash
# Variant: the older record predates durable leases (no lease_holder=), as the
# live records named in the task do; the pool leases its slot to new-r1's claim.
set -u
ROOT=${ROOT:?}
SCEN=$(mktemp -d /tmp/fm-retire-legacy.XXXX)
NEW_LABEL=fm-task:new-r1:l1789026480.244338.3761
STATE=$SCEN/home/state
step() { printf '\n\n===== %s =====\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; "$@"; printf '[exit %d]\n' "$?"; }
th() { HOME=$SCEN/fakehome treehouse "$@"; }
mkdir -p "$SCEN/fakehome" "$SCEN/project" "$STATE" "$SCEN/home/data" "$SCEN/home/config" "$SCEN/fakebin"
cd "$SCEN/project" || exit 1
git init -q -b main . && printf 'base\n' > README.md
git -c user.name=t -c user.email=t@example.invalid add README.md
git -c user.name=t -c user.email=t@example.invalid commit -qm initial
printf 'max_trees = 4\nroot = "%s"\n' "$SCEN/th" > treehouse.toml
step "1. legacy-r1 predates durable leases: its slot was only owner-reserved; the pool now leases it to new-r1"
P=$(th get --lease --lease-holder "$NEW_LABEL" 2>/dev/null); POOL=$(dirname "$(dirname "$P")")
printf 'live uncommitted work of new-r1\n' > "$P/live-work.txt"
run th status
write_record() { printf '%s\n' "window=firstmate:fm-$1" "endpoint_task_id=$1" "worktree=$P" "project=$SCEN/project" "harness=claude" "kind=ship" "tasktmp=$SCEN/tasktmp-$1" "spawn_gen=$2" "mode=direct-PR" "yolo=off" "$3" | grep -v '^$' > "$STATE/$1.meta"; printf 'done: PR merged\n' > "$STATE/$1.status"; }
write_record legacy-r1 s1788765996.150863.30112 ""
write_record new-r1 s1789026483.244338.3761 "lease_holder=$NEW_LABEL"
run cat "$STATE/legacy-r1.meta"
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
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCEN/fakebin/no-mistakes"; chmod +x "$SCEN/fakebin"/*; : > "$SCEN/runtime.log"
teardown() { FM_HOME="$SCEN/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEARDOWN_GUARD_DONE=1 FM_GATE_REFUSE_BYPASS=1 FM_RUNTIME_LOG="$SCEN/runtime.log" PATH="$SCEN/fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" "$@"; }
step "2. --retire-record of the legacy record (dry run, then real)"
run teardown legacy-r1 --retire-record --dry-run
run teardown legacy-r1 --retire-record
step "3. ordinary teardown of the legacy record, plain"
run teardown legacy-r1
step "4. ordinary teardown of the legacy record, --force"
run teardown legacy-r1 --force
step "5. after: is new-r1's live work still there? who holds the slot?"
[ -f "$P/live-work.txt" ] && echo "new-r1's live-work.txt: still present" || echo "new-r1's live-work.txt: DESTROYED"
run th status
printf '\n$ cat runtime.log\n'; cat "$SCEN/runtime.log"
printf '\n$ ls %s\n' "$STATE"; ls -A "$STATE"
th return --force "$P" >/dev/null 2>&1 || true
cd / && rm -rf "$SCEN"
