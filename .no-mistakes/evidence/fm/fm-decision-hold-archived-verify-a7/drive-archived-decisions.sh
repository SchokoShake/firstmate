#!/usr/bin/env bash
# Live driver: runs <root>/bin/fm-decision-hold.sh and <root>/bin/fm-teardown.sh
# against throwaway FM_HOMEs with the real tasks-axi, pruning Done records into the
# archive the way `tasks-axi done` does (done_keep = 10).
# Usage: drive-archived-decisions.sh <product-root> <scratch-dir>
set -u
ROOT=$1
SCRATCH=$2
mkdir -p "$SCRATCH"
PASSES=0
FAILS=0

say() { printf '\n## %s\n' "$*"; }
# check <ok|fail> <expected-stderr-substring-or-empty> <label> <cmd...>
check() {
  local want=$1 needle=$2 label=$3 out rc verdict
  shift 3
  out=$("$@" 2>&1)
  rc=$?
  printf '$ %s\n%s\n[exit %s]\n' "${*#"$ROOT/"}" "$out" "$rc"
  verdict=PASS
  if [ "$want" = ok ] && [ "$rc" -ne 0 ]; then verdict=FAIL; fi
  if [ "$want" = fail ] && [ "$rc" -eq 0 ]; then verdict=FAIL; fi
  if [ -n "$needle" ]; then
    case "$out" in *"$needle"*) : ;; *) verdict=FAIL ;; esac
  fi
  if [ "$verdict" = PASS ]; then PASSES=$((PASSES + 1)); else FAILS=$((FAILS + 1)); fi
  printf '=> %s: %s (expected %s%s)\n' "$verdict" "$label" "$want" "${needle:+, \"$needle\"}"
}
assert() {  # <label> <test...>
  local label=$1
  shift
  if "$@"; then PASSES=$((PASSES + 1)); printf '=> PASS: %s\n' "$label"
  else FAILS=$((FAILS + 1)); printf '=> FAIL: %s\n' "$label"; fi
}

make_home() {  # <name> -> sets HOME_DIR
  HOME_DIR=$SCRATCH/$1
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$HOME_DIR/fakebin"
  cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  for t in tmux treehouse no-mistakes gh gh-axi; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME_DIR/fakebin/$t"
    chmod +x "$HOME_DIR/fakebin/$t"
  done
}
tx() { (cd "$HOME_DIR" && tasks-axi "$@"); }
dec() {
  PATH="$HOME_DIR/fakebin:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-decision-hold.sh" "$@"
}
teardown() {
  # Same sandbox exemption tests/lib.sh exports: this teardown only ever targets a
  # throwaway FM_HOME with faked tmux/treehouse/no-mistakes/gh.
  FM_GATE_REFUSE_BYPASS=1 XDG_STATE_HOME="$SCRATCH/xdg-state" \
    PATH="$HOME_DIR/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-teardown.sh" "$@"
}
origin() {  # <id>
  local id=$1
  mkdir -p "$HOME_DIR/data/$id"
  tx add "$id" "Investigate $id" --kind scout --repo sample --start >/dev/null
  printf '%s\n' "window=firstmate:fm-$id" "worktree=$HOME_DIR/projects/missing-$id" \
    "project=$HOME_DIR/projects/sample" harness=codex kind=scout mode=scout > "$HOME_DIR/state/$id.meta"
  printf 'done: report complete\n' > "$HOME_DIR/state/$id.status"
  printf '# %s\n\nOne captain choice remains.\n' "$id" > "$HOME_DIR/data/$id/report.md"
}
FILLER=0
close_fillers() {  # <n> -- ordinary work closed with tasks-axi done, which prunes at done_keep
  local i
  for i in $(seq 1 "$1"); do
    FILLER=$((FILLER + 1))
    tx add "filler-$FILLER" "Filler work $FILLER" --repo sample >/dev/null
    tx "done" "filler-$FILLER" >/dev/null
  done
}
sum() { cksum < "$1"; }
in_live() { grep -qF -- "- [x] $1 - " "$HOME_DIR/data/backlog.md"; }

say "Scenario R: reported incident - answered decision pruned by tasks-axi done, then scout teardown"
make_home incident
origin rougeic-art-style
HOLD=$(dec hold rougeic-art-style palette --title "Choose the art palette" --reason "captain palette choice pending" --repo sample)
dec complete rougeic-art-style palette >/dev/null
printf 'Declined: keep the current palette.\n' > "$HOME_DIR/decision.txt"
dec decline rougeic-art-style palette --decision-file "$HOME_DIR/decision.txt"
close_fillers 10
assert "answered hold $HOLD was pruned from data/backlog.md into data/done-archive.md" \
  bash -c "! grep -qF -- '$HOLD' '$HOME_DIR/data/backlog.md' && grep -qF -- '- [x] $HOLD - ' '$HOME_DIR/data/done-archive.md'"
