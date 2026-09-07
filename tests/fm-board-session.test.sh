#!/usr/bin/env bash
# tests/fm-board-session.test.sh - behavior tests for bin/fm-board-session-lib.sh,
# which publishes state/board-session.json so a board can wake this session by
# session id instead of by a name a person has to set by hand.
#
# Coverage:
#   - both identity routes and the record shape, pinned case by case against
#     tests/fixtures/board-session/cases.json, the shared statement of this
#     cross-repo contract (docs/architecture.md, "Cross-repo contracts are
#     stated as fixtures")
#   - the environment route prefers the pid the harness names, and falls back to
#     the lock's when that process is not running
#   - the liveness rule, driven against real processes: a matching start time
#     publishes, a corpse entry whose pid was recycled does not
#   - the pid-domain half of that rule: this machine's own domain publishes, a
#     foreign one is refused, and a host whose machine id cannot be read skips
#     the test rather than refusing every entry
#   - registry values: non-ASCII text publishes whatever the locale, a control
#     character is refused
#   - refusal leaves any prior record untouched and no temp file behind
#   - the record is written atomically and mode 0600
#   - the registry directory resolves from CLAUDE_CONFIG_DIR
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# This suite runs inside a real session that exports these, and every case sets
# exactly the ones it means to drive. Clearing them first is what keeps the
# surrounding session from deciding a case's route.
unset CLAUDE_CODE_SESSION_ID CLAUDE_PID

# shellcheck source=/dev/null
. "$ROOT/bin/fm-board-session-lib.sh"

FIXTURE="$ROOT/tests/fixtures/board-session/cases.json"
[ -f "$FIXTURE" ] || fail "missing fixture: $FIXTURE"
jq -e . "$FIXTURE" >/dev/null 2>&1 || fail "fixture is not valid JSON: $FIXTURE"

TMP_ROOT=$(fm_test_tmproot fm-board-session-tests)
LIVE_PIDS=()
board_session_cleanup() {
  local pid
  for pid in "${LIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap board_session_cleanup EXIT

# start_live_process sets LIVE_PID to a real process this suite owns, so the
# liveness rule is exercised against the kernel rather than a stub that could
# only confirm its own assumption.
#
# Its stdout is detached, because a background child holding this script's pipe
# open keeps the runner waiting long after the last assertion. It sets a global
# rather than echoing, because a command substitution would register the child
# for cleanup in a subshell and lose it.
LIVE_PID=
start_live_process() {
  sleep 120 >/dev/null 2>&1 &
  LIVE_PID=$!
  LIVE_PIDS+=("$LIVE_PID")
}

# The start time the registry records for <pid>: /proc/<pid>/stat field 22,
# counted from after comm's closing paren because comm may hold spaces.
proc_start() {  # <pid>
  local stat rest
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  rest=${stat##*') '}
  printf '%s\n' "$rest" | awk '{print $20}'
}

# --- the record shape, case by case against the shared fixture ---------------

REGISTRY="$TMP_ROOT/registry"
STATE="$TMP_ROOT/state"
mkdir -p "$REGISTRY" "$STATE"

# One live process stands in for the session across every case: the entry is
# keyed by its pid and rewritten per case, so a second process would prove
# nothing the first does not.
CASES=$(jq -r '.cases[].name' "$FIXTURE")
CASE_COUNT=0
start_live_process
pid=$LIVE_PID
while IFS= read -r name; do
  [ -n "$name" ] || continue
  CASE_COUNT=$((CASE_COUNT + 1))
  rm -f "$STATE/board-session.json" "$REGISTRY/$pid.json"

  entry=$(jq -c --arg name "$name" --arg pid "$pid" \
    '(.cases[] | select(.name == $name) | .entry)
     | if . == null then null
       else with_entries(.value |= (if . == "{{PID}}" then ($pid | tonumber) else . end))
       end' "$FIXTURE")
  [ "$entry" = null ] || printf '%s\n' "$entry" > "$REGISTRY/$pid.json"

  # The case's own environment, and nothing the surrounding session left behind.
  unset CLAUDE_CODE_SESSION_ID CLAUDE_PID
  while IFS='=' read -r key value; do
    [ -n "$key" ] || continue
    case "$key" in
      CLAUDE_CODE_SESSION_ID) export CLAUDE_CODE_SESSION_ID="$value" ;;
      CLAUDE_PID) export CLAUDE_PID="$value" ;;
      *) fail "$name: the fixture sets an environment variable this suite does not drive: $key" ;;
    esac
  done <<EOC
