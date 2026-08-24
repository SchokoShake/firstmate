#!/usr/bin/env bash
# tests/fm-cadence-carriers.test.sh - a home's watcher cadence carriers must
# reach the watcher PROCESS, not just the rendered instruction.
#
# The regression these pin: bin/fm-watch.sh reads FM_CHECK_INTERVAL and
# FM_STALE_ESCALATE_SECS from its inherited environment only, and for a long
# time nothing on the automatic arm path put them there. A home could carry
# config/check-cadence.d/<name>.env for months while every watcher it launched
# ran on the 300s default.
#
# These are real-process tests: a real bin/fm-watch-arm.sh forks a real
# bin/fm-watch.sh, and the watcher's own environment is read back through a
# registered custom check that prints what it inherited. macOS does not let ps
# dump another process's environment at all, so the check script - which the
# watcher execs from inside its own process - is the portable way to observe it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"
TMP_ROOT=$(fm_test_tmproot fm-cadence-carriers)

# A home whose only wake source is one registered check that reports the two
# cadence variables the watcher process actually inherited.
make_home() {  # <name>
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config/check-cadence.d"
  # The watcher refuses to sweep custom checks until the non-executing legacy
  # migration is recorded as complete for this state dir.
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  cat > "$home/state/probe.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'probe interval=%s escalate=%s\n' \
  "${FM_CHECK_INTERVAL:-UNSET}" "${FM_STALE_ESCALATE_SECS:-UNSET}"
SH
  chmod 0700 "$home/state/probe.check.sh"
  FM_HOME="$home" "$REGISTER" probe >/dev/null || fail "could not register the cadence probe check"
  printf '%s\n' "$home"
}

carrier() {  # <home> <name> <line...>
  local home=$1 name=$2
  shift 2
  printf '%s\n' "$@" > "$home/config/check-cadence.d/$name.env"
}

# Arm one real cycle against <home> and echo the probe line the watcher's own
# process produced. The arm is a tracked background child rather than a
# foreground call so a hung cycle fails this test instead of the whole suite;
# any extra env assignments are passed through as leading NAME=VALUE arguments.
arm_probe() {  # <home> [NAME=VALUE ...]
  local home=$1 out pid i probe
  shift
  out="$home/arm-output.txt"
  : > "$out"
  env FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 "$@" \
    "$WATCH_ARM" >"$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 450 ]; do
    grep -q 'probe interval=' "$out" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  probe=$(sed -n 's/.*\(probe interval=[^ ]* escalate=[^ ]*\).*/\1/p' "$out" | head -1)
  [ -n "$probe" ] || fail "watcher never ran the cadence probe check: $(cat "$out")"
  printf '%s\n' "$probe"
}

test_carrier_reaches_the_armed_watcher() {
  local home probe
  home=$(make_home applies)
  carrier "$home" logbook 'export FM_CHECK_INTERVAL=15'
  probe=$(arm_probe "$home")
  assert_contains "$probe" "interval=15" "an armed watcher did not inherit the carrier's check interval"
  pass "a cadence carrier reaches the watcher an ordinary arm launches"
}

test_snappiest_carrier_wins() {
  local home probe
  home=$(make_home snappiest)
  printf 'export FM_CHECK_INTERVAL=30\n' > "$home/config/x-mode.env"
  carrier "$home" board 'export FM_CHECK_INTERVAL=15'
  carrier "$home" slow 'export FM_CHECK_INTERVAL=60'
  probe=$(arm_probe "$home")
  assert_contains "$probe" "interval=15" "three carriers did not resolve to the snappiest interval"
  pass "the snappiest carrier wins when a home runs several"
}

test_carrier_carries_the_wedge_threshold() {
  local home probe
  home=$(make_home escalate)
  carrier "$home" logbook 'export FM_CHECK_INTERVAL=15' 'export FM_STALE_ESCALATE_SECS=900'
  probe=$(arm_probe "$home")
  assert_contains "$probe" "escalate=900" "an armed watcher did not inherit the carrier's wedge threshold"
  pass "a carrier can also raise the wedge-escalation threshold"
}

test_another_homes_carriers_are_not_inherited() {
  local other home probe
  other=$(make_home other-home)
  carrier "$other" logbook 'export FM_CHECK_INTERVAL=15'
  home=$(make_home own-home)
  # Same machine, same repo, a carrier next door - and nothing in this home.
  probe=$(arm_probe "$home")
  assert_contains "$probe" "interval=UNSET" "a watcher inherited another home's cadence carrier"
  assert_not_contains "$probe" "interval=15" "a watcher inherited another home's cadence carrier"
  pass "carriers stay per-home: another home's config never applies"
}

test_explicit_environment_wins_over_a_carrier() {
  local home probe
  home=$(make_home explicit-env)
  carrier "$home" logbook 'export FM_CHECK_INTERVAL=15'
  probe=$(arm_probe "$home" FM_CHECK_INTERVAL=7)
  assert_contains "$probe" "interval=7" "an explicit FM_CHECK_INTERVAL lost to a carrier"
  pass "an explicit environment value wins over a carrier"
}

test_unreadable_carrier_content_is_ignored_not_executed() {
  local home probe marker
  home=$(make_home hostile)
  marker="$home/state/carrier-was-executed"
  # A carrier that would kill the arm outright if it were ever sourced.
  carrier "$home" broken \
    "printf x > '$marker'" \
    'if [ -z' \
    'export FM_CHECK_INTERVAL=15' \
    'exit 3'
  probe=$(arm_probe "$home")
  assert_contains "$probe" "interval=15" "the declaration in a malformed carrier was not applied"
  assert_absent "$marker" "carrier content was executed instead of read"
  pass "a carrier is read by pattern, so malformed content cannot break the arm"
}

test_non_env_files_in_the_carrier_directory_are_ignored() {
  local home probe
  home=$(make_home non-env)
  printf 'export FM_CHECK_INTERVAL=15\n' > "$home/config/check-cadence.d/notes.txt"
  mkdir -p "$home/config/check-cadence.d/nested.env"
  printf 'export FM_CHECK_INTERVAL=9\n' > "$home/config/check-cadence.d/nested.env/inner.env"
  probe=$(arm_probe "$home")
  assert_contains "$probe" "interval=UNSET" "a non-.env file or a directory was treated as a carrier"
  pass "only .env files directly in the carrier directory are carriers"
}

test_missing_carrier_directory_is_not_an_error() {
  local home probe
  home=$(make_home no-dir)
  rmdir "$home/config/check-cadence.d"
  probe=$(arm_probe "$home")
  assert_contains "$probe" "interval=UNSET" "a home with no carrier directory did not use the default cadence"
  pass "a home with no carrier directory arms normally"
}

test_codex_checkpoint_applies_carriers_too() {
  local home out status
  home=$(make_home checkpoint)
  carrier "$home" logbook 'export FM_CHECK_INTERVAL=15'
  status=0
  out=$(FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 20 2>&1) || status=$?
  expect_code 0 "$status" "checkpoint exit with an actionable check wake"
  assert_contains "$out" "interval=15" "the Codex checkpoint's watcher did not inherit the carrier"
  pass "the Codex foreground checkpoint applies carriers on the same terms"
}

test_carrier_reaches_the_armed_watcher
test_snappiest_carrier_wins
test_carrier_carries_the_wedge_threshold
test_another_homes_carriers_are_not_inherited
test_explicit_environment_wins_over_a_carrier
test_unreadable_carrier_content_is_ignored_not_executed
test_non_env_files_in_the_carrier_directory_are_ignored
test_missing_carrier_directory_is_not_an_error
test_codex_checkpoint_applies_carriers_too