check ok "" "scout teardown passes the decision gate for the archived answered decision" teardown rougeic-art-style
assert "teardown went through (origin metadata removed)" [ ! -f "$HOME_DIR/state/rougeic-art-style.meta" ]

say "Scenario A: answered decision pruned into data/done-archive.md by ordinary tasks-axi done"
make_home answered
origin tour-review
HOLD=$(dec hold tour-review art-style --title "Choose the tour art style" --reason "captain art style choice pending" --repo sample)
echo "hold id: $HOLD"
dec complete tour-review art-style
printf 'Declined: keep the current art style.\n' > "$HOME_DIR/decision.txt"
dec decline tour-review art-style --decision-file "$HOME_DIR/decision.txt"
# A second origin with the same decision key, closed out of band with no answer.
origin other-review
OTHER=$(dec hold other-review art-style --title "Choose the other art style" --reason "captain other choice pending" --repo sample)
dec complete other-review art-style >/dev/null
tx "done" "$OTHER" >/dev/null
close_fillers 10
assert "answered hold $HOLD is gone from data/backlog.md" bash -c "! grep -qF -- '$HOLD' '$HOME_DIR/data/backlog.md'"
assert "answered hold $HOLD is in data/done-archive.md" grep -qF -- "- [x] $HOLD - " "$HOME_DIR/data/done-archive.md"
assert "other origin's unanswered hold $OTHER is in data/done-archive.md" grep -qF -- "- [x] $OTHER - " "$HOME_DIR/data/done-archive.md"
echo "--- archived block for $HOLD (data/done-archive.md) ---"
awk -v id="$HOLD" '/^- \[x\] /{p = index($0, "- [x] " id " - ") == 1} p' "$HOME_DIR/data/done-archive.md"
echo "---"
A_SUM=$(sum "$HOME_DIR/data/done-archive.md")
check ok "" "verify passes for an archived answered decision" dec verify tour-review
check ok "" "complete passes for an archived answered decision" dec complete tour-review art-style
check ok "declined: $HOLD" "identical decline retry of the archived decision is idempotent" \
  dec decline tour-review art-style --decision-file "$HOME_DIR/decision.txt"
printf 'Approved: switch to the new art style.\n' > "$HOME_DIR/drift.txt"
check fail "records a different captain decision" "a changed answer is rejected against the archived record" \
  dec decline tour-review art-style --decision-file "$HOME_DIR/drift.txt"
check fail "already durably resolved" "re-asking an archived answered decision under the same identity is refused" \
  dec hold tour-review art-style --title "Choose the tour art style" --reason "captain art style choice pending" --repo sample
check fail "neither open nor durably resolved" "same key under a different origin, archived without an answer, still fails" \
  dec verify other-review
assert "archive unchanged by every decision-hold read above" [ "$(sum "$HOME_DIR/data/done-archive.md")" = "$A_SUM" ]
assert "no new live hold was created for $HOLD" bash -c "! grep -qF -- '$HOLD' '$HOME_DIR/data/backlog.md'"
check ok "" "teardown of the origin passes the decision gate" teardown tour-review
assert "teardown removed the origin metadata" [ ! -f "$HOME_DIR/state/tour-review.meta" ]
check fail "REFUSED" "teardown of the other origin is still refused" teardown other-review

say "Scenario B: decision closed out of band with no answer, then pruned into the archive"
make_home unanswered
origin audio-flow
HOLD=$(dec hold audio-flow format --title "Choose the audio format" --reason "captain format choice pending" --repo sample)
echo "hold id: $HOLD"
dec complete audio-flow format
tx "done" "$HOLD" >/dev/null
close_fillers 10
assert "unanswered hold $HOLD is in data/done-archive.md only" bash -c "grep -qF -- '- [x] $HOLD - ' '$HOME_DIR/data/done-archive.md' && ! grep -qF -- '$HOLD' '$HOME_DIR/data/backlog.md'"
B_SUM=$(sum "$HOME_DIR/data/done-archive.md")
cp "$HOME_DIR/data/done-archive.md" "$HOME_DIR/archive.before"
check fail "neither open nor durably resolved" "verify fails for an archived decision with no answer" dec verify audio-flow
check fail "neither open nor durably resolved" "complete fails for an archived decision with no answer" dec complete audio-flow format
check fail "REFUSED" "teardown refuses while the archived decision has no answer" teardown audio-flow
assert "refused teardown kept the origin metadata" [ -f "$HOME_DIR/state/audio-flow.meta" ]
printf 'Declined: keep the current audio format.\n' > "$HOME_DIR/decision.txt"
check fail "hold it again under this decision key" "repair refuses and names the recovery path" \
  dec repair audio-flow format --decision-file "$HOME_DIR/decision.txt"
