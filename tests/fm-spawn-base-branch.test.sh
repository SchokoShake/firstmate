#!/usr/bin/env bash
# tests/fm-spawn-base-branch.test.sh - regressions for bin/fm-spawn.sh --base,
# the branch a task's work will merge into, recorded as base=<branch> in
# state/<id>.meta so a consumer can build the branch tree from durable state
# before the task has a PR (bin/fm-fleet-snapshot.sh's task rows).
#
# The recording cases drive a real spawn against a real isolated git worktree and
# a fake tmux, exactly like the trace-context spawn suite. The refusal cases stop
# before any endpoint exists, so a fake tmux that exits non-zero backstops them.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-base-branch)

# Fake tmux: answers the pane-path query with the real task worktree and accepts
# every lifecycle command, so a spawn that clears validation reaches metadata.
make_launching_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# Same home shape, but a tmux that refuses, so a spawn that gets past the flag
# checks still creates nothing.
make_refusing_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# Echoes "<home>|<project>|<worktree>|<fakebin>".
make_case() {  # <name> <launching|refusing>
  local name=$1 flavor=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  if [ "$flavor" = launching ]; then
    fakebin=$(make_launching_fakebin "$case_dir/fake")
    fm_git_worktree "$proj" "$wt" "wt-$name"
  else
    fakebin=$(make_refusing_fakebin "$case_dir/fake")
    mkdir -p "$proj"
  fi
  printf '%s\n' "$home|$proj|$wt|$fakebin"
}

write_brief() {  # <home> <id>
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n' \
    "$id" > "$home/data/$id/brief.md"
}

run_spawn() {  # <home> <worktree> <fakebin> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

read_case() {  # <record>
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN <<EOF
$1
EOF
}

# The declared parent branch survives to the task's durable record verbatim, and
# a spawn that declares none records none - the two are different facts.
test_declared_base_is_recorded() {
  local out

  read_case "$(make_case declared launching)"
  write_brief "$HOME_DIR" base-ship-a1
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" base-ship-a1 "$PROJ_DIR" claude \
    --mode no-mistakes --yolo off --base release/2026.09)
  assert_contains "$out" "spawned base-ship-a1" "ship spawn with --base did not complete: $out"
  assert_grep 'base=release/2026.09' "$HOME_DIR/state/base-ship-a1.meta" \
    "the declared base branch was not recorded"
  [ "$(grep -c '^base=' "$HOME_DIR/state/base-ship-a1.meta")" -eq 1 ] \
    || fail "the declared base branch was recorded more than once"

  read_case "$(make_case undeclared launching)"
  write_brief "$HOME_DIR" base-ship-b2
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" base-ship-b2 "$PROJ_DIR" claude \
    --mode no-mistakes --yolo off)
  assert_contains "$out" "spawned base-ship-b2" "ship spawn without --base did not complete: $out"
  assert_no_grep 'base=' "$HOME_DIR/state/base-ship-b2.meta" \
    "a spawn that declared no base recorded one anyway"

  read_case "$(make_case scout launching)"
  write_brief "$HOME_DIR" base-scout-c3
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" base-scout-c3 "$PROJ_DIR" claude \
    --scout --base main)
  assert_contains "$out" "spawned base-scout-c3" "scout spawn with --base did not complete: $out"
  assert_grep 'base=main' "$HOME_DIR/state/base-scout-c3.meta" \
    "a scout did not record its declared base branch"
  pass "fm-spawn records the declared base branch, and records none when undeclared"
}

# The value reaches durable metadata other tools parse as key=value lines, so
# anything that is not a plain branch name stops the spawn instead. The table
# uses the --base=<value> form: the separated form refuses an option-looking
# value earlier, as a missing value, which is asserted on its own below.
test_invalid_base_is_refused() {
  local label value out status n=0

  read_case "$(make_case invalid refusing)"
  while IFS='|' read -r label value; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    write_brief "$HOME_DIR" "base-bad-$n"
    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "base-bad-$n" "$PROJ_DIR" claude \
      --mode no-mistakes --yolo off --base="$value")
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "--base must be a plain branch name" \
      "$label: refusal did not explain the contract"
    assert_absent "$HOME_DIR/state/base-bad-$n.meta" "$label: refused spawn wrote task metadata"
  done <<'ROWS'
option-looking|--delete
leading dash|-topic
metadata separator|window=unexpected
revision range|main..topic
trailing slash|release/
empty segment|release//2026
git-reserved suffix|topic.lock
whitespace|two words
ROWS
  [ "$n" -eq 8 ] || fail "the invalid-base table went thin: only $n rows"

  # A newline is the one that would forge a second metadata key, so it is driven
  # as a real embedded newline rather than through the table.
  write_brief "$HOME_DIR" base-bad-newline
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" base-bad-newline "$PROJ_DIR" claude \
    --mode no-mistakes --yolo off --base "$(printf 'main\nwindow=unexpected')")
  status=$?
  [ "$status" -ne 0 ] || fail "a --base carrying a newline should exit non-zero"
  assert_contains "$out" "--base must be a plain branch name" "a newline base was not refused"
  assert_absent "$HOME_DIR/state/base-bad-newline.meta" "a newline base wrote task metadata"

  # An empty value, and a separated flag whose value looks like another flag, are
  # both refused by the flag itself, before the name check.
  write_brief "$HOME_DIR" base-bad-empty
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" base-bad-empty "$PROJ_DIR" claude \
    --mode no-mistakes --yolo off --base '')
  status=$?
  [ "$status" -ne 0 ] || fail "an empty --base should exit non-zero"
  assert_contains "$out" "--base requires a non-empty value" "empty --base was not refused"

  write_brief "$HOME_DIR" base-bad-flagvalue
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" base-bad-flagvalue "$PROJ_DIR" claude \
    --mode no-mistakes --yolo off --base --delete)
  status=$?
  [ "$status" -ne 0 ] || fail "a separated --base swallowing a flag should exit non-zero"
  assert_contains "$out" "--base requires a value" "a separated --base swallowed the next flag"
  pass "fm-spawn refuses a --base that is not a plain branch name"
}

# A secondmate is a firstmate home with no task branch to parent, and a relaunch
# reuses the branch the task already recorded, so both refuse the flag rather
# than accepting and ignoring it.
test_base_is_refused_where_it_has_no_meaning() {
  local out status

  read_case "$(make_case scoped refusing)"
  write_brief "$HOME_DIR" base-sm-d4
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" base-sm-d4 "$HOME_DIR" --secondmate --base main)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn carrying --base should exit non-zero"
  assert_contains "$out" "--base applies only to ship and scout spawns" \
    "secondmate spawn did not refuse --base"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" base-sm-d4 --relaunch --base main)
  status=$?
  [ "$status" -ne 0 ] || fail "a relaunch carrying --base should exit non-zero"
  assert_contains "$out" "--relaunch reuses the task's recorded base branch" \
    "relaunch did not refuse --base"
  pass "fm-spawn refuses --base on a secondmate spawn and on a relaunch"
}

test_declared_base_is_recorded
test_invalid_base_is_refused
test_base_is_refused_where_it_has_no_meaning
