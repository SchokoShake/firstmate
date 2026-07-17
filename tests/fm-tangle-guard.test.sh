#!/usr/bin/env bash
# Behavior tests for the worktree-tangle guards.
#
# Firstmate is a treehouse-pooled git repo of itself: linked worktrees and
# secondmate homes all sit at a detached HEAD on the default branch, while the
# PRIMARY checkout (FM_ROOT) is a normal checkout on a real branch. The "tangle"
# is a crewmate branching/committing in the primary instead of its own worktree,
# stranding the primary on a feature branch. Two guards cover it:
#   GUARD 1 (prevention) - the brief asserts isolation before its branch step, and
#            fm-spawn refuses to launch unless the resolved worktree is isolated.
#   GUARD 2 (detection)  - fm-guard and fm-bootstrap alarm when the primary is on
#            a feature branch, and stay silent on the default branch or detached.
# These cases pin: the shared lib's branch classification, the fm-guard banner,
# the fm-bootstrap problem line, the brief assertion ordering, and the fm-spawn
# abort - all hermetic over temp git repos and fakebins.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tangle-lib.sh
. "$ROOT/bin/fm-tangle-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tangle-guard)
fm_git_identity fmtest fmtest@example.invalid

# A fresh git repo on `main` with one commit. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# --- shared lib: branch classification --------------------------------------

# fm_primary_tangle_branch is the whole scoping decision: a NAMED non-default
# branch is the tangle; the default branch and detached HEAD are healthy.
test_lib_classification() {
  local repo n=0 label state branch expect out
  repo=$(make_repo "$TMP_ROOT/lib-repo")
  while IFS='|' read -r label state branch expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case "$state" in
      default)  git -C "$repo" checkout -q main ;;
      feature)  git -C "$repo" checkout -q -B "$branch" ;;
      detached) git -C "$repo" checkout -q main; git -C "$repo" checkout -q --detach ;;
    esac
    out=$(fm_primary_tangle_branch "$repo" || true)
    [ "$out" = "$expect" ] || fail "$label: expected tangle='$expect', got '$out'"
  done <<'ROWS'
on the default branch is healthy|default||
on a feature branch is the tangle|feature|fm/readme-restructure-d3|fm/readme-restructure-d3
detached HEAD on default is healthy (worktrees, secondmate homes)|detached||
ROWS
  # A non-git directory is not a tangle and must not error.
  out=$(fm_primary_tangle_branch "$TMP_ROOT" || true)
  [ -z "$out" ] || fail "non-git dir wrongly reported a tangle: '$out'"
  pass "fm_primary_tangle_branch: feature branch alarms; default/detached/non-git stay silent"
}

# --- GUARD 2a: fm-guard banner ----------------------------------------------

run_guard() {
  # Scope the guard to a temp repo as the primary checkout; state lives under it.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-guard.sh" 2>&1
}

