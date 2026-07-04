#!/usr/bin/env bash
# Behavior tests for the logbook attention-board client: config resolution
# (fm-logbook-lib.sh), the feed/reconcile/clear posters (fm-logbook-push.sh,
# fm-logbook-sync.sh, fm-logbook-resolve.sh), the detached server launcher
# (fm-logbook-up.sh), and bootstrap's config-presence activation (logbook_setup).
#
# Logbook must be INERT by default (no config -> the up launcher is a hard no-op
# and bootstrap writes/prints nothing) and additive when on. Crucially, Phase 0+1
# is READ-ONLY: opting in drops NO watcher poll shim and writes NO cadence file
# (that inbound answer-loop is a later phase) - these tests assert that explicitly.
# The network is stubbed with a fakebin `curl` so these stay hermetic: no ports, no
# server, deterministic in CI. jq stays the real tool. No real projects/logbook
# clone or live server is required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
# The client under test uses the real jq; make it resolvable regardless of where it
# is installed (Homebrew, Nix profile bins, etc.). Prepended after the fakebin so a
# fake curl still wins.
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-logbook-tests)

# A fakebin `curl` that mimics the board: /health returns FAKE_HEALTH_CODE (default
# 200); a POST to /api/* returns FAKE_POST_CODE (default 200). Each call is recorded
# to FAKE_CURL_LOG (url, auth header, streamed body, full argv) so a test can assert
# the request shape and prove no token leaks into argv.
make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" method=GET data="" url="" auth=""
argv=$*
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -X) method=$2; shift 2 ;;
    --data-binary)
      case "$2" in
        @-) data=$(cat) ;;
        @*) data=$(cat -- "${2#@}") ;;
        *) data=$2 ;;
      esac
      shift 2
      ;;
    -H)
      case "$2" in
        @*) while IFS= read -r header; do case "$header" in Authorization:*) auth=$header ;; esac; done < "${2#@}" ;;
        Authorization:*) auth=$2 ;;
      esac
      shift 2
      ;;
    -m|-w) shift 2 ;;
    -s) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ -n "${FAKE_CURL_LOG:-}" ]; then
  { echo "argv=$argv"; echo "method=$method"; echo "url=$url"; echo "auth=$auth"; echo "data=$data"; } >> "$FAKE_CURL_LOG"