$(jq -r --arg name "$name" --arg pid "$pid" \
  '(.cases[] | select(.name == $name) | .env // {})
   | to_entries[]
   | "\(.key)=\(if .value == "{{PID}}" then $pid else .value end)"' "$FIXTURE")
EOC

  want=$(jq -c --arg name "$name" --arg pid "$pid" \
    '(.cases[] | select(.name == $name) | .expect)
     | if . == null then null
       else with_entries(.value |= (if . == "{{PID}}" then ($pid | tonumber) else . end))
       end' "$FIXTURE")

  # A lock pid that is deliberately not this process, so a case that publishes
  # the live pid can only have got it from CLAUDE_PID or from the entry key.
  status=0
  reason=$(fm_board_session_publish "$STATE" "$pid" "$REGISTRY") || status=$?

  if [ "$want" = null ]; then
    [ "$status" -ne 0 ] || fail "$name: a refused identity was published anyway"
    assert_absent "$STATE/board-session.json" "$name: a refused identity left a record"
    [ -n "$reason" ] || fail "$name: a refusal said nothing about what it could not confirm"
    continue
  fi

  expect_code 0 "$status" "$name: the identity was refused ($reason)"
  assert_present "$STATE/board-session.json" "$name: no record was written"
  jq -e . "$STATE/board-session.json" >/dev/null 2>&1 \
    || fail "$name: the record is not valid JSON: $(cat "$STATE/board-session.json")"

  # One line, so a reader can take the record cheaply.
  [ "$(wc -l < "$STATE/board-session.json")" -eq 1 ] \
    || fail "$name: the record is not exactly one line"

  # Every field the fixture states, and no field it does not - registered_at
  # excepted, which is asserted for shape rather than value.
  got=$(jq -cS 'del(.registered_at)' "$STATE/board-session.json")
  [ "$got" = "$(printf '%s' "$want" | jq -cS .)" ] \
    || fail "$name: record mismatch"$'\n'"want: $want"$'\n'"got:  $got"

  stamp=$(jq -r '.registered_at' "$STATE/board-session.json")
  printf '%s\n' "$stamp" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || fail "$name: registered_at is not ISO-8601 UTC: $stamp"
done <<EOF
$CASES
EOF
unset CLAUDE_CODE_SESSION_ID CLAUDE_PID

[ "$CASE_COUNT" -eq "$(jq '.cases | length' "$FIXTURE")" ] \
  || fail "not every fixture case ran: $CASE_COUNT of $(jq '.cases | length' "$FIXTURE")"

# Both routes are actually reached, so neither can go quietly vacuous if the
# resolution order changes underneath the shape assertions above.
for route in environment registry; do
  jq -e --arg r "$route" 'any(.cases[]; .expect != null and .expect.source == $r)' \
    "$FIXTURE" >/dev/null || fail "the fixture states no case for the $route route"
done
pass "every state/board-session.json case in the shared fixture is produced exactly"

# --- the liveness rule, against real processes -------------------------------

# A corpse entry whose pid the kernel has since handed to another process would,
# if published, name a dead session that every wake reaches nothing through -
# the exact silent failure this record exists to end. The start time is what
# separates the two, so drive it apart from the recorded one deliberately.
test_start_time_separates_this_session_from_a_recycled_pid() {
  local dir state pid start status reason
  dir="$TMP_ROOT/liveness-registry"
  state="$TMP_ROOT/liveness-state"
  mkdir -p "$dir" "$state"
  start_live_process
  pid=$LIVE_PID
  start=$(proc_start "$pid") || { echo "skip: /proc is unreadable here"; return 0; }
  [ -n "$start" ] || fail "could not read the start time of a live process"

  printf '{"pid":%s,"sessionId":"aaaaaaaa-1111-2222-3333-444444444444","cwd":"/tmp","kind":"interactive","procStart":"%s","name":"fm-test","nameSource":"derived"}\n' \
    "$pid" "$start" > "$dir/$pid.json"
  fm_board_session_publish "$state" "$pid" "$dir" >/dev/null \
    || fail "an entry whose start time matches the live process was refused"
  assert_grep 'aaaaaaaa-1111-2222-3333-444444444444' "$state/board-session.json" \
    "the published record does not name the session"
  pass "an entry whose recorded start time matches the live pid is published"

  # Same live pid, a start time that is not this process's: a corpse.
  printf '{"pid":%s,"sessionId":"bbbbbbbb-1111-2222-3333-444444444444","cwd":"/tmp","kind":"interactive","procStart":"%s","name":"fm-test","nameSource":"derived"}\n' \
    "$pid" "$((start + 1))" > "$dir/$pid.json"
  status=0
  reason=$(fm_board_session_publish "$state" "$pid" "$dir") || status=$?
  [ "$status" -ne 0 ] || fail "a corpse entry for a recycled pid was published"
  assert_contains "$reason" "stale" "the refusal does not say the entry is stale"

  # The refusal left the record it could not replace exactly as it was, so a
  # board keeps waking the session that is actually running.
  assert_grep 'aaaaaaaa-1111-2222-3333-444444444444' "$state/board-session.json" \
    "a refusal overwrote or removed the previously published record"
  assert_no_grep 'bbbbbbbb-1111-2222-3333-444444444444' "$state/board-session.json" \
    "a refused entry reached the record"
  pass "a corpse entry for a recycled pid is refused and leaves the standing record intact"
}

test_a_dead_pid_is_refused() {
  local dir state pid status reason
  dir="$TMP_ROOT/dead-registry"
  state="$TMP_ROOT/dead-state"
  mkdir -p "$dir" "$state"
  # A child that exits on its own, rather than one killed here: a background
  # child forked from this shell still carries its TERM trap until it execs, so
  # killing it immediately can run this suite's own cleanup inside it. `bash -c`
  # execs at once and drops every inherited trap with it.
  bash -c 'exit 0' >/dev/null 2>&1 &
  pid=$!
  wait "$pid" 2>/dev/null || true
  printf '{"pid":%s,"sessionId":"cccccccc-1111-2222-3333-444444444444","kind":"interactive"}\n' \
    "$pid" > "$dir/$pid.json"
  status=0
  reason=$(fm_board_session_publish "$state" "$pid" "$dir") || status=$?
  [ "$status" -ne 0 ] || fail "an entry for a dead pid was published"
  assert_contains "$reason" "stale" "the refusal does not say the entry is stale"
  assert_absent "$state/board-session.json" "a dead session left a record"
  pass "an entry whose pid is gone is refused"
}

test_a_missing_entry_is_refused_and_names_where_it_looked() {
  local dir state pid status reason
  dir="$TMP_ROOT/missing-registry"
  state="$TMP_ROOT/missing-state"
  mkdir -p "$dir" "$state"
  start_live_process
  pid=$LIVE_PID
  status=0
  reason=$(fm_board_session_publish "$state" "$pid" "$dir") || status=$?
  [ "$status" -ne 0 ] || fail "a session with no registry entry was published"
  assert_absent "$state/board-session.json" "an unregistered session left a record"
  assert_contains "$reason" "$dir" "the refusal does not name the directory it looked in"
  pass "a session with no registry entry is refused and says where it looked"
}

# The record carries this home's session identity and is written into a
# gitignored state directory, so it is owner-only, and it is renamed into place
# rather than truncated: a reader must never catch it half-written.
test_the_record_is_owner_only_and_written_atomically() {
  local dir state pid mode leftovers
  dir="$TMP_ROOT/atomic-registry"
  state="$TMP_ROOT/atomic-state"
  mkdir -p "$dir" "$state"
  start_live_process
  pid=$LIVE_PID
  printf '{"pid":%s,"sessionId":"dddddddd-1111-2222-3333-444444444444","kind":"interactive"}\n' \
    "$pid" > "$dir/$pid.json"
  fm_board_session_publish "$state" "$pid" "$dir" >/dev/null || fail "the record was not published"

  mode=$(stat -c %a "$state/board-session.json" 2>/dev/null || stat -f %Lp "$state/board-session.json")
  [ "$mode" = 600 ] || fail "the record is mode $mode, not 600"

  leftovers=$(find "$state" -name '.fm-board-session.*' 2>/dev/null)
  [ -z "$leftovers" ] || fail "a staging file was left behind: $leftovers"

  # Republishing over a standing record replaces it in place, still owner-only.
  printf '{"pid":%s,"sessionId":"eeeeeeee-1111-2222-3333-444444444444","kind":"interactive"}\n' \
    "$pid" > "$dir/$pid.json"
  fm_board_session_publish "$state" "$pid" "$dir" >/dev/null || fail "the record was not refreshed"
  assert_grep 'eeeeeeee-1111-2222-3333-444444444444' "$state/board-session.json" \
    "the refreshed record does not name the current session"
  mode=$(stat -c %a "$state/board-session.json" 2>/dev/null || stat -f %Lp "$state/board-session.json")
  [ "$mode" = 600 ] || fail "the refreshed record is mode $mode, not 600"
  pass "the record is owner-only and replaced by rename, leaving no staging file"
}

# A session that registered under its own CLAUDE_CONFIG_DIR must still be found,
# which is the case a board spawned from a different environment depends on.
test_the_registry_directory_follows_claude_config_dir() {
  local cfg state pid
  cfg="$TMP_ROOT/config-dir"
  state="$TMP_ROOT/config-dir-state"
  mkdir -p "$cfg/sessions" "$state"
  start_live_process
  pid=$LIVE_PID
  printf '{"pid":%s,"sessionId":"ffffffff-1111-2222-3333-444444444444","kind":"interactive"}\n' \
    "$pid" > "$cfg/sessions/$pid.json"
  [ "$(CLAUDE_CONFIG_DIR="$cfg" fm_board_session_registry_dir)" = "$cfg/sessions" ] \
    || fail "the registry directory does not follow CLAUDE_CONFIG_DIR"
  CLAUDE_CONFIG_DIR="$cfg" fm_board_session_publish "$state" "$pid" >/dev/null \
    || fail "the entry under CLAUDE_CONFIG_DIR was not found"
  assert_grep 'ffffffff-1111-2222-3333-444444444444' "$state/board-session.json" \
    "the record does not name the session registered under CLAUDE_CONFIG_DIR"
  pass "the registry directory resolves from CLAUDE_CONFIG_DIR"
}

# CLAUDE_PID names the session process directly, so it is preferred over the pid
# the ancestry walk inferred - but only while that process is actually running.
# A dead one is not this session, so it must not decide which entry is read.
test_the_named_session_process_is_preferred_and_a_dead_one_is_dropped() {
  local dir state pid dead
  dir="$TMP_ROOT/named-pid-registry"
  state="$TMP_ROOT/named-pid-state"
  mkdir -p "$dir" "$state"
  start_live_process
  pid=$LIVE_PID
  bash -c 'exit 0' >/dev/null 2>&1 &
  dead=$!
  wait "$dead" 2>/dev/null || true

  # Two entries: one under the named process, one under the lock's pid. Only the
  # named one may be read.
  printf '{"pid":%s,"sessionId":"11110000-0000-4000-8000-000000000001","kind":"interactive"}\n' \
    "$pid" > "$dir/$pid.json"
  printf '{"pid":%s,"sessionId":"22220000-0000-4000-8000-000000000002","kind":"interactive"}\n' \
    "$dead" > "$dir/$dead.json"

  export CLAUDE_PID="$pid"
  unset CLAUDE_CODE_SESSION_ID
  fm_board_session_publish "$state" "$dead" "$dir" >/dev/null \
    || fail "the named session process was not used"
  assert_grep '"pid":'"$pid" "$state/board-session.json" \
    "the record does not name the process the harness named"
  assert_grep '11110000-0000-4000-8000-000000000001' "$state/board-session.json" \
    "the record was not read from the named process's entry"

  # The named process is gone: fall back to the lock's pid rather than reading a
  # registry entry that belongs to nothing running.
  export CLAUDE_PID="$dead"
  fm_board_session_publish "$state" "$pid" "$dir" >/dev/null \
    || fail "the lock's pid was not used once the named process was gone"
  assert_grep '"pid":'"$pid" "$state/board-session.json" \
    "the record does not fall back to the pid the session lock holds"
  assert_grep '11110000-0000-4000-8000-000000000001' "$state/board-session.json" \
    "the fallback did not read the lock pid's entry"
  unset CLAUDE_PID
  pass "a running named session process is preferred, and a dead one falls back to the lock's pid"
}

# The pid domain pins an entry to the machine and pid namespace it was written
# in, so a matching one publishes and a foreign one is a record from somewhere
# else and is refused. A host whose machine id cannot be read - a container,
# typically - cannot evaluate that test at all, so it must fall back to the other
# two rather than refuse every entry that carries a domain as stale.
test_pid_domain_pins_this_machine_and_degrades_without_a_machine_id() {
  local dir state pid machine_id ns fakebin real_cat status reason
  dir="$TMP_ROOT/domain-registry"
  state="$TMP_ROOT/domain-state"
  fakebin="$TMP_ROOT/domain-fakebin"
  mkdir -p "$dir" "$state" "$fakebin"
  machine_id=$(cat /etc/machine-id 2>/dev/null) || machine_id=
  ns=$(readlink /proc/self/ns/pid 2>/dev/null) || ns=
  start_live_process
  pid=$LIVE_PID

  if [ -n "$machine_id" ] && [ -n "$ns" ]; then
    printf '{"pid":%s,"sessionId":"aaaa1111-0000-4000-8000-000000000001","kind":"interactive","pidDomain":"linux:%s:%s"}\n' \
      "$pid" "$machine_id" "$ns" > "$dir/$pid.json"
    fm_board_session_publish "$state" "$pid" "$dir" >/dev/null \
      || fail "an entry recorded in this machine's own pid domain was refused"
    assert_grep 'aaaa1111-0000-4000-8000-000000000001' "$state/board-session.json" \
      "the record does not name the session recorded in this pid domain"
    pass "an entry recorded in this machine's own pid domain is published"

    printf '{"pid":%s,"sessionId":"bbbb1111-0000-4000-8000-000000000002","kind":"interactive","pidDomain":"linux:%s:%s"}\n' \
      "$pid" "00000000000000000000000000000000" "$ns" > "$dir/$pid.json"
    status=0
    reason=$(fm_board_session_publish "$state" "$pid" "$dir") || status=$?
    [ "$status" -ne 0 ] || fail "an entry recorded on another machine was published"
    assert_contains "$reason" "stale" "the refusal does not say the entry is stale"
    assert_grep 'aaaa1111-0000-4000-8000-000000000001' "$state/board-session.json" \
      "a refused foreign-domain entry replaced or removed the standing record"
    pass "an entry recorded in another machine's pid domain is refused as stale"
  else
    echo "skip: this host's machine id or pid namespace is unreadable, so only the degraded half runs"
  fi

  # The same foreign domain on a host that cannot read its machine id: the
  # comparison has nothing to be made against, so it is skipped and the entry
  # stands on the pid and start-time tests alone.
  printf '{"pid":%s,"sessionId":"cccc1111-0000-4000-8000-000000000003","kind":"interactive","pidDomain":"linux:%s:%s"}\n' \
    "$pid" "00000000000000000000000000000000" "${ns:-pid:[0]}" > "$dir/$pid.json"
  if [ -n "$machine_id" ]; then
    real_cat=$(command -v cat)
    cat > "$fakebin/cat" <<SH
#!/usr/bin/env bash
for argument in "\$@"; do [ "\$argument" = /etc/machine-id ] && exit 1; done
exec $real_cat "\$@"
SH
    chmod +x "$fakebin/cat"
    "$fakebin/cat" /etc/machine-id >/dev/null 2>&1 \
      && fail "the fixture that hides the machine id still reads it"
    status=0
    reason=$(PATH="$fakebin:$PATH" fm_board_session_publish "$state" "$pid" "$dir") || status=$?
  else
    status=0
    reason=$(fm_board_session_publish "$state" "$pid" "$dir") || status=$?
  fi
  expect_code 0 "$status" "an entry carrying a pid domain was refused on a host whose machine id cannot be read ($reason)"
  assert_grep 'cccc1111-0000-4000-8000-000000000003' "$state/board-session.json" \
    "the record does not name the session published without a readable machine id"
  pass "an entry carrying a pid domain still publishes when the machine id cannot be read"
}

# A registry cwd is a path, and the derived name is that path's basename, so a
# home under a directory with a non-ASCII character in its name must register
# whatever locale the SessionStart hook runs under; the C locale, where every
# non-ASCII byte is non-printable, is the one to drive. A control character is
# the case the narrow reader cannot represent, and stays refused.
test_non_ascii_registry_values_publish_and_control_characters_refuse() {
  local dir state pid status reason
  dir="$TMP_ROOT/charset-registry"
  state="$TMP_ROOT/charset-state"
  mkdir -p "$dir" "$state"
  start_live_process
  pid=$LIVE_PID

  printf '{"pid":%s,"sessionId":"dddd1111-0000-4000-8000-000000000004","cwd":"/home/jörg/firstmate","kind":"interactive","name":"firstmate-ö7c","nameSource":"derived"}\n' \
    "$pid" > "$dir/$pid.json"
  status=0
  reason=$( (export LC_ALL=C; fm_board_session_publish "$state" "$pid" "$dir") ) || status=$?
  expect_code 0 "$status" "an entry whose cwd holds a non-ASCII character was refused under the C locale ($reason)"
  assert_grep '"cwd":"/home/jörg/firstmate"' "$state/board-session.json" \
    "the record does not carry the non-ASCII path as the registry wrote it"
  assert_grep '"name":"firstmate-ö7c"' "$state/board-session.json" \
    "the record does not carry the non-ASCII name as the registry wrote it"
  jq -e . "$state/board-session.json" >/dev/null 2>&1 \
    || fail "the record holding non-ASCII text is not valid JSON: $(cat "$state/board-session.json")"
  rm -f "$state/board-session.json"
  fm_board_session_publish "$state" "$pid" "$dir" >/dev/null \
    || fail "an entry whose cwd holds a non-ASCII character was refused under the suite's own locale"
  assert_grep 'dddd1111-0000-4000-8000-000000000004' "$state/board-session.json" \
    "the record does not name the session with the non-ASCII path"
  pass "an entry holding non-ASCII text is published under the C locale and under the suite's own"

  printf '{"pid":%s,"sessionId":"eeee1111-0000-4000-8000-000000000005","cwd":"/home/captain/first\tmate","kind":"interactive"}\n' \
    "$pid" > "$dir/$pid.json"
  status=0
  reason=$(fm_board_session_publish "$state" "$pid" "$dir") || status=$?
  [ "$status" -ne 0 ] || fail "an entry whose cwd holds a control character was published"
  assert_contains "$reason" "cannot represent" "the refusal does not say the value cannot be represented"
  assert_grep 'dddd1111-0000-4000-8000-000000000004' "$state/board-session.json" \
    "a refused control-character entry replaced or removed the standing record"
  assert_no_grep 'eeee1111-0000-4000-8000-000000000005' "$state/board-session.json" \
    "a refused control-character entry reached the record"
  pass "an entry holding a control character is refused and leaves the standing record intact"
}

test_start_time_separates_this_session_from_a_recycled_pid
test_pid_domain_pins_this_machine_and_degrades_without_a_machine_id
test_non_ascii_registry_values_publish_and_control_characters_refuse
test_a_dead_pid_is_refused
test_the_named_session_process_is_preferred_and_a_dead_one_is_dropped
test_a_missing_entry_is_refused_and_names_where_it_looked
test_the_record_is_owner_only_and_written_atomically
test_the_registry_directory_follows_claude_config_dir