test_guard_banner() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/guard-repo")

  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed while primary was on main"

  git -C "$repo" checkout -q --detach
  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed on a detached HEAD (legitimate worktree state)"

  git -C "$repo" checkout -q -B fm/tangle-aa1
  out=$(run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "guard did not alarm on a feature branch in the primary"
  assert_contains "$out" "fm/tangle-aa1" "guard banner did not name the offending branch"
  assert_contains "$out" "checkout main" "guard banner did not print the restore remediation"
  out=$(FM_GUARD_READ_ONLY=1 run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "read-only guard did not keep the tangle alarm"
  assert_contains "$out" "read-only session must leave restore work" "read-only guard did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "read-only guard printed a state-changing restore command"
  pass "fm-guard: bordered tangle banner fires only for a feature branch and suppresses repair commands in read-only mode"
}

# --- GUARD 2b: fm-bootstrap problem line ------------------------------------

run_bootstrap() {
  # No projects/ under the home keeps fleet sync inert; grep isolates the line.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_line() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/bootstrap-repo")

  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line while on main: $out"

  git -C "$repo" checkout -q --detach
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line on a detached HEAD: $out"

  git -C "$repo" checkout -q -B fm/tangle-bb2
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "bootstrap did not report the tangled branch"
  assert_contains "$out" "checkout main" "bootstrap TANGLE line lacked the restore remediation"
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "detect-only bootstrap did not report the tangled branch"
  assert_contains "$out" "read-only session must leave restore work" "detect-only bootstrap did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "detect-only bootstrap printed a state-changing restore command"
  pass "fm-bootstrap: TANGLE problem line fires only for a feature branch and suppresses repair commands in detect-only mode"
}

# --- GUARD 1a: brief isolation assertion ------------------------------------

# The generated ship brief must carry the isolation assertion AHEAD of the
# `git checkout -b` step, so the crewmate verifies its worktree before branching.
test_brief_assertion_precedes_branch() {
  local home brief iso br
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tangle-brief-cc3 alpha >/dev/null 2>&1
  brief="$home/data/tangle-brief-cc3/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "blocked: launched in primary checkout, not an isolated worktree" "$brief" \
    "brief is missing the isolation blocked-status contract"
  assert_grep "The path check is authoritative" "$brief" \
    "brief must make the path check authoritative"
  assert_no_grep "A reliable test that you are in a linked worktree" "$brief" \
    "brief must not present git-dir/common-dir as decisive"
  assert_no_grep "they are identical in the primary checkout" "$brief" \
    "brief must not claim the primary checkout has identical git dirs"
  iso=$(grep -n 'launched in primary checkout, not an isolated worktree' "$brief" | head -1 | cut -d: -f1)
  br=$(grep -n 'git checkout -b fm/' "$brief" | head -1 | cut -d: -f1)
  if [ -z "$iso" ] || [ -z "$br" ]; then
    fail "brief missing assertion ($iso) or branch step ($br)"
  fi
  [ "$iso" -lt "$br" ] || fail "isolation assertion (line $iso) must precede the branch step (line $br)"
  pass "fm-brief: ship brief asserts worktree isolation before the branch step"
}

# --- GUARD 1b: fm-spawn isolation abort -------------------------------------

# A fake tmux that swallows window ops and names the session on '#S', paired with
# a treehouse stub whose `get --lease` prints FM_FAKE_PANE_PATH as the leased
# worktree - so the spawn's authoritative worktree capture resolves to a path we
# control (fm-spawn-wt-batch-x5). Echoes the fakebin dir.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse_lease "$fakebin"
  printf '%s\n' "$fakebin"
}

run_spawn() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex 2>&1
}