fi
case "$url" in
  */health) [ -n "$ofile" ] && : > "$ofile"; printf '%s' "${FAKE_HEALTH_CODE:-200}" ;;
  */api/*) [ -n "$ofile" ] && : > "$ofile"; printf '%s' "${FAKE_POST_CODE:-200}" ;;
  *) printf '000' ;;
esac
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# Resolve the config in a child and print URL|PORT|TOOL_DIR|ENABLE|TOKEN|DRY.
resolve_cfg() {
  bash -c '. "'"$ROOT"'/bin/fm-logbook-lib.sh"; logbook_load_config
    printf "%s|%s|%s|%s|%s|%s" "$LOGBOOK_URL" "$LOGBOOK_PORT" "$LOGBOOK_TOOL_DIR" "$LOGBOOK_ENABLE" "$LOGBOOK_TOKEN" "$LOGBOOK_DRY"'
}

# ---------------------------------------------------------------------------

test_config_defaults() {
  local home out
  home="$TMP_ROOT/cfg-defaults"; mkdir -p "$home"
  # No config file at all: URL/port/tool-dir take their documented defaults.
  out=$(FM_HOME="$home" PATH="$BASE_PATH" resolve_cfg)
  assert_contains "$out" "http://127.0.0.1:8137|8137|$home/projects/logbook||" \
    "defaults: loopback URL, port 8137, projects/logbook tool dir, empty enable/token"
  pass "logbook config resolves documented defaults with no config file"
}

test_config_from_file() {
  local home out
  home="$TMP_ROOT/cfg-file"; mkdir -p "$home/config"
  cat > "$home/config/logbook.env" <<'EOF'
LOGBOOK_ENABLE=1
LOGBOOK_URL=http://127.0.0.1:9999/
LOGBOOK_TOKEN=filetok
LOGBOOK_PORT=9999
LOGBOOK_TOOL_DIR=/opt/logbook
EOF
  out=$(FM_HOME="$home" PATH="$BASE_PATH" resolve_cfg)
  # Trailing slash on the URL is trimmed so callers can append paths cleanly.
  assert_contains "$out" "http://127.0.0.1:9999|9999|/opt/logbook|1|filetok|" \
    "config file values are used and the URL slash is trimmed"
  pass "logbook config reads config/logbook.env"
}

test_config_env_wins_over_file() {
  local home out
  home="$TMP_ROOT/cfg-env"; mkdir -p "$home/config"
  cat > "$home/config/logbook.env" <<'EOF'
LOGBOOK_ENABLE=1
LOGBOOK_URL=http://127.0.0.1:9999
LOGBOOK_TOKEN=filetok
LOGBOOK_PORT=9999
LOGBOOK_TOOL_DIR=/opt/logbook
EOF
  out=$(FM_HOME="$home" LOGBOOK_URL=http://127.0.0.1:7000 LOGBOOK_PORT=7000 \
    LOGBOOK_TOKEN=envtok LOGBOOK_TOOL_DIR=/env/dir PATH="$BASE_PATH" resolve_cfg)
  assert_contains "$out" "http://127.0.0.1:7000|7000|/env/dir|1|envtok|" \
    "an explicit environment value wins over config/logbook.env"
  pass "logbook config lets the environment override the file"
}

test_config_empty_env_url_falls_back_to_default() {
  local home out
  home="$TMP_ROOT/cfg-empty-url"; mkdir -p "$home/config"
  printf 'LOGBOOK_URL=http://127.0.0.1:9999\n' > "$home/config/logbook.env"
  # An explicitly empty env URL overrides the file and falls back to the default,
  # mirroring fmx relay resolution.
  out=$(FM_HOME="$home" LOGBOOK_URL='' PATH="$BASE_PATH" resolve_cfg)
  assert_contains "$out" "http://127.0.0.1:8137|" \
    "an explicitly empty env URL falls back to the loopback default"
  pass "logbook config falls back to the default URL for an empty env override"
}

test_push_dry_run_records_no_network_no_token() {
  local home fakebin log out rc
  home="$TMP_ROOT/push-dry"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  # Dry-run, NO token: it must compose the body, record it, and never call curl.
  out=$(printf '%s' '{"id":"aura-x9","kind":"decision","title":"Two findings need a call","options":[{"label":"Fix","value":"fix"}]}' \
    | PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-logbook-push.sh" - 2>"$home/err"); rc=$?
  expect_code 0 "$rc" "push dry-run exit"
  [ ! -f "$log" ] || fail "push dry-run must not call curl (no network)"
  assert_present "$home/state/logbook-outbox/items.json" "push dry-run must record the would-be body"
  [ "$(jq -r .id "$home/state/logbook-outbox/items.json")" = "aura-x9" ] \
    || fail "recorded push body must preserve the item id"
  [ "$(jq -r .title "$home/state/logbook-outbox/items.json")" = "Two findings need a call" ] \
    || fail "recorded push body must preserve the composed title"
  assert_grep "DRY RUN" "$home/err" "push dry-run must surface a DRY RUN summary on stderr"
  pass "fm-logbook-push dry-run records the body with no network and no token"
}

test_push_dry_run_from_json_file() {
  local home out rc
  home="$TMP_ROOT/push-dry-file"; mkdir -p "$home"
  printf '%s' '[{"id":"t1:merge","kind":"action","title":"PR ready"},{"id":"t2:fyi","kind":"fyi","title":"all green"}]' > "$home/items.json"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 \
    "$ROOT/bin/fm-logbook-push.sh" --json-file "$home/items.json" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "push dry-run --json-file exit"
  assert_present "$home/state/logbook-outbox/items.json" "push --json-file dry-run must record the body"
  [ "$(jq -r '.[1].id' "$home/state/logbook-outbox/items.json")" = "t2:fyi" ] \
    || fail "recorded array body must preserve every item"
  pass "fm-logbook-push accepts an array body via --json-file"
}

test_push_rejects_invalid_json() {
  local home out rc err
  home="$TMP_ROOT/push-badjson"; mkdir -p "$home"
  err="$home/err.txt"
  out=$(printf 'not json' | PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 \
    "$ROOT/bin/fm-logbook-push.sh" - 2>"$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "push must reject a non-JSON body"
  assert_grep "not valid JSON" "$err" "push must explain the JSON error"
  assert_absent "$home/state/logbook-outbox/items.json" "invalid JSON must not record an outbox preview"
  pass "fm-logbook-push rejects a body that is not valid JSON"
}

test_sync_dry_run_records() {
  local home out rc
  home="$TMP_ROOT/sync-dry"; mkdir -p "$home"
  printf '%s' '{"projects":[{"name":"SchokosLauncher","active":true}],"items":[{"id":"t1:merge","kind":"action","title":"PR ready"}]}' > "$home/board.json"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 \
    "$ROOT/bin/fm-logbook-sync.sh" --json-file "$home/board.json" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "sync dry-run exit"
  assert_present "$home/state/logbook-outbox/sync.json" "sync dry-run must record the {projects,items} body"
  [ "$(jq -r '.projects[0].name' "$home/state/logbook-outbox/sync.json")" = "SchokosLauncher" ] \
    || fail "recorded sync body must preserve projects"
  [ "$(jq -r '.items[0].id' "$home/state/logbook-outbox/sync.json")" = "t1:merge" ] \
    || fail "recorded sync body must preserve items"
  pass "fm-logbook-sync dry-run records the declarative reconcile body"
}

test_resolve_dry_run_records() {
  local home out rc
  home="$TMP_ROOT/resolve-dry"; mkdir -p "$home"
  # Default status is resolved; the tool has no resolve endpoint, so this upserts
  # {id,status} which drops the card off the board.
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 \
    "$ROOT/bin/fm-logbook-resolve.sh" 'aura-bench-e4:nm-review' 2>/dev/null); rc=$?
  expect_code 0 "$rc" "resolve dry-run exit"
  assert_present "$home/state/logbook-outbox/aura-bench-e4:nm-review.json" "resolve dry-run must record the upsert body"
  [ "$(jq -r .id "$home/state/logbook-outbox/aura-bench-e4:nm-review.json")" = "aura-bench-e4:nm-review" ] \
    || fail "resolve body must carry the item id (colon slug accepted, as the tool allows)"
  [ "$(jq -r .status "$home/state/logbook-outbox/aura-bench-e4:nm-review.json")" = "resolved" ] \
    || fail "resolve body must default status to resolved"
  # An explicit dismissed status is also accepted.
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 \
    "$ROOT/bin/fm-logbook-resolve.sh" mb-fast-search dismissed 2>/dev/null); rc=$?
  expect_code 0 "$rc" "resolve dismissed exit"
  [ "$(jq -r .status "$home/state/logbook-outbox/mb-fast-search.json")" = "dismissed" ] \
    || fail "resolve must honor an explicit dismissed status"
  pass "fm-logbook-resolve dry-run upserts a terminal status to clear a card"
}

test_resolve_rejects_bad_id() {
  local home rc
  home="$TMP_ROOT/resolve-bad"; mkdir -p "$home"
  # Path traversal, whitespace, and a leading dot are all rejected as unsafe slugs.
  PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 "$ROOT/bin/fm-logbook-resolve.sh" '../evil' >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "resolve traversal id exit"
  PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 "$ROOT/bin/fm-logbook-resolve.sh" 'has space' >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "resolve space id exit"
  PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 "$ROOT/bin/fm-logbook-resolve.sh" '.hidden' >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "resolve leading-dot id exit"
  PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 "$ROOT/bin/fm-logbook-resolve.sh" 'a..b' >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "resolve dotdot id exit"
  assert_absent "$home/state/logbook-outbox" "a rejected id must not write any outbox preview"
  pass "fm-logbook-resolve rejects an unsafe item id (safe-slug guard)"
}

test_resolve_rejects_bad_status() {
  local home rc err
  home="$TMP_ROOT/resolve-badstatus"; mkdir -p "$home"
  err="$home/err.txt"
  PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 "$ROOT/bin/fm-logbook-resolve.sh" good-id pending >/dev/null 2>"$err"; rc=$?
  expect_code 2 "$rc" "resolve bad-status exit"
  assert_grep "resolved" "$err" "resolve must explain the allowed statuses"
  pass "fm-logbook-resolve only accepts resolved or dismissed"
}

test_push_live_posts_with_bearer_no_leak() {
  local home fakebin log out rc data
  home="$TMP_ROOT/push-live"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  out=$(printf '%s' '{"id":"t1","kind":"fyi","title":"hi"}' \
    | PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_TOKEN=secrettok \
      LOGBOOK_URL=http://127.0.0.1:8137 FAKE_CURL_LOG="$log" FAKE_POST_CODE=200 \
    "$ROOT/bin/fm-logbook-push.sh" -); rc=$?
  expect_code 0 "$rc" "push live exit"
  assert_grep "url=http://127.0.0.1:8137/api/items" "$log" "push must POST to /api/items"
  assert_grep "method=POST" "$log" "push must use POST"
  assert_grep "auth=Authorization: Bearer secrettok" "$log" "push must send the bearer token"
  grep '^argv=' "$log" | grep -F 'secrettok' >/dev/null 2>&1 \
    && fail "push must not expose the bearer token in curl argv"
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  [ "$(printf '%s' "$data" | jq -r .id)" = "t1" ] || fail "push must stream the item body"
  pass "fm-logbook-push posts with a bearer header and never leaks the token in argv"
}

test_push_live_non_2xx_fails() {
  local home fakebin out rc err
  home="$TMP_ROOT/push-500"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  err="$home/err.txt"
  out=$(printf '{}' | PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_TOKEN=t \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_POST_CODE=500 \
    "$ROOT/bin/fm-logbook-push.sh" - 2>"$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "push must exit non-zero on a non-2xx response"
  assert_grep "HTTP 500" "$err" "push must report the failing status"
  pass "fm-logbook-push exits non-zero on a non-2xx board response"
}

test_up_noops_when_healthy() {
  local home fakebin out rc
  home="$TMP_ROOT/up-healthy"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  # /health already answers 200, so the launcher must short-circuit BEFORE ever
  # launching a server. The absent server log proves no node was spawned.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_HEALTH_CODE=200 \
    "$ROOT/bin/fm-logbook-up.sh"); rc=$?
  expect_code 0 "$rc" "up healthy exit"
  assert_contains "$out" "board already up at http://127.0.0.1:8137" \
    "up must report the board is already up without launching a server"
  assert_absent "$home/state/logbook-server.log" "an already-up board must not spawn a server (no log)"
  pass "fm-logbook-up no-ops when the board is already healthy"
}

test_up_hard_noop_when_disabled() {
  local home fakebin out rc log
  home="$TMP_ROOT/up-off"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  # Not opted in: a hard no-op that never even health-checks the board.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE='' FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-logbook-up.sh"); rc=$?
  expect_code 0 "$rc" "up disabled exit"
  [ -z "$out" ] || fail "up must be silent when not opted in (got: $out)"
  [ ! -f "$log" ] || fail "up must not even health-check the board when not opted in"
  pass "fm-logbook-up is a hard no-op when not opted in (inert default)"
}

test_bootstrap_opt_in_prints_line_no_shim_no_cadence() {
  local home fakebin out
  home="$TMP_ROOT/boot-on"; mkdir -p "$home/config"
  fakebin=$(make_fake_curl "$home")
  cat > "$home/config/logbook.env" <<'EOF'
LOGBOOK_ENABLE=1
LOGBOOK_URL=http://127.0.0.1:8137
LOGBOOK_TOKEN=boottok
EOF
  # Stub curl reports the board already up so logbook_setup's ensure-up is instant.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_HEALTH_CODE=200 \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "LOGBOOK: on - board at http://127.0.0.1:8137" \
    "bootstrap must announce logbook on opt-in"
  # CRITICAL Phase 0+1 invariant: read-only feed only. No inbound poll shim...
  assert_absent "$home/state/logbook-watch.check.sh" "opt-in must NOT drop a watcher poll shim in Phase 0+1"
  # ...and NO cadence file anywhere (nothing may set FM_CHECK_INTERVAL).
  if grep -rIlF 'FM_CHECK_INTERVAL' "$home/config" "$home/state" 2>/dev/null | grep -q .; then
    fail "opt-in must NOT write any watcher cadence file in Phase 0+1"
  fi
  pass "bootstrap opt-in prints the LOGBOOK line and drops no poll shim or cadence file"
}

test_bootstrap_opt_out_is_noop() {
  local home out
  # No config/logbook.env at all -> complete no-op, no LOGBOOK line.
  home="$TMP_ROOT/boot-off"; mkdir -p "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "LOGBOOK:" "bootstrap must say nothing about logbook without config"
  assert_absent "$home/state/logbook-watch.check.sh" "no config -> no poll shim"
  # config present but LOGBOOK_ENABLE falsy -> still off.
  home="$TMP_ROOT/boot-off-falsy"; mkdir -p "$home/config"
  printf 'LOGBOOK_ENABLE=0\n' > "$home/config/logbook.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "LOGBOOK:" "a falsy LOGBOOK_ENABLE must be treated as off"
  pass "bootstrap is inert without a truthy LOGBOOK_ENABLE (non-adopters unaffected)"
}

test_bootstrap_detect_only_skips_logbook() {
  local home out
  home="$TMP_ROOT/boot-detect"; mkdir -p "$home/config"
  printf 'LOGBOOK_ENABLE=1\n' > "$home/config/logbook.env"
  # The read-only (no-lock) session path must not run the mutating logbook_setup.
  out=$(FM_HOME="$home" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "LOGBOOK:" "detect-only bootstrap must skip logbook_setup"
  pass "bootstrap detect-only path leaves logbook untouched (read-only session)"
}

test_config_defaults
test_config_from_file
test_config_env_wins_over_file
test_config_empty_env_url_falls_back_to_default
test_push_dry_run_records_no_network_no_token
test_push_dry_run_from_json_file
test_push_rejects_invalid_json
test_sync_dry_run_records
test_resolve_dry_run_records
test_resolve_rejects_bad_id
test_resolve_rejects_bad_status
test_push_live_posts_with_bearer_no_leak
test_push_live_non_2xx_fails
test_up_noops_when_healthy
test_up_hard_noop_when_disabled
test_bootstrap_opt_in_prints_line_no_shim_no_cadence
test_bootstrap_opt_out_is_noop
test_bootstrap_detect_only_skips_logbook