check fail "hold it under this decision key first" "decline before re-holding names the recovery path" \
  dec decline audio-flow format --decision-file "$HOME_DIR/decision.txt"
assert "archive unchanged by verify/complete/repair/decline" [ "$(sum "$HOME_DIR/data/done-archive.md")" = "$B_SUM" ]
check ok "$HOLD" "hold again under the same key opens a fresh live hold" \
  dec hold audio-flow format --title "Choose the audio format" --reason "captain format choice pending" --repo sample
assert "archive unchanged by the re-hold itself" [ "$(sum "$HOME_DIR/data/done-archive.md")" = "$B_SUM" ]
check ok "state: queued" "the re-held decision is open in the live backlog" tx show "$HOLD" --full
check ok "declined: $HOLD" "decline records the captain's answer on the live re-hold" \
  dec decline audio-flow format --decision-file "$HOME_DIR/decision.txt"
check ok "" "verify passes once the re-held decision is answered" dec verify audio-flow
# decline closes the live hold with tasks-axi done; with 10 Done records already
# live, tasks-axi's own done_keep prune moves the oldest one into the archive.
echo "--- archive diff across decline (tasks-axi done_keep prune) ---"
diff "$HOME_DIR/archive.before" "$HOME_DIR/data/done-archive.md"
echo "---"
assert "the archive only grew by appended records; nothing in it was rewritten" \
  bash -c "head -c \$(wc -c < '$HOME_DIR/archive.before') '$HOME_DIR/data/done-archive.md' | cmp -s - '$HOME_DIR/archive.before'"
assert "the archived unanswered record was not touched (no resolution written into it)" \
  bash -c "diff '$HOME_DIR/archive.before' '$HOME_DIR/data/done-archive.md' | grep -q '^> ' && ! diff '$HOME_DIR/archive.before' '$HOME_DIR/data/done-archive.md' | grep -q -- '$HOLD'"
close_fillers 10
assert "the identity now appears twice in the archive (unanswered then answered)" \
  [ "$(grep -cF -- "- [x] $HOLD - " "$HOME_DIR/data/done-archive.md")" = 2 ]
grep -n -- "^## Archived\|- \[x\] $HOLD - " "$HOME_DIR/data/done-archive.md"
check ok "" "verify judges the latest archived record (answered) and passes" dec verify audio-flow
check ok "" "teardown passes after the answered re-hold was pruned too" teardown audio-flow

say "Scenario C: custom [markdown] archive path in .tasks.toml"
make_home custom-archive
sed -i '' 's#^archive = .*#archive = "data/history/old-done.md"#' "$HOME_DIR/.tasks.toml"
mkdir -p "$HOME_DIR/data/history"
grep -n archive "$HOME_DIR/.tasks.toml"
origin app-stats
HOLD=$(dec hold app-stats palette --title "Choose the stats palette" --reason "captain palette choice pending" --repo sample)
dec complete app-stats palette >/dev/null
printf 'Declined: keep the current palette.\n' > "$HOME_DIR/decision.txt"
dec decline app-stats palette --decision-file "$HOME_DIR/decision.txt"
close_fillers 10
assert "answered hold reached the configured archive data/history/old-done.md" grep -qF -- "- [x] $HOLD - " "$HOME_DIR/data/history/old-done.md"
assert "default data/done-archive.md was never created" [ ! -e "$HOME_DIR/data/done-archive.md" ]
check ok "" "verify reads the configured archive and passes" dec verify app-stats
# Adversarial: an unanswered decision archived in the configured path, plus a forged
# answered copy of it planted in the default path, which must not be consulted.
LAYOUT=$(dec hold app-stats layout --title "Choose the stats layout" --reason "captain layout choice pending" --repo sample)
dec complete app-stats layout >/dev/null
tx "done" "$LAYOUT" >/dev/null
close_fillers 10
assert "unanswered layout hold reached the configured archive" grep -qF -- "- [x] $LAYOUT - " "$HOME_DIR/data/history/old-done.md"
{ printf '## Archived 2026-11-05\n'
  awk -v id="$HOLD" '/^- \[x\] /{p = index($0, "- [x] " id " - ") == 1} p' "$HOME_DIR/data/history/old-done.md" \
    | sed "s/$HOLD/$LAYOUT/; s/palette/layout/g"
} > "$HOME_DIR/data/done-archive.md"
echo "--- forged decoy in the unconfigured default path ---"; cat "$HOME_DIR/data/done-archive.md"; echo "---"
check fail "neither open nor durably resolved" "a forged answer in the unconfigured default archive is ignored" dec verify app-stats

printf '\nSUMMARY root=%s passes=%s fails=%s\n' "$ROOT" "$PASSES" "$FAILS"