test_spawn_isolation_abort() {
  local home proj fakebin out status
  home="$TMP_ROOT/spawn-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-fake")
  # A genuine isolated linked worktree of the project, detached on the default.
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-wt" >/dev/null 2>&1
  mkdir -p "$TMP_ROOT/spawn-notgit" "$proj/sub"

  # Abort: the pane resolves to a plain non-git directory (not a worktree at all).
  out=$(run_spawn "$home" abort-notgit-dd4 "$proj" "$TMP_ROOT/spawn-notgit" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn into a non-worktree dir should abort"
  assert_contains "$out" "did not yield an isolated worktree" "non-worktree spawn lacked the isolation error"
  assert_absent "$home/state/abort-notgit-dd4.meta" "aborted spawn must not record meta"

  # Abort: the pane resolves INTO the primary checkout (a subdir of PROJ_ABS).
  out=$(run_spawn "$home" abort-primary-ee5 "$proj" "$proj/sub" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn landing inside the primary checkout should abort"
  assert_contains "$out" "did not yield an isolated worktree" "primary-checkout spawn lacked the isolation error"

  # Proceed: the pane resolves to a genuine, isolated worktree.
  out=$(run_spawn "$home" ok-isolated-ff6 "$proj" "$TMP_ROOT/spawn-wt" "$fakebin"); status=$?
  expect_code 0 "$status" "spawn into a genuine isolated worktree should succeed"
  assert_contains "$out" "spawned ok-isolated-ff6" "isolated spawn did not report success"
  assert_not_contains "$out" "did not yield an isolated worktree" "isolated spawn wrongly tripped the guard"
  pass "fm-spawn: aborts unless the resolved worktree is a genuine, isolated worktree"
}

# --- GUARD 1d: fm-spawn $FM_HOME backstop (fm-spawn-wt-batch-x5) -------------

# The historical mis-capture recorded worktree=$FM_HOME (the primary firstmate
# checkout) on projects/* spawns. Because firstmate is a git repo of itself,
# $FM_HOME is a VALID git toplevel distinct from a projects/* project, so it
# cleared every clause of the isolation guard above and was recorded silently.
# validate_spawn_worktree now asserts the resolved worktree is NOT the primary
# checkout, so a regression ABORTS loudly instead of corrupting meta and tangling
# the turn-end hook into the primary. This pins that backstop.
test_spawn_fm_home_worktree_backstop() {
  local home proj fakebin out status
  # $FM_HOME is itself a git repo (the firstmate-is-a-git-repo-of-itself shape).
  home=$(make_repo "$TMP_ROOT/fmhome-home")
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/fmhome-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/fmhome-fake")

  # The lease resolves to $FM_HOME itself - the exact mis-capture value. It is a
  # valid git toplevel distinct from the project, so it clears the isolation
  # clauses and only the $FM_HOME backstop can catch it.
  out=$(run_spawn "$home" abort-fmhome-hh8 "$proj" "$home" "$fakebin"); status=$?
  expect_code 1 "$status" "a worktree resolving to \$FM_HOME must abort"
  assert_contains "$out" "primary firstmate checkout" "the \$FM_HOME backstop error was not printed"
  assert_not_contains "$out" "did not yield an isolated worktree" "the \$FM_HOME case must hit the dedicated backstop, not the generic isolation clause"
  assert_not_contains "$out" "spawned abort-fmhome-hh8" "the guarded spawn must not report success"
  assert_absent "$home/state/abort-fmhome-hh8.meta" "a \$FM_HOME-mis-captured spawn must not record meta"
  pass "fm-spawn: aborts loudly when the resolved worktree is the primary firstmate checkout (\$FM_HOME)"
}

# --- GUARD 1e: fm-spawn lease release on abort -------------------------------

# `treehouse get --lease` reserves the worktree DURABLY - treehouse never hands
# it out again and never prunes it until a `treehouse return` releases it. Only
# state/<id>.meta's worktree= tells fm-teardown which worktree to release, so an
# abort BETWEEN the lease and that write would strand the pool slot forever with
# nothing left naming it. Every guard above is exactly such an abort. This pins
# that fm-spawn releases the lease itself on those paths.
test_spawn_releases_lease_on_abort() {
  local home proj fakebin rec out status
  home=$(make_repo "$TMP_ROOT/lease-home")
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/lease-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/lease-fake")
  rec="$TMP_ROOT/lease-rec.log"
  mkdir -p "$TMP_ROOT/lease-notgit"

  # The $FM_HOME backstop abort: the leased worktree must still be returned.
  : > "$rec"
  out=$(FM_TMUX_REC="$rec" run_spawn "$home" lease-fmhome-jj9 "$proj" "$home" "$fakebin"); status=$?
  expect_code 1 "$status" "the \$FM_HOME backstop must still abort"
  assert_grep "treehouse get --lease" "$rec" "the spawn did not lease a worktree at all"
  assert_grep "treehouse return --force $home" "$rec" \
    "an aborted spawn must release its durable lease (else the pool slot leaks with no meta to name it)"

  # The generic isolation abort releases its lease too.
  : > "$rec"
  out=$(FM_TMUX_REC="$rec" run_spawn "$home" lease-notgit-kk1 "$proj" "$TMP_ROOT/lease-notgit" "$fakebin"); status=$?
  expect_code 1 "$status" "the non-worktree isolation guard must still abort"
  assert_grep "treehouse return --force $TMP_ROOT/lease-notgit" "$rec" \
    "an isolation-aborted spawn must release its durable lease"

  # A SUCCESSFUL spawn must NOT return the lease: meta now records worktree= and
  # fm-teardown owns the release. Returning here would hand the live crewmate's
  # worktree back to the pool underneath it.
  : > "$rec"
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/lease-wt" >/dev/null 2>&1
  out=$(FM_TMUX_REC="$rec" run_spawn "$home" lease-ok-ll2 "$proj" "$TMP_ROOT/lease-wt" "$fakebin"); status=$?
  expect_code 0 "$status" "a genuine isolated worktree should spawn"
  assert_present "$home/state/lease-ok-ll2.meta" "a successful spawn must record meta"
  assert_no_grep "treehouse return" "$rec" \
    "a successful spawn must NOT release the lease; meta records worktree= and fm-teardown owns the release"
  pass "fm-spawn: releases the durable treehouse lease on abort, and never on success"
}

# The abort release is best-effort, so its failure warning must carry signal. An
# isolation-guard abort captured a path that is BY DEFINITION not a pool worktree,
# so treehouse refuses to return it and there is no lease to leak: warning there
# would print a second, spurious line telling the captain to hand-run a command
# that just repeats the refusal, burying the guard's own error. Every OTHER return
# failure is a real un-released lease and must stay loud. This pins both halves.
test_spawn_lease_release_warning_is_signal() {
  local home proj fakebin out status
  home=$(make_repo "$TMP_ROOT/warn-home")
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/warn-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/warn-fake")

  # Real treehouse refuses an unmanaged path exactly this way (verified against
  # treehouse v2.0.0): rc=1, "worktree <path> is not managed by treehouse".
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  return) printf 'worktree %s is not managed by treehouse\n' "${3:-}" >&2; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  out=$(run_spawn "$home" warn-quiet-pp5 "$proj" "$home" "$fakebin"); status=$?
  expect_code 1 "$status" "the \$FM_HOME backstop must still abort"
  assert_contains "$out" "primary firstmate checkout" "the guard's own error must still be printed"
  assert_not_contains "$out" "could not release the treehouse lease" \
    "an unmanaged path holds no lease; warning there buries the guard's error under a dead-end command"

  # A genuine release failure must still be loud - the lease really is stranded.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  return) printf 'fatal: Unable to create index.lock: File exists\n' >&2; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  out=$(run_spawn "$home" warn-loud-qq6 "$proj" "$home" "$fakebin"); status=$?
  expect_code 1 "$status" "the \$FM_HOME backstop must still abort"
  assert_contains "$out" "could not release the treehouse lease" \
    "a real release failure strands the lease and must be reported"
  pass "fm-spawn: the lease-release warning fires on a real strand, never on a path treehouse never managed"
}

