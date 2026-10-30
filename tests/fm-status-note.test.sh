#!/usr/bin/env bash
# tests/fm-status-note.test.sh - bin/fm-status-note.sh writes exactly one
# firstmate-marked line that leaves the watcher's announced baseline intact,
# refuses rather than writing a line that would close nothing or stray outside
# a real task log, and never hides a worker's still-unannounced line.
#
# The end-to-end proof that the watcher stays quiet for such a note and still
# wakes for a later worker line lives in fm-watch-triage.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

NOTE="$ROOT/bin/fm-status-note.sh"
TMP_ROOT=$(fm_test_tmproot fm-status-note-tests)

make_state() {  # <name>
  local state="$TMP_ROOT/$1/state"
  mkdir -p "$state"
  printf '%s\n' "$state"
}

run_note() {  # <state> <args...>
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" "$NOTE" "$@"
}

announced() {  # <state> <file>
  FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

test_note_is_one_marked_line_and_stays_announced() {
  local state status
  state=$(make_state note-one-line)
  status="$state/t.status"
  printf 'working: setup complete\n' > "$status"
  prime_status_seen "$state" "$status" || fail "could not prime the announced baseline"
  run_note "$state" t "$(printf 'captain chose B\nblocked: not a second line\tok')" \
    || fail "a memo on an announced log was refused"
  [ "$(wc -l < "$status" | tr -d ' ')" -eq 2 ] || fail "a multi-line memo wrote more than one status line"
  grep -Fxq 'note: firstmate: captain chose B blocked: not a second line ok' "$status" \
    || fail "the memo was not one firstmate-marked note line: $(cat "$status")"
  announced "$state" "$status" || fail "the memo left unannounced bytes for the watcher"
  pass "a memo is one firstmate-marked line and leaves the log announced"
}

test_resolve_closes_only_an_open_key() {
  local state status rc
  state=$(make_state resolve-open-key)
  status="$state/t.status"
  printf 'needs-decision [key=api]: REST or RPC\n' > "$status"
  prime_status_seen "$state" "$status" || fail "could not prime the announced baseline"
  rc=0
  run_note "$state" --resolve other t 'mistyped key' 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "a close for a key that is not open was not refused (rc=$rc)"
  grep -Fq 'mistyped key' "$status" && fail "a refused close still wrote a line"
  run_note "$state" --resolve api t 'went with REST' || fail "a close for an open key was refused"
  grep -Fxq 'resolved [key=api]: firstmate: went with REST' "$status" \
    || fail "the close was not a firstmate-marked resolution: $(cat "$status")"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    [ -z "$(status_open_decisions "$2")" ]
  ' _ "$ROOT/bin/fm-classify-lib.sh" "$status" || fail "the close did not close the open decision"
  announced "$state" "$status" || fail "the close left unannounced bytes for the watcher"
  pass "a by-hand close is refused for a key that is not open and closes one that is"
}

test_resolve_refuses_a_reserved_key() {
  local state status rc
  state=$(make_state resolve-reserved)
  status="$state/t.status"
  printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-opened: waiting on the mate\n' > "$status"
  rc=0
  run_note "$state" --resolve pending-reply-abcdef0123456789 t 'closing by hand' 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "a by-hand close of a reserved key was not refused (rc=$rc)"
  [ "$(wc -l < "$status" | tr -d ' ')" -eq 1 ] || fail "a refused reserved-key close still wrote a line"
  pass "a by-hand close refuses a key only its owning library may close"
}

test_refuses_without_a_task_log() {
  local state rc
  state=$(make_state no-log)
  rc=0
  run_note "$state" missing 'a memo' 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "a memo for a task with no log was not refused (rc=$rc)"
  [ ! -e "$state/missing.status" ] || fail "a refused memo created a stray status log"
  rc=0
  run_note "$state" '../escape' 'a memo' 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "a task id with a path separator was not refused (rc=$rc)"
  printf 'working: setup\n' > "$state/t.status"
  rc=0
  run_note "$state" t '   ' 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "an empty memo was not refused (rc=$rc)"
  [ "$(wc -l < "$state/t.status" | tr -d ' ')" -eq 1 ] || fail "a refused empty memo still wrote a line"
  pass "a memo is refused without a real task log, a slug task id, or any text"
}

test_pending_worker_line_still_wakes() {
  local state status err
  state=$(make_state pending-worker-line)
  status="$state/t.status"
  err="$TMP_ROOT/pending-worker-line/err"
  printf 'working: setup\n' > "$status"
  prime_status_seen "$state" "$status" || fail "could not prime the announced baseline"
  printf 'done: PR https://example.test/pr/1\n' >> "$status"
  run_note "$state" t 'noted the PR' 2> "$err" || fail "a memo over a pending worker line was refused"
  grep -Fxq 'note: firstmate: noted the PR' "$status" || fail "the memo was not appended"
  announced "$state" "$status" && fail "a memo hid the worker's still-unannounced line"
  grep -Fq 'monitoring will still surface it' "$err" \
    || fail "the memo did not say the log is left for monitoring: $(cat "$err")"
  pass "a memo over a worker's unannounced line leaves the log to wake as before"
}

test_note_is_one_marked_line_and_stays_announced
test_resolve_closes_only_an_open_key
test_resolve_refuses_a_reserved_key
test_refuses_without_a_task_log
test_pending_worker_line_still_wakes

echo "# fm-status-note.test.sh: all assertions passed"
