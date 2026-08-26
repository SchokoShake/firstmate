#!/usr/bin/env bash
# End-to-end transcript for the backlog PR-link convention, driven exactly the
# way firstmate drives it: a throwaway home with a real tasks-axi markdown
# backlog, the real bin/fm-pr-check.sh (forge CLIs stubbed to exit 0), and the
# real bin/fm-backlog-pr.sh. Usage: e2e-transcript.sh <firstmate-checkout>
set -u
ROOT=$1
H=$(mktemp -d "${TMPDIR:-/tmp}/fm-e2e-XXXXXX")
trap 'rm -rf "$H"' EXIT
mkdir -p "$H/data" "$H/state" "$H/config" "$H/fakebin"
cp "$ROOT/.tasks.toml" "$H/.tasks.toml"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
for t in tmux treehouse no-mistakes gh gh-axi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$H/fakebin/$t"; chmod +x "$H/fakebin/$t"
done
export PATH="$H/fakebin:$PATH" FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$H/state" FM_CONFIG_OVERRIDE="$H/config"
PR=https://github.com/acme/widget/pull/42
MR=https://gitlab.com/acme/widget/-/merge_requests/9

echo "firstmate checkout: $ROOT ($(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo 'exported tree'))"
echo "tasks-axi: $(tasks-axi --version 2>/dev/null | head -1)   backlog: \$FM_HOME/data/backlog.md (fresh)"

run() {  # print the command as typed, then its output and exit code
  local rc
  printf '\n$ %s\n' "$*"
  "$@" 2>&1
  rc=$?
  printf '[exit %s]\n' "$rc"
}
ta() { (cd "$H" && tasks-axi "$@"); }
board() {  # the persisted item line the logbook board reads
  printf '\n$ grep -- "- [ ] %s - " data/backlog.md\n' "$1"
  grep -- "- \[ \] $1 - " "$H/data/backlog.md" || echo "(no in-flight line for $1)"
}
links() {
  printf '\n$ tasks-axi show %s --full | grep -E "^  (title|links):"\n' "$1"
  ta show "$1" --full | grep -E '^  (title|links):'
}
fm() {  # a firstmate script, printed with its repo-relative name
  local script=$1; shift
  if [ -x "$ROOT/bin/$script" ]; then run "$ROOT/bin/$script" "$@" | sed "s#$ROOT/bin/#bin/#"
  else printf '\n$ bin/%s %s\n(bin/%s does not exist at this commit)\n' "$script" "$*" "$script"; fi
}

echo; echo "================ 1. THE DEFECT: a PR URL living in the title is wiped by a title change ================"
run ta add legacy-a1 "ship the widget $PR" --kind ship --repo widget --start >/dev/null
board legacy-a1; links legacy-a1
run ta update legacy-a1 --title "ship the widget, revised" >/dev/null
board legacy-a1; links legacy-a1
echo "^ the board card for legacy-a1 now has no PR link and therefore no Merge option"

echo; echo "================ 2. THE FIX: fm-pr-check.sh records the PR in the item's pr field ================"
run ta add ship-k2 "ship the widget" --kind ship --repo widget --start >/dev/null
printf 'kind=ship\nmode=no-mistakes\n' > "$H/state/ship-k2.meta"; chmod 0600 "$H/state/ship-k2.meta"
fm fm-pr-check.sh ship-k2 "$PR"
printf '\n$ cat state/ship-k2.meta\n'; cat "$H/state/ship-k2.meta"
board ship-k2; links ship-k2

[ -x "$ROOT/bin/fm-backlog-pr.sh" ] || { echo; echo "(bin/fm-backlog-pr.sh does not exist at this commit: no owner records the link on the item, so sections 3-6 cannot run)"; exit 0; }

echo; echo "================ 3. THE GUARD: a title change through the owner keeps the link ================"
fm fm-backlog-pr.sh retitle ship-k2 "ship the widget, revised"
board ship-k2; links ship-k2
echo "^ title changed, pr link intact"

echo; echo "================ 4. COMPAT READ: a legacy title-embedded URL migrates into the pr field on the next touch ================"
run ta add legacy-b2 "ship the gadget (see $PR)." --kind ship --repo gadget --start >/dev/null
board legacy-b2
fm fm-backlog-pr.sh retitle legacy-b2 "ship the gadget, revised"
board legacy-b2; links legacy-b2
echo "^ the URL is no longer title text; it is the item's pr link and survives further retitles"

echo; echo "================ 5. REPAIR: a link already lost (as in 1) comes back from the task's own pr= metadata ================"
printf 'kind=ship\nmode=no-mistakes\npr=%s\n' "$PR" > "$H/state/legacy-a1.meta"; chmod 0600 "$H/state/legacy-a1.meta"
fm fm-backlog-pr.sh repair legacy-a1
board legacy-a1; links legacy-a1

echo; echo "================ 6. GITLAB: a merge request is reported, never written into the title ================"
run ta add ship-m4 "ship the gizmo" --kind ship --repo gizmo --start >/dev/null
fm fm-backlog-pr.sh record ship-m4 "$MR"
board ship-m4
fm fm-backlog-pr.sh retitle ship-m4 "ship the gizmo $MR"
board ship-m4
echo "^ refused: a URL in title text is exactly the link the next title change would drop"