# --- GUARD 1f: fm-spawn respawn reuses the recorded worktree -----------------

# Spawning over an existing task id is a documented recovery flow (a restarted
# server leaves a husk tab; docs/herdr-backend.md "Respawn idempotency"). Because
# a lease is DURABLE, an unconditional `treehouse get --lease` there would reserve
# a SECOND worktree while the meta write overwrote the only record of the first -
# stranding the crew's branch, commits, and uncommitted work in a leased worktree
# nothing names and prune can never reclaim. fm-teardown returns the worktree and
# removes the meta together, so a surviving worktree= is still this task's own
# leased one. This pins the reuse, mirroring the secondmate branch's home= readback.
test_spawn_respawn_reuses_recorded_worktree() {
  local home proj fakebin rec out status wt1 wt2 wt3 wt4
  home=$(make_repo "$TMP_ROOT/respawn-home")
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/respawn-proj")
  fakebin=$(make_spawn_record_fakebin "$TMP_ROOT/respawn-fake")
  rec="$TMP_ROOT/respawn-rec.log"
  wt1="$TMP_ROOT/respawn-wt1"; wt2="$TMP_ROOT/respawn-wt2"
  wt3="$TMP_ROOT/respawn-wt3"; wt4="$TMP_ROOT/respawn-wt4"
  for w in "$wt1" "$wt2" "$wt3" "$wt4"; do
    git -C "$proj" worktree add -q --detach "$w" >/dev/null 2>&1
  done

  # First spawn leases wt1 and records it.
  : > "$rec"
  out=$(run_spawn_record "$home" respawn-mm3 "$proj" "$wt1" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "the first spawn should succeed"
  assert_grep "treehouse get --lease" "$rec" "the first spawn must lease a worktree"
  assert_grep "worktree=$wt1" "$home/state/respawn-mm3.meta" "the first spawn must record its leased worktree"

  # Respawn the SAME id while the stub stands ready to hand out a different
  # worktree (wt2). The respawn must reuse wt1 and never lease at all.
  : > "$rec"
  out=$(run_spawn_record "$home" respawn-mm3 "$proj" "$wt2" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "a respawn over an existing task id should succeed"
  assert_no_grep "treehouse get" "$rec" \
    "a respawn must NOT lease a second worktree; the first would be stranded, leased, with no meta naming it"
  assert_grep "worktree=$wt1" "$home/state/respawn-mm3.meta" \
    "a respawn must keep the recorded worktree, so fm-teardown still names the crew's real work"
  assert_no_grep "worktree=$wt2" "$home/state/respawn-mm3.meta" \
    "a respawn must not overwrite worktree= with a freshly leased path"
  assert_grep "cd '$wt1'" "$rec" "the respawned pane must be cd'd into the REUSED worktree"
  assert_not_contains "$out" "no longer reserves" \
    "wt1's lease is still held, so the reuse must not warn about a lost reservation"

  # A recorded worktree that no longer exists holds nothing to reuse: lease fresh,
  # and name the old path so its possibly-still-held lease can be released by hand.
  : > "$rec"
  out=$(run_spawn_record "$home" respawn-gone-nn4 "$proj" "$wt3" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "the first spawn should succeed"
  git -C "$proj" worktree remove --force "$wt3" >/dev/null 2>&1 || rm -rf "$wt3"
  : > "$rec"
  out=$(run_spawn_record "$home" respawn-gone-nn4 "$proj" "$wt4" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "a respawn whose recorded worktree vanished should still spawn"
  assert_contains "$out" "no longer exists" "a vanished recorded worktree must warn"
  assert_contains "$out" "$wt3" "the warning must name the old path whose lease may still be held"
  assert_grep "treehouse get --lease" "$rec" "a vanished recorded worktree must fall back to a fresh lease"
  assert_grep "worktree=$wt4" "$home/state/respawn-gone-nn4.meta" "the fresh lease must be recorded"

  pass "fm-spawn: a respawn reuses the recorded worktree instead of stranding it behind a second lease"
}

# --- GUARD 1g: fm-spawn respawn identity gate --------------------------------

# Reuse trusts ONE field of a meta (worktree=), so the meta must first be proven
# to describe the task actually being spawned. project= and kind= sit right beside
# worktree= and are exactly that proof. Without the gate, `fm-spawn <id> projects/bar`
# over a meta recording projects/foo launches the crew into FOO's worktree carrying
# BAR's brief - the isolation guard cannot see it, because foo's worktree is a real
# git toplevel that is neither projects/bar nor $FM_HOME - and then rewrites meta to
# a project=bar/worktree=<foo wt> pair fm-teardown can never release (treehouse
# resolves the pool from the project dir). A kind=secondmate meta is worse still:
# its worktree= is a HOME path. Refuse both; a fresh lease instead would overwrite
# the only record of the other task's live worktree.
test_spawn_respawn_identity_gate() {
  local home projA projB fakebin rec out status wtA
  home=$(make_repo "$TMP_ROOT/ident-home")
  mkdir -p "$home/data"
  projA=$(make_repo "$TMP_ROOT/ident-projA")
  projB=$(make_repo "$TMP_ROOT/ident-projB")
  fakebin=$(make_spawn_record_fakebin "$TMP_ROOT/ident-fake")
  rec="$TMP_ROOT/ident-rec.log"
  wtA="$TMP_ROOT/ident-wtA"
  git -C "$projA" worktree add -q --detach "$wtA" >/dev/null 2>&1

  : > "$rec"
  out=$(run_spawn_record "$home" ident-rr7 "$projA" "$wtA" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "the first spawn should succeed"
  assert_grep "worktree=$wtA" "$home/state/ident-rr7.meta" "the first spawn must record its worktree"

  # project= mismatch: same id, different project.
  : > "$rec"
  out=$(run_spawn_record "$home" ident-rr7 "$projB" "$wtA" "$fakebin" "$rec"); status=$?
  expect_code 1 "$status" "a respawn against a different project must refuse"
  assert_contains "$out" "already recorded against project=$projA" \
    "the project-mismatch refusal must name the recorded project"
  assert_not_contains "$out" "spawned ident-rr7" "a refused respawn must not report success"
  assert_grep "project=$projA" "$home/state/ident-rr7.meta" \
    "a refused respawn must leave the recorded task's meta intact"
  assert_no_grep "treehouse get" "$rec" \
    "a refused respawn must not lease; that meta write would strand the recorded task's worktree"

  # kind= mismatch: the recorded ship task respawned as a scout.
  : > "$rec"
  out=$(run_spawn_record "$home" ident-rr7 "$projA" "$wtA" "$fakebin" "$rec" --scout); status=$?
  expect_code 1 "$status" "a respawn under a different kind must refuse"
  assert_contains "$out" "already recorded as kind=ship" "the kind-mismatch refusal must name the recorded kind"
  assert_grep "kind=ship" "$home/state/ident-rr7.meta" "a refused respawn must leave kind= intact"

  # A kind=secondmate meta's worktree= is a HOME path, never a pool worktree.
  fm_write_secondmate_meta "$home/state/ident-sm-ss8.meta" "$projA"
  : > "$rec"
  out=$(run_spawn_record "$home" ident-sm-ss8 "$projA" "$wtA" "$fakebin" "$rec"); status=$?
  expect_code 1 "$status" "a crewmate spawn over a kind=secondmate meta must refuse"
  assert_contains "$out" "already recorded as kind=secondmate" \
    "the refusal must name the recorded secondmate kind (its worktree= is a HOME path)"

  # The gate must never false-refuse the same project reached through a symlinked
  # prefix: project= is recorded from a LOGICAL pwd, so only a physical compare
  # holds (the same reason PROJ_ABS_REAL exists).
  ln -s "$projA" "$TMP_ROOT/ident-link"
  : > "$rec"
  out=$(run_spawn_record "$home" ident-rr7 "$TMP_ROOT/ident-link" "$wtA" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "the same project via a symlinked path must not trip the identity gate"
  assert_not_contains "$out" "already recorded against project=" \
    "a symlinked path to the SAME project must not be read as a different project"

  pass "fm-spawn: a respawn refuses when the recorded meta's project= or kind= describes another task"
}

# --- GUARD 1h: fm-spawn reuse checks the worktree is still reserved -----------

# A reused worktree is only as safe as treehouse's reservation of it, and the meta
# does not imply one: a task spawned before the fm-spawn-side lease landed recorded
# a worktree held only by the old pane-side `treehouse get` subshell, which reserves
# nothing once that subshell dies. Reusing an unreserved path lets a concurrent
# `treehouse get` hand the same worktree to another task. treehouse v2.0.0 has no
# verb to lease an existing path, so fm-spawn warns and reuses anyway - the crew's
# work is IN that worktree, and a fresh lease would abandon it.
test_spawn_reuse_warns_when_lease_is_gone() {
  local home proj fakebin rec out status wt wt2
  home=$(make_repo "$TMP_ROOT/unheld-home")
  mkdir -p "$home/data" "$home/state"
  proj=$(make_repo "$TMP_ROOT/unheld-proj")
  fakebin=$(make_spawn_record_fakebin "$TMP_ROOT/unheld-fake")
  rec="$TMP_ROOT/unheld-rec.log"
  wt="$TMP_ROOT/unheld-wt"; wt2="$TMP_ROOT/unheld-wt2"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  git -C "$proj" worktree add -q --detach "$wt2" >/dev/null 2>&1

  # A pre-fix meta: a real worktree the stub's pool never leased, so `treehouse
  # status` does not report it reserved - exactly the post-fast-forward shape.
  fm_write_meta "$home/state/unheld-tt9.meta" \
    "window=firstmate:fm-unheld-tt9" "worktree=$wt" "project=$proj" \
    "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off"
  : > "$rec"
  out=$(run_spawn_record "$home" unheld-tt9 "$proj" "$wt2" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "an unreserved recorded worktree must still spawn"
  assert_contains "$out" "no longer reserves the worktree recorded for unheld-tt9" \
    "reusing a worktree treehouse no longer reserves must warn: a concurrent get can hand it out"
  assert_contains "$out" "$wt" "the warning must name the unreserved worktree"
  assert_grep "treehouse status" "$rec" "the reuse must ASK treehouse whether the worktree is still reserved"
  assert_no_grep "treehouse get" "$rec" \
    "an unreserved worktree still holds the crew's work; a fresh lease would abandon it"
  assert_grep "worktree=$wt" "$home/state/unheld-tt9.meta" "the reused worktree must stay recorded"
  assert_grep "cd '$wt'" "$rec" "the pane must still be cd'd into the reused worktree"

  # The happy path stays silent: a worktree this pool really leased reads back held.
  : > "$rec"
  out=$(run_spawn_record "$home" held-uu1 "$proj" "$wt2" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "the first spawn should succeed"
  : > "$rec"
  out=$(run_spawn_record "$home" held-uu1 "$proj" "$wt2" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "a respawn of a still-leased worktree should succeed"
  assert_not_contains "$out" "no longer reserves" \
    "a worktree treehouse still holds must reuse silently"

  pass "fm-spawn: reusing a worktree treehouse no longer reserves warns instead of passing it off as held"
}

# The reservation check reads a human table, so it is only as good as its grip on
# treehouse's REAL output shape. Both of these were verified against treehouse
# v2.0.0 and would otherwise fail silently - as a spurious warning on every reuse
# of a genuinely-held pool worktree, which is exactly the noise that teaches a
# captain to ignore the warning:
#   - `in-use` (a live process inside the worktree) is reserved just like `leased`;
#     only `available` means the next `get` may hand the path out.
#   - a path under $HOME is printed ABBREVIATED to `~`, so a raw compare against an
#     absolute worktree= never matches; and a worktree's processes are listed on an
#     indented continuation line that must not be parsed as a pool entry.
test_spawn_reuse_reads_real_treehouse_status_shape() {
  local home proj fakebin rec out status hwt
  home=$(make_repo "$TMP_ROOT/shape-home")
  mkdir -p "$home/data" "$home/state"
  proj=$(make_repo "$TMP_ROOT/shape-proj")
  fakebin=$(make_spawn_record_fakebin "$TMP_ROOT/shape-fake")
  rec="$TMP_ROOT/shape-rec.log"
  # Lives directly under the HOME handed to the spawn, so treehouse's `~` form
  # resolves back to it.
  hwt="$TMP_ROOT/shape-wt"
  git -C "$proj" worktree add -q --detach "$hwt" >/dev/null 2>&1

  # A pool reporting the recorded worktree in treehouse's real shape: `in-use`,
  # $HOME abbreviated to `~`, and a process continuation line. No `get` verb at
  # all - a reuse that leases instead would get an empty path and fail loudly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_TMUX_REC:-}" ] && printf 'treehouse %s\n' "$*" >> "$FM_TMUX_REC"
case "${1:-}" in
  status)
    printf '%-4s  %s  %s\n' 1 in-use '~/shape-wt'
    printf '                   bash (2203717), codex (2203718)\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_write_meta "$home/state/shape-vv2.meta" \
    "window=firstmate:fm-shape-vv2" "worktree=$hwt" "project=$proj" \
    "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off"

  : > "$rec"
  out=$(mkdir -p "$home/data/shape-vv2" && printf 'brief\n' > "$home/data/shape-vv2/brief.md"
    FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$TMP_ROOT" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$hwt" TMUX="fake,1,0" \
      FM_TMUX_REC="$rec" PATH="$fakebin:$PATH" \
      "$ROOT/bin/fm-spawn.sh" shape-vv2 "$proj" codex 2>&1); status=$?
  expect_code 0 "$status" "a respawn onto an in-use pool worktree should succeed"
  assert_not_contains "$out" "no longer reserves" \
    "an in-use, ~-abbreviated pool worktree IS reserved; warning there is spurious noise on every reuse"
  assert_grep "cd '$hwt'" "$rec" "the pane must still be cd'd into the reused worktree"

  pass "fm-spawn: the reservation check reads treehouse's real status shape (in-use, ~-abbreviated \$HOME, process lines)"
}

# --- GUARD 1c: fm-spawn tmux window construction ----------------------------

# The prevention guard also depends on fm-spawn building robust tmux commands
# under a non-default tmux config (base-index 1, automatic-rename on). A RECORDING
# fake tmux+treehouse logs every invocation and returns a sentinel window id, so
# these assertions pin the command construction deterministically, with no live
# tmux:
#   - window creation targets the session with a trailing colon (append form), so
#     tmux appends at the next free index instead of the active window index, which
#     collides under base-index 1;
#   - the window id is captured (-P -F #{window_id}) and automatic-rename/allow-rename
#     are disabled so the fm-<id> name survives the pane cd'ing into the worktree;
#   - the worktree is captured authoritatively from `treehouse get --lease` (not a
#     pane-current-path poll, which could latch $FM_HOME), and the cd-into-worktree
#     send targets that stable window id, never the (possibly-renamed) name
#     (fm-spawn-wt-batch-x5).
make_spawn_record_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_TMUX_REC:-}" ] && printf 'tmux %s\n' "$*" >> "$FM_TMUX_REC"
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '%s\n' "@spawnwid"; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # Recording treehouse stub: logs every call to FM_TMUX_REC and emits
  # FM_FAKE_PANE_PATH as the leased worktree on `get --lease` (fm-spawn-wt-batch-x5).
  fm_fake_treehouse_lease "$fakebin"
  printf '%s\n' "$fakebin"
}

run_spawn_record() {  # <home> <id> <proj> <pane> <fakebin> <rec> [extra spawn args...]
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5 rec=$6
  shift 6
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    FM_TMUX_REC="$rec" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex "$@" 2>&1
}

test_spawn_tmux_window_construction() {
  local home proj fakebin rec wt out status
  home="$TMP_ROOT/spawn-rec-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-rec-proj")
  fakebin=$(make_spawn_record_fakebin "$TMP_ROOT/spawn-rec-fake")
  rec="$TMP_ROOT/spawn-rec.log"
  : > "$rec"
  wt="$TMP_ROOT/spawn-rec-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1

  out=$(run_spawn_record "$home" rec-win-gg7 "$proj" "$wt" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "spawn into a genuine worktree should succeed"
  assert_contains "$out" "spawned rec-win-gg7" "recording spawn did not report success"

  # Bug 1 fix: append-form window creation (trailing colon on the session target).
  assert_grep "new-window -dP -F #{window_id} -t firstmate: -n fm-rec-win-gg7" "$rec" \
    "new-window must append at the session (trailing colon) and capture the window id"
  assert_no_grep "new-window -dP -F #{window_id} -t firstmate -n" "$rec" \
    "new-window must not target the bare session name (collides under base-index 1)"

  # Bug 2 fix (a): pin the window name against automatic-rename / allow-rename.
  assert_grep "set-window-option -t @spawnwid automatic-rename off" "$rec" \
    "must disable automatic-rename on the spawned window"
  assert_grep "set-window-option -t @spawnwid allow-rename off" "$rec" \
    "must disable allow-rename on the spawned window"

  # Authoritative capture (fm-spawn-wt-batch-x5): the worktree is leased via
  # `treehouse get --lease`, the pane is moved into it with a cd sent to the stable
  # window id, and there is no pane_current_path poll (that poll latched $FM_HOME).
  assert_grep "treehouse get --lease" "$rec" \
    "the worktree must be captured authoritatively via treehouse get --lease"
  assert_grep "send-keys -t @spawnwid cd " "$rec" \
    "the cd-into-worktree send must target the stable window id"
  assert_no_grep "send-keys -t @spawnwid treehouse get Enter" "$rec" \
    "the pane must not run a bare 'treehouse get' (capture is now the fm-spawn-side lease)"
  assert_no_grep "#{pane_current_path}" "$rec" \
    "worktree capture must not poll pane_current_path (that poll latched \$FM_HOME)"

  # The recorded worktree= is the real leased path, NOT $FM_HOME (the exact
  # projects/*-only mis-capture this task fixes). Here FM_HOME=$home != $wt.
  assert_grep "worktree=$wt" "$home/state/rec-win-gg7.meta" \
    "meta must record the real leased worktree"
  assert_no_grep "worktree=$home" "$home/state/rec-win-gg7.meta" \
    "meta must never record worktree=\$FM_HOME (the historical mis-capture)"

  pass "fm-spawn: appends windows by session-colon, pins the name, leases the worktree, records it in meta, and targets the window id"
}

test_lib_classification
test_guard_banner
test_bootstrap_line
test_brief_assertion_precedes_branch
test_spawn_isolation_abort
test_spawn_fm_home_worktree_backstop
test_spawn_releases_lease_on_abort
test_spawn_lease_release_warning_is_signal
test_spawn_respawn_identity_gate
test_spawn_reuse_warns_when_lease_is_gone
test_spawn_reuse_reads_real_treehouse_status_shape
test_spawn_respawn_reuses_recorded_worktree
test_spawn_tmux_window_construction
