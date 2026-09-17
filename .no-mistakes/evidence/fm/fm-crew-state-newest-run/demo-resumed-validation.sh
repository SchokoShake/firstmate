#!/usr/bin/env bash
# Manual end-to-end demo: the backlog repro (fail one run, start another on the
# same branch, read fm-crew-state during the second), read by the base commit's
# fm-crew-state.sh and by the target commit's, over the same fixture.
# Usage: demo-resumed-validation.sh <old-root> <new-root>
set -u
OLD=$1 NEW=$2
unset FM_HOME
D=$(mktemp -d /tmp/fm-demo-XXXXXX)
trap 'rm -rf "$D"' EXIT
export GIT_AUTHOR_NAME=demo GIT_AUTHOR_EMAIL=demo@example.invalid
export GIT_COMMITTER_NAME=demo GIT_COMMITTER_EMAIL=demo@example.invalid

WT="$D/wt"
mkdir -p "$WT" "$D/state" "$D/fakebin"
git -C "$WT" init -q
git -C "$WT" commit -q --allow-empty -m init
git -C "$WT" checkout -q -b fm/feat-resume
git -C "$WT" commit -q --allow-empty -m feature
LOCAL=$(git -C "$WT" rev-parse HEAD)

# The pipeline's review fix lives only in a separate gate repository.
git init -q --bare "$D/gate.git"
git -C "$WT" push -q "$D/gate.git" HEAD:refs/heads/submitted
git clone -q -b submitted "$D/gate.git" "$D/pipeline" 2>/dev/null
git -C "$D/pipeline" commit -q --allow-empty -m 'no-mistakes(review): apply review fix'
PIPE=$(git -C "$D/pipeline" rev-parse HEAD)

cat > "$D/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'axi status') printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;;
  'runs '*) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
SH
cat > "$D/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
SH
chmod +x "$D/fakebin/no-mistakes" "$D/fakebin/tmux"

printf 'window=fm:fm-resume\nworktree=%s\nkind=ship\nharness=claude\n' "$WT" > "$D/state/resume.meta"
printf 'resolved: pipeline agent limit reset; reran validation\n' > "$D/state/resume.status"

status() {  # <with-provenance:0|1>
  cat <<EOF
run:
  id: "01LIVE"
  branch: fm/feat-resume
  status: running
  head: ${PIPE:0:8}
  findings: none
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,7
    review,fixing,1,812000
    test,pending,0,0
EOF
  [ "$1" = 1 ] && cat <<EOF
branch_sync:
  state: pipeline_owned
  local:
    branch: fm/feat-resume
    head: $LOCAL
  pipeline:
    run: "01LIVE"
    status: running
    submitted_head: $LOCAL
    current_head: $PIPE
EOF
}
FM_FAKE_RUNS_LIST=$(printf '  running      fm/feat-resume %s  2026-09-02 19:13\n  failed       fm/feat-resume %s  2026-09-02 16:05\n' "${PIPE:0:8}" "${LOCAL:0:8}")
export FM_FAKE_RUNS_LIST

echo "worktree HEAD (submitted head): ${LOCAL:0:8}   live run head (gate-only review fix): ${PIPE:0:8}"
echo "pipeline head resolves in worktree: $(git -C "$WT" rev-parse -q --verify "$PIPE^{commit}" >/dev/null 2>&1 && echo yes || echo no)"
echo
echo '$ no-mistakes runs   (plain listing; still offers the superseded run)'
printf '%s\n\n' "$FM_FAKE_RUNS_LIST"
for prov in 1 0; do
  FM_FAKE_AXI_STATUS=$(status "$prov"); export FM_FAKE_AXI_STATUS
  if [ "$prov" = 1 ]; then echo "### Case A: newest run is live (review fix round 1), push provenance names the worktree HEAD"
  else echo "### Case B: newest run cannot be bound to the current head (no provenance)"; fi
  echo '$ no-mistakes axi status'
  printf '%s\n' "$FM_FAKE_AXI_STATUS" | sed 's/^/    /'
  for side in OLD NEW; do
    root=${!side}
    printf '%s fm-crew-state.sh resume -> ' "$side"
    PATH="$D/fakebin:$PATH" FM_STATE_OVERRIDE="$D/state" "$root/bin/fm-crew-state.sh" resume
  done
  echo
done
