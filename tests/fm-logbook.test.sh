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
# 200) - or, when FAKE_HEALTH_FILE is set, whatever code that file currently holds, so
# a test can flip the board from dead to alive mid-run (that is how the reap tests let
# a fake `node` "bind" the port); GET /api/board writes FAKE_BOARD_BODY to the -o file
# and returns FAKE_BOARD_CODE (default 200); any other POST to /api/* returns
# FAKE_POST_CODE (default 200). Each call is recorded to FAKE_CURL_LOG (url, auth
# header, streamed body, full argv) so a test can assert the request shape and prove no
# token leaks into argv.
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
  */health)
    [ -n "$ofile" ] && : > "$ofile"
    if [ -n "${FAKE_HEALTH_FILE:-}" ]; then
      printf '%s' "$(cat "$FAKE_HEALTH_FILE" 2>/dev/null || printf '000')"
    else
      printf '%s' "${FAKE_HEALTH_CODE:-200}"
    fi
    ;;
  */api/board) [ -n "$ofile" ] && printf '%s' "${FAKE_BOARD_BODY:-}" > "$ofile"; printf '%s' "${FAKE_BOARD_CODE:-200}" ;;
  */api/*) [ -n "$ofile" ] && : > "$ofile"; printf '%s' "${FAKE_POST_CODE:-200}" ;;
  *) printf '000' ;;
esac
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# Give <fakebin> a fake `node` that stands in for the board server: it "binds" by
# writing 200 into FAKE_HEALTH_FILE, which the fake curl above then serves from
# /health. That is what lets a reap test drive a real fm-logbook-up.sh relaunch to
# success without a port, a server, or the projects/logbook clone. Also drops the
# server.mjs the launcher insists on finding before it will start anything.
make_fake_node() {
  local fakebin=$1 tool_dir=$2
  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
# The board "comes up": flip /health to 200 for the fake curl. The real server would
# stay resident; exiting is fine, since fm-logbook-up.sh detaches it and only ever
# polls /health for readiness.
[ -n "${FAKE_HEALTH_FILE:-}" ] && printf '200' > "$FAKE_HEALTH_FILE"
exit 0
SH
  chmod +x "$fakebin/node"
  mkdir -p "$tool_dir"
  : > "$tool_dir/server.mjs"
}

# How many times the board's /health was probed, per FAKE_CURL_LOG. The reap's own
# probe is one call; a relaunch attempt adds fm-logbook-up.sh's own probes on top, so
# a flat count is how a test proves an attempt was (or was not) made.
count_health_calls() {
  grep -c 'url=.*/health' "$1" 2>/dev/null || printf '0'
}

# A fakebin `curl` for the Phase 2 inbound connector: GET /api/connector/poll
# returns FAKE_POLL_CODE (default 204) writing FAKE_POLL_BODY to the -o file, and
# POST /api/connector/ack returns FAKE_ACK_CODE (default 200). Each call is logged
# to FAKE_CURL_LOG (url, auth header, streamed body, full argv) so a test can prove
# the request shape and that no token leaks into argv.
make_fake_conn_curl() {
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
  */api/connector/poll) [ -n "$ofile" ] && printf '%s' "${FAKE_POLL_BODY:-}" > "$ofile"; printf '%s' "${FAKE_POLL_CODE:-204}" ;;
  */api/connector/ack) printf '%s' "${FAKE_ACK_CODE:-200}" ;;
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

test_config_lone_url_derives_port() {
  local home out
  # A lone LOGBOOK_URL override (file) with no LOGBOOK_PORT must derive the port
  # from the URL, so the server bind port and the client/health-check URL can never
  # silently mismatch.
  home="$TMP_ROOT/cfg-lone-url-file"; mkdir -p "$home/config"
  printf 'LOGBOOK_ENABLE=1\nLOGBOOK_URL=http://127.0.0.1:9000\n' > "$home/config/logbook.env"
  out=$(FM_HOME="$home" PATH="$BASE_PATH" resolve_cfg)
  assert_contains "$out" "http://127.0.0.1:9000|9000|" \
    "a lone LOGBOOK_URL (file) override derives the port from the URL (9000)"
  # Same via an env-only URL override with no port set anywhere.
  home="$TMP_ROOT/cfg-lone-url-env"; mkdir -p "$home"
  out=$(FM_HOME="$home" LOGBOOK_URL=http://127.0.0.1:9100 PATH="$BASE_PATH" resolve_cfg)
  assert_contains "$out" "http://127.0.0.1:9100|9100|" \
    "a lone LOGBOOK_URL (env) override derives the port from the URL (9100)"
  # An explicit LOGBOOK_PORT still wins over the URL's port.
  home="$TMP_ROOT/cfg-url-port-explicit"; mkdir -p "$home"
  out=$(FM_HOME="$home" LOGBOOK_URL=http://127.0.0.1:9000 LOGBOOK_PORT=9500 PATH="$BASE_PATH" resolve_cfg)
  assert_contains "$out" "http://127.0.0.1:9000|9500|" \
    "an explicit LOGBOOK_PORT wins over the port derived from LOGBOOK_URL"
  # A URL with no explicit port falls back to the documented default port.
  home="$TMP_ROOT/cfg-url-noport"; mkdir -p "$home"
  out=$(FM_HOME="$home" LOGBOOK_URL=http://127.0.0.1 PATH="$BASE_PATH" resolve_cfg)
  assert_contains "$out" "http://127.0.0.1|8137|" \
    "a URL with no explicit port falls back to the default port 8137"
  pass "logbook config derives LOGBOOK_PORT from a lone LOGBOOK_URL override"
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

# A board with two cards, used by the resolve tests. Composing the full upsert body
# means fetching these fields via GET /api/board, so the fake curl serves this as
# FAKE_BOARD_BODY. Note the null priority/source and empty options: the composed
# body must still validate.
RESOLVE_BOARD_BODY='{"projects":[{"name":"aura"}],"items":[{"id":"aura-bench-e4:nm-review","project":"aura","kind":"decision","title":"Two findings need a call","body":"pick one","options":[{"label":"Fix","value":"fix"},{"label":"Ship","value":"ship"}],"priority":null,"status":"submitted","source":{"task":"aura-bench-e4"},"created":"2026-07-09T10:00:00Z","updated":"2026-07-09T10:05:00Z"},{"id":"mb-fast-search","project":"","kind":"action","title":"PR ready","body":"","options":[],"priority":72,"status":"pending","source":null,"created":"2026-07-09T09:00:00Z","updated":"2026-07-09T09:00:00Z"}]}'

test_resolve_dry_run_records() {
  local home fakebin log out rc obx
  home="$TMP_ROOT/resolve-dry"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  # A bare {id,status} upsert is rejected by the tool's validateItem (missing kind),
  # so resolve fetches the card via GET /api/board and re-posts the WHOLE item with
  # a terminal status. Dry-run still performs that read-only GET (a GET has no side
  # effects) to compose a faithful preview, but records the body instead of posting.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 LOGBOOK_TOKEN=drytok \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_CURL_LOG="$log" FAKE_BOARD_BODY="$RESOLVE_BOARD_BODY" \
    "$ROOT/bin/fm-logbook-resolve.sh" 'aura-bench-e4:nm-review' 2>"$home/err"); rc=$?
  expect_code 0 "$rc" "resolve dry-run exit"
  obx="$home/state/logbook-outbox/aura-bench-e4:nm-review.json"
  assert_present "$obx" "resolve dry-run must record the upsert body"
  [ "$(jq -r .id "$obx")" = "aura-bench-e4:nm-review" ] \
    || fail "resolve body must carry the item id (colon slug accepted, as the tool allows)"
  [ "$(jq -r .status "$obx")" = "resolved" ] \
    || fail "resolve body must default status to resolved"
  # The whole point of the fix: the recorded body is a FULL valid item, not a bare
  # {id,status}. kind and title (the fields validateItem rejected the old body for)
  # must be carried over from the board.
  [ "$(jq -r .kind "$obx")" = "decision" ] \
    || fail "resolve body must carry the card's kind (a full valid item, not {id,status})"
  [ "$(jq -r .title "$obx")" = "Two findings need a call" ] \
    || fail "resolve body must carry the card's title"
  [ "$(jq -r '.options[0].value' "$obx")" = "fix" ] \
    || fail "resolve body must carry the card's options"
  # Dry-run reads the board (GET) but never writes it (no POST /api/items).
  assert_grep "url=http://127.0.0.1:8137/api/board" "$log" "resolve dry-run must GET the board to compose the body"
  assert_no_grep "method=POST" "$log" "resolve dry-run must not POST anything (send nothing)"
  # An explicit dismissed status carries the OTHER card's fields through, too.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 LOGBOOK_TOKEN=drytok \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_BOARD_BODY="$RESOLVE_BOARD_BODY" \
    "$ROOT/bin/fm-logbook-resolve.sh" mb-fast-search dismissed 2>/dev/null); rc=$?
  expect_code 0 "$rc" "resolve dismissed exit"
  obx="$home/state/logbook-outbox/mb-fast-search.json"
  [ "$(jq -r .status "$obx")" = "dismissed" ] || fail "resolve must honor an explicit dismissed status"
  [ "$(jq -r .kind "$obx")" = "action" ] || fail "resolve dismissed body must carry the card's kind"
  [ "$(jq -r .priority "$obx")" = "72" ] || fail "resolve body must carry the card's numeric priority"
  pass "fm-logbook-resolve dry-run records a full valid item (kind/title) with a terminal status"
}

test_resolve_live_posts_full_item() {
  local home fakebin log out rc data
  home="$TMP_ROOT/resolve-live"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  # Live: GET the board, then upsert the FULL item with a terminal status. The
  # posted body must carry kind/title (what the old {id,status} body lacked) so the
  # tool's validateItem accepts it instead of 400ing.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_TOKEN=secrettok \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_CURL_LOG="$log" FAKE_BOARD_BODY="$RESOLVE_BOARD_BODY" \
    FAKE_BOARD_CODE=200 FAKE_POST_CODE=200 \
    "$ROOT/bin/fm-logbook-resolve.sh" 'aura-bench-e4:nm-review'); rc=$?
  expect_code 0 "$rc" "resolve live exit"
  assert_grep "url=http://127.0.0.1:8137/api/board" "$log" "resolve must GET the board first"
  assert_grep "url=http://127.0.0.1:8137/api/items" "$log" "resolve must upsert to /api/items"
  assert_grep "method=POST" "$log" "resolve must POST the upsert"
  assert_grep "auth=Authorization: Bearer secrettok" "$log" "resolve must send the bearer token"
  grep '^argv=' "$log" | grep -F 'secrettok' >/dev/null 2>&1 \
    && fail "resolve must not expose the bearer token in curl argv"
  # The streamed POST body (last curl call) is the full item with status=resolved.
  data=$(grep '^data={' "$log" | tail -1 | sed 's/^data=//')
  [ "$(printf '%s' "$data" | jq -r .id)" = "aura-bench-e4:nm-review" ] || fail "posted body must carry the id"
  [ "$(printf '%s' "$data" | jq -r .kind)" = "decision" ] || fail "posted body must carry kind (full valid item)"
  [ -n "$(printf '%s' "$data" | jq -r .title)" ] || fail "posted body must carry a non-empty title"
  [ "$(printf '%s' "$data" | jq -r .status)" = "resolved" ] || fail "posted body must set the terminal status"
  pass "fm-logbook-resolve upserts a full valid item (kind/title) that the tool accepts"
}

test_resolve_unknown_id_is_noop() {
  local home fakebin log out rc
  home="$TMP_ROOT/resolve-unknown"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  # The board does not contain this id (already resolved/dismissed, or unknown):
  # there is nothing to clear. It is a clean no-op success - GET happens, but no
  # upsert is posted and nothing is recorded.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_TOKEN=tok \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_CURL_LOG="$log" FAKE_BOARD_BODY="$RESOLVE_BOARD_BODY" \
    "$ROOT/bin/fm-logbook-resolve.sh" 'not-on-the-board' 2>"$home/err"); rc=$?
  expect_code 0 "$rc" "resolve unknown-id exit (clean no-op)"
  assert_grep "url=http://127.0.0.1:8137/api/board" "$log" "resolve must still read the board to learn the id is absent"
  assert_no_grep "url=.*/api/items" "$log" "an absent id must not upsert anything"
  assert_absent "$home/state/logbook-outbox" "an absent id must not record any body"
  # Same clean no-op under dry-run.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 LOGBOOK_TOKEN=tok \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_BOARD_BODY="$RESOLVE_BOARD_BODY" \
    "$ROOT/bin/fm-logbook-resolve.sh" 'not-on-the-board' 2>/dev/null); rc=$?
  expect_code 0 "$rc" "resolve unknown-id dry-run exit"
  assert_absent "$home/state/logbook-outbox" "an absent id (dry-run) must not record any body"
  pass "fm-logbook-resolve treats an id absent from the board as a clean no-op"
}

test_resolve_board_unreadable_fails() {
  local home fakebin log out rc err
  home="$TMP_ROOT/resolve-noread"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"; err="$home/err.txt"
  # If the board read fails, resolve cannot compose a valid body: it must exit
  # non-zero (so the answer-loop leaves the inbox file and retries) and never post a
  # blind, possibly-invalid upsert.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_TOKEN=tok \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_CURL_LOG="$log" FAKE_BOARD_CODE=500 \
    "$ROOT/bin/fm-logbook-resolve.sh" 'aura-bench-e4:nm-review' 2>"$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "resolve must exit non-zero when the board read fails"
  assert_grep "HTTP 500" "$err" "resolve must report the failing board read"
  assert_no_grep "url=.*/api/items" "$log" "a failed board read must not post a blind upsert"
  pass "fm-logbook-resolve fails (no blind upsert) when the board cannot be read"
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

test_bootstrap_opt_in_drops_poll_shim_and_cadence() {
  local home fakebin out sum1 sum2 n inherited
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
    "bootstrap must announce the logbook feed on opt-in"
  assert_contains "$out" "LOGBOOK: board-response poll armed" \
    "bootstrap must announce the Phase 2 board-response poll arm"
  # Phase 2: opt-in DROPS the inbound poll shim + 15s cadence (mirroring X mode).
  assert_present "$home/state/logbook-watch.check.sh" "opt-in must drop the board-response poll shim"
  [ -x "$home/state/logbook-watch.check.sh" ] || fail "the poll shim must be executable"
  assert_grep "fm-logbook-poll.sh" "$home/state/logbook-watch.check.sh" "the shim must exec the poll script"
  # Board liveness rides the same rail: nothing else supervises the detached board.
  assert_present "$home/state/logbook-reap.check.sh" "opt-in must drop the board-liveness reap shim"
  [ -x "$home/state/logbook-reap.check.sh" ] || fail "the reap shim must be executable"
  assert_grep "fm-logbook-reap.sh" "$home/state/logbook-reap.check.sh" "the reap shim must exec the reap script"
  assert_present "$home/config/logbook-mode.env" "opt-in must drop the cadence config"
  assert_grep "export FM_CHECK_INTERVAL=15" "$home/config/logbook-mode.env" "cadence must be 15s"
  # The generated cadence file must NOT clobber the captain's hand-authored opt-in.
  assert_grep "LOGBOOK_ENABLE=1" "$home/config/logbook.env" "the hand-authored opt-in file must be untouched"
  assert_no_grep "FM_CHECK_INTERVAL" "$home/config/logbook.env" "the cadence must not be written into config/logbook.env"
  # Cadence inheritance: sourcing the config exports the 15s interval to a child,
  # exactly how fm-watch-arm.sh's forked watcher inherits it.
  # shellcheck source=/dev/null
  inherited=$( . "$home/config/logbook-mode.env" && bash -c 'echo "${FM_CHECK_INTERVAL:-300}"' )
  [ "$inherited" = "15" ] || fail "sourcing the cadence config must export FM_CHECK_INTERVAL=15 to a child"
  # Idempotent: re-running changes nothing and does not duplicate the shims.
  sum1=$(cat "$home/state/logbook-watch.check.sh" "$home/state/logbook-reap.check.sh" "$home/config/logbook-mode.env" | shasum)
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_HEALTH_CODE=200 "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  sum2=$(cat "$home/state/logbook-watch.check.sh" "$home/state/logbook-reap.check.sh" "$home/config/logbook-mode.env" | shasum)
  [ "$sum1" = "$sum2" ] || fail "bootstrap logbook Phase 2 setup must be idempotent"
  n=$(find "$home/state" -maxdepth 1 -name 'logbook-*.check.sh' | wc -l | tr -d ' ')
  [ "$n" = "2" ] || fail "bootstrap must drop exactly the poll + reap shims, unduplicated (found $n)"
  pass "bootstrap opt-in drops the board-response poll shim, board-liveness reap shim, and 15s cadence, idempotently"
}

test_xmode_and_logbook_cadences_coexist() {
  local home fakebin out arm inherited verdict
  home="$TMP_ROOT/coexist"; mkdir -p "$home/config" "$home/state"
  fakebin=$(make_fake_curl "$home")
  # Opt into BOTH X mode and logbook in the same home.
  printf 'FMX_PAIRING_TOKEN=xtok\n' > "$home/.env"
  cat > "$home/config/logbook.env" <<'EOF'
LOGBOOK_ENABLE=1
LOGBOOK_URL=http://127.0.0.1:8137
LOGBOOK_TOKEN=boottok
EOF
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_HEALTH_CODE=200 \
    "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1

  # 1. Both cadence configs exist side by side; neither clobbers the other.
  assert_present "$home/config/x-mode.env" "X mode cadence must survive alongside logbook"
  assert_present "$home/config/logbook-mode.env" "logbook cadence must survive alongside X mode"
  assert_grep "export FM_CHECK_INTERVAL=30" "$home/config/x-mode.env" "X mode cadence must stay 30s"
  assert_grep "export FM_CHECK_INTERVAL=15" "$home/config/logbook-mode.env" "logbook cadence must stay 15s"
  assert_present "$home/state/x-watch.check.sh" "X mode poll shim must survive alongside logbook"
  assert_present "$home/state/logbook-watch.check.sh" "logbook poll shim must survive alongside X mode"

  # 2. The emitted supervision block must source BOTH, with logbook LAST, because both
  #    export FM_CHECK_INTERVAL and the snappier 15s board cadence has to win.
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness grok)
  assert_contains "$out" "$home/config/x-mode.env" "emitted block lost the X-mode cadence"
  assert_contains "$out" "$home/config/logbook-mode.env" "emitted block lost the logbook cadence"
  assert_not_contains "$out" "__FM_" "emitted block leaked a template placeholder"
  arm=$(printf '%s\n' "$out" | grep -o "\[ -f .*exec bin/fm-watch-arm.sh")
  case "$arm" in
    *x-mode.env*logbook-mode.env*) : ;;
    *) fail "the emitted arm command must source logbook AFTER x-mode, got: $arm" ;;
  esac

  # 3. Running that exact prelude order must leave the watcher on 15s, not 30s.
  # shellcheck source=/dev/null
  inherited=$( . "$home/config/x-mode.env"; . "$home/config/logbook-mode.env"; \
    bash -c 'echo "${FM_CHECK_INTERVAL:-300}"' )
  [ "$inherited" = "15" ] \
    || fail "sourcing x-mode then logbook must inherit the 15s cadence, got '$inherited'"

  # 4. The arm-command PreToolUse policy must ALLOW that emitted command. If it denied it,
  #    the arm would be blocked and supervision would silently lapse.
  verdict=$(node "$ROOT/bin/fm-arm-command-policy.mjs" --root "$ROOT" --home "$home" \
    --command "[ -f '$home/config/x-mode.env' ] && . '$home/config/x-mode.env'; [ -f '$home/config/logbook-mode.env' ] && . '$home/config/logbook-mode.env'; exec bin/fm-watch-arm.sh")
  case "$verdict" in
    allow*) : ;;
    *) fail "the arm policy must allow the emitted both-cadences command, got: $verdict" ;;
  esac
  # The hand-authored opt-in file is NOT a generated cadence config and stays unsourceable.
  verdict=$(node "$ROOT/bin/fm-arm-command-policy.mjs" --root "$ROOT" --home "$home" \
    --command "source '$home/config/logbook.env'; exec bin/fm-watch-arm.sh")
  case "$verdict" in
    deny*) : ;;
    *) fail "the arm policy must still deny sourcing config/logbook.env, got: $verdict" ;;
  esac
  pass "X-mode and logbook cadences coexist: both armed, logbook sourced last (15s wins), policy allows it"
}

test_logbook_off_leaves_supervision_block_inert() {
  local home out
  home="$TMP_ROOT/inert-sup"; mkdir -p "$home/config" "$home/state"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness grok --x-mode 1)
  # Inertness is about the EXECUTABLE contract, not the prose. The snippet's step-2 prose
  # names both cadence paths with a "when ... is active" qualifier - exactly as upstream's
  # X-mode prose already does for a home with no X mode - so the guarantee that matters is
  # that a logbook-less home is never actually told to source a logbook cadence, and its
  # arm command stays byte-identical to upstream's X-mode-only form.
  assert_contains "$out" "- Logbook: inactive" "the block must state logbook is inactive"
  assert_not_contains "$out" "__FM_" "emitted block leaked a template placeholder"
  assert_contains "$out" "[ -f '$home/config/x-mode.env' ] && . '$home/config/x-mode.env'; exec bin/fm-watch-arm.sh" \
    "with logbook off the arm command must stay byte-identical to the X-mode-only form"
  assert_not_contains "$out" ". '$home/config/logbook-mode.env';" \
    "a home without logbook must never be given a logbook source clause to run"
  # The repair line guards and hooks emit must be untouched too.
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness claude --x-mode 1 --repair-line)
  assert_contains "$out" "source '$home/config/x-mode.env' first, then " "repair line lost the X-mode-only prefix"
  assert_not_contains "$out" "logbook-mode.env" "a logbook-less home's repair line must not mention the logbook cadence"
  pass "logbook off keeps the emitted arm command and repair line identical to the X-mode-only form"
}

test_bootstrap_opt_in_unhealthy_reports_degraded() {
  local home fakebin out err
  home="$TMP_ROOT/boot-unhealthy"; mkdir -p "$home/config"
  fakebin=$(make_fake_curl "$home")
  cat > "$home/config/logbook.env" <<'EOF'
LOGBOOK_ENABLE=1
LOGBOOK_URL=http://127.0.0.1:8137
LOGBOOK_TOKEN=boottok
LOGBOOK_TOOL_DIR=/nonexistent/logbook
EOF
  err="$home/err.txt"
  # Board is not healthy (000) and the tool dir has no server.mjs, so the launcher
  # cannot bring the board up and exits non-zero. Bootstrap must not claim a bare
  # "on": it reports opted-in-but-not-up AND passes the launcher's stderr through.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_HEALTH_CODE=000 \
    "$ROOT/bin/fm-bootstrap.sh" 2>"$err")
  assert_contains "$out" "LOGBOOK: on - board at http://127.0.0.1:8137 (server not reachable yet" \
    "an unreachable board must be reported as opted-in-but-not-up, not a bare 'on'"
  assert_grep "fm-logbook-up:" "$err" "the launcher's own diagnostic must surface on stderr, not be swallowed"
  pass "bootstrap reports a degraded logbook line and surfaces the launcher diagnostic when the board is down"
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

test_bootstrap_opt_out_removes_poll_shim_and_cadence() {
  local home fakebin out
  home="$TMP_ROOT/boot-optout"; mkdir -p "$home/config"
  fakebin=$(make_fake_curl "$home")
  # Opt in: the Phase 2 artifacts appear.
  cat > "$home/config/logbook.env" <<'EOF'
LOGBOOK_ENABLE=1
LOGBOOK_URL=http://127.0.0.1:8137
LOGBOOK_TOKEN=boottok
EOF
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_HEALTH_CODE=200 "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_present "$home/state/logbook-watch.check.sh" "opt-in must create the poll shim before opt-out"
  assert_present "$home/state/logbook-reap.check.sh" "opt-in must create the reap shim before opt-out"
  assert_present "$home/config/logbook-mode.env" "opt-in must create the cadence config before opt-out"
  # Opt out: falsy flag -> every artifact removed + one off line.
  printf 'LOGBOOK_ENABLE=0\n' > "$home/config/logbook.env"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_HEALTH_CODE=200 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "LOGBOOK: off - removed board-response poll shim, board-liveness reap shim, and 15s cadence" \
    "opt-out must announce logbook off when it removed artifacts"
  assert_absent "$home/state/logbook-watch.check.sh" "opt-out must remove the poll shim"
  assert_absent "$home/state/logbook-reap.check.sh" "opt-out must remove the reap shim"
  assert_absent "$home/config/logbook-mode.env" "opt-out must remove the cadence config"
  # Steady-state off: another run with nothing to remove is silent.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_HEALTH_CODE=200 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "LOGBOOK:" "steady-state off must be silent"
  pass "bootstrap removes the logbook poll shim + cadence on opt-out and is silent once off"
}

# --- inbound board-response poll (fm-logbook-poll.sh) ------------------------

test_poll_no_optin_is_hard_noop() {
  local home fakebin out rc log
  home="$TMP_ROOT/poll-noop"; mkdir -p "$home"
  fakebin=$(make_fake_conn_curl "$home")
  log="$home/curl.log"
  # Not opted in: a hard no-op that never even polls the board.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE='' FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-logbook-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll no-optin exit"
  [ -z "$out" ] || fail "poll must be silent when not opted in (got: $out)"
  [ ! -f "$log" ] || fail "poll must not even call the board when not opted in"
  assert_absent "$home/state/logbook-inbox" "poll no-optin must not create an inbox"
  pass "fm-logbook-poll is a hard no-op when not opted in (inert default)"
}

test_poll_204_is_silent() {
  local home fakebin log out rc
  home="$TMP_ROOT/poll-204"; mkdir -p "$home"
  fakebin=$(make_fake_conn_curl "$home")
  log="$home/curl.log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 LOGBOOK_TOKEN=tok-204 \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_CURL_LOG="$log" FAKE_POLL_CODE=204 \
    "$ROOT/bin/fm-logbook-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll 204 exit"
  [ -z "$out" ] || fail "poll 204 must be silent (got: $out)"
  assert_grep "auth=Authorization: Bearer tok-204" "$log" "poll must send the bearer token"
  grep '^argv=' "$log" | grep -F 'tok-204' >/dev/null 2>&1 \
    && fail "poll must not expose the bearer token in curl argv"
  assert_grep "url=http://127.0.0.1:8137/api/connector/poll" "$log" "poll must hit /api/connector/poll"
  ls "$home/state/logbook-inbox/"*.json >/dev/null 2>&1 && fail "poll 204 must not stash an inbox file"
  pass "fm-logbook-poll stays silent on HTTP 204 (the common case)"
}

test_poll_pending_stashes_and_marks() {
  local home fakebin out rc body f1 f2
  home="$TMP_ROOT/poll-pending"; mkdir -p "$home"
  fakebin=$(make_fake_conn_curl "$home")
  # Two answers in one poll: an option answer and a free-text answer. The full
  # object must round-trip so logbook-respond can route and act on it.
  body='{"responses":[{"response_id":"r-1","item_id":"fix-login-k3:merge","kind":"option","value":"merge","text":null,"created":"t1"},{"response_id":"r-2","item_id":"scout-x","kind":"text","value":null,"text":"go with plan B","created":"t2"}]}'
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 LOGBOOK_TOKEN=tok \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_POLL_CODE=200 FAKE_POLL_BODY="$body" \
    "$ROOT/bin/fm-logbook-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll pending exit"
  assert_contains "$out" "logbook-response r-1" "poll must print a wake line for r-1"
  assert_contains "$out" "logbook-response r-2" "poll must print a wake line for r-2"
  f1="$home/state/logbook-inbox/r-1.json"; f2="$home/state/logbook-inbox/r-2.json"
  assert_present "$f1" "poll must stash r-1"
  assert_present "$f2" "poll must stash r-2"
  [ "$(jq -r .item_id "$f1")" = "fix-login-k3:merge" ] || fail "stashed r-1 must preserve item_id"
  [ "$(jq -r .value "$f1")" = "merge" ] || fail "stashed r-1 must preserve the option value"
  [ "$(jq -r .kind "$f2")" = "text" ] || fail "stashed r-2 must preserve kind"
  [ "$(jq -r .text "$f2")" = "go with plan B" ] || fail "stashed r-2 must preserve the free text"
  pass "fm-logbook-poll stashes every pending answer and prints one wake line each"
}

test_poll_empty_responses_is_silent() {
  local home fakebin out rc
  home="$TMP_ROOT/poll-empty"; mkdir -p "$home"
  fakebin=$(make_fake_conn_curl "$home")
  # A 200 with an empty responses array is a defensive equivalent of 204.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 LOGBOOK_TOKEN=tok \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_POLL_CODE=200 FAKE_POLL_BODY='{"responses":[]}' \
    "$ROOT/bin/fm-logbook-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll empty responses exit"
  [ -z "$out" ] || fail "poll must be silent for an empty responses array (got: $out)"
  assert_absent "$home/state/logbook-inbox" "empty responses must not create an inbox"
  pass "fm-logbook-poll stays silent when the board returns no responses"
}

test_poll_error_reports_once() {
  local home fakebin out rc
  home="$TMP_ROOT/poll-err"; mkdir -p "$home"
  fakebin=$(make_fake_conn_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 LOGBOOK_TOKEN=tok \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_POLL_CODE=401 "$ROOT/bin/fm-logbook-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll auth error exit"
  [ "$out" = "logbook-error board returned HTTP 401" ] \
    || fail "poll auth error must emit one visible diagnostic (got: $out)"
  assert_present "$home/state/logbook-poll.error" "poll auth error must write a dedupe marker"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 LOGBOOK_TOKEN=tok \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_POLL_CODE=401 "$ROOT/bin/fm-logbook-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll repeated auth error exit"
  [ -z "$out" ] || fail "repeated poll auth error must be quiet after the first diagnostic (got: $out)"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 LOGBOOK_TOKEN=tok \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_POLL_CODE=204 "$ROOT/bin/fm-logbook-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll recovered error exit"
  [ -z "$out" ] || fail "poll recovery 204 must stay silent (got: $out)"
  assert_absent "$home/state/logbook-poll.error" "poll 204 must clear the error marker"
  pass "fm-logbook-poll surfaces board errors once and clears on recovery"
}

test_poll_rejects_unsafe_response_id() {
  local home fakebin out rc
  home="$TMP_ROOT/poll-evil"; mkdir -p "$home"
  fakebin=$(make_fake_conn_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 LOGBOOK_TOKEN=tok \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_POLL_CODE=200 \
    FAKE_POLL_BODY='{"responses":[{"response_id":"../../etc/x","item_id":"t","kind":"text","text":"hi"}]}' \
    "$ROOT/bin/fm-logbook-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll unsafe id exit"
  [ -z "$out" ] || fail "poll must not emit a marker for an unsafe response_id (got: $out)"
  assert_absent "$home/state/logbook-inbox/../../etc/x.json" "poll must not write outside the inbox"
  pass "fm-logbook-poll rejects an unsafe response_id (path-traversal guard)"
}

test_poll_missing_jq_reports_error() {
  local home fakebin out rc
  home="$TMP_ROOT/poll-nojq"; mkdir -p "$home"
  # A fakebin with curl but deliberately no jq on PATH: the poll must not stash or
  # wake for nothing; it surfaces one repairable diagnostic.
  fakebin=$(make_fake_conn_curl "$home")
  out=$(PATH="$fakebin:/usr/bin:/bin" FM_HOME="$home" LOGBOOK_ENABLE=1 LOGBOOK_TOKEN=tok \
    LOGBOOK_URL=http://127.0.0.1:8137 "$ROOT/bin/fm-logbook-poll.sh" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "poll missing-jq exit"
  # Only assert the diagnostic when the bare PATH genuinely lacks jq (some hosts put
  # jq in /usr/bin); otherwise this degenerates to the 204 path, still a valid no-op.
  if ! PATH="/usr/bin:/bin" command -v jq >/dev/null 2>&1; then
    [ "$out" = "logbook-error missing jq" ] || fail "poll must report a missing jq once (got: $out)"
    assert_present "$home/state/logbook-poll.error" "missing jq must write a dedupe marker"
  fi
  assert_absent "$home/state/logbook-inbox" "missing jq must not stash an inbox file"
  pass "fm-logbook-poll surfaces a missing jq dependency instead of a silent failure"
}

# --- board-liveness reap (fm-logbook-reap.sh) --------------------------------
#
# The board is a bare detached node process that nothing supervised: before the reap,
# only a session-start bootstrap ever started it, so a board killed mid-session stayed
# dead. The reap rides the SAME check rail as the poll, and its defining property is
# that it is QUIET - a board it brings back must not wake firstmate, because reaping is
# housekeeping. Only a board it has given up on may speak, and then only once.

test_reap_hard_noop_when_disabled() {
  local home fakebin out rc log
  home="$TMP_ROOT/reap-off"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  # Not opted in: a hard no-op that never even health-checks the board. This is what a
  # non-adopter pays for the reap - nothing.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE='' FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-logbook-reap.sh"); rc=$?
  expect_code 0 "$rc" "reap disabled exit"
  [ -z "$out" ] || fail "reap must be silent when not opted in (got: $out)"
  [ ! -f "$log" ] || fail "reap must not even health-check the board when not opted in"
  assert_absent "$home/state/logbook-reap.state" "reap must write no state when not opted in"
  pass "fm-logbook-reap is a hard no-op when not opted in (inert default)"
}

test_reap_healthy_board_is_silent() {
  local home fakebin out rc log
  home="$TMP_ROOT/reap-healthy"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  # The common path: the board answers, so the reap probes once and says nothing. An
  # absent server log proves it never launched anything.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_HEALTH_CODE=200 FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-logbook-reap.sh"); rc=$?
  expect_code 0 "$rc" "reap healthy exit"
  [ -z "$out" ] || fail "a healthy board must produce NO output, hence no wake (got: $out)"
  [ "$(count_health_calls "$log")" = "1" ] \
    || fail "a healthy board must cost exactly one /health probe (got: $(count_health_calls "$log"))"
  assert_absent "$home/state/logbook-server.log" "a healthy board must not spawn a server"
  assert_absent "$home/state/logbook-reap.state" "a healthy board with no incident writes no state"
  pass "fm-logbook-reap stays silent and cheap while the board is healthy"
}

test_reap_relaunches_dead_board_without_waking() {
  local home fakebin out rc health
  home="$TMP_ROOT/reap-revive"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  make_fake_node "$fakebin" "$home/projects/logbook"
  health="$home/health.code"
  printf '000' > "$health"   # the board is dead: /health refuses the connection
  # The whole point of the task: a board killed mid-session comes back on the next
  # check cycle, and the captain is NOT woken for it.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_HEALTH_FILE="$health" \
    "$ROOT/bin/fm-logbook-reap.sh"); rc=$?
  expect_code 0 "$rc" "reap relaunch exit"
  [ -z "$out" ] || fail "a RELAUNCHED board must not manufacture a wake (got: $out)"
  [ "$(cat "$health")" = "200" ] || fail "the reap must actually have relaunched the board"
  # A clean revival records phase=up with both streaks at zero: the board is being
  # watched for stability (it clears once healthy for STABLE_SECS), but it never gave up.
  assert_grep 'up 0 0 ' "$home/state/logbook-reap.state" \
    "a clean revival records phase up with both streaks at zero"
  assert_absent "$home/state/logbook-reap.error" "a successful relaunch must leave no diagnostic"
  pass "fm-logbook-reap revives a dead board silently (housekeeping, never a wake)"
}

test_reap_wont_start_gives_up_once_then_stops() {
  local home fakebin out rc health log i
  home="$TMP_ROOT/reap-wontstart"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  health="$home/health.code"; log="$home/curl.log"
  printf '000' > "$health"   # board dead and, with no `node`, it can never be started
  # The board never answers, so the WONT-START streak climbs one per cycle. The cycles
  # before the threshold stay QUIET - a board merely slow to bind lands here and recovers
  # on the next cycle, and waking for that is noise.
  i=1
  while [ "$i" -lt 3 ]; do
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
      LOGBOOK_URL=http://127.0.0.1:8137 FAKE_HEALTH_FILE="$health" \
      FM_LOGBOOK_REAP_MAX_STRIKES=3 "$ROOT/bin/fm-logbook-reap.sh" 2>/dev/null); rc=$?
    expect_code 0 "$rc" "reap wont-start cycle $i exit"
    [ -z "$out" ] || fail "wont-start cycle $i must stay quiet (got: $out)"
    assert_grep "launching $i 0 " "$home/state/logbook-reap.state" \
      "wont-start cycle $i must advance the streak to $i and keep trying"
    i=$((i + 1))
  done

  # The MAX_STRIKES-th failed relaunch exhausts the tries: ONE diagnostic that says the
  # board WON'T START and carries the launcher's own reason so the captain can act.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_HEALTH_FILE="$health" \
    FM_LOGBOOK_REAP_MAX_STRIKES=3 "$ROOT/bin/fm-logbook-reap.sh" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "reap wont-start give-up exit"
  assert_contains "$out" "logbook-error logbook board won't start at http://127.0.0.1:8137" \
    "exhausting the relaunch tries must surface exactly one won't-start diagnostic"
  assert_contains "$out" "node not found" \
    "the diagnostic must carry the launcher's own reason, not just 'it failed'"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] \
    || fail "the give-up must be ONE line (one wake), not a stream (got: $out)"
  assert_grep "wontstart 3 0 " "$home/state/logbook-reap.state" "give-up must record the wontstart phase"
  assert_present "$home/state/logbook-reap.error" "the give-up must write a dedupe marker"

  # After giving up, the reap STOPS relaunching until reset - this is what kills the old
  # decay-into-thrash bug, where the in-window count decayed and the gate reopened. A
  # given-up cycle costs ONE /health probe and issues NO relaunch (a relaunch would add
  # fm-logbook-up.sh's own probes on top of that one).
  rm -f "$log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_HEALTH_FILE="$health" FAKE_CURL_LOG="$log" \
    FM_LOGBOOK_REAP_MAX_STRIKES=3 "$ROOT/bin/fm-logbook-reap.sh" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "reap wont-start backed-off exit"
  [ -z "$out" ] || fail "a given-up board must stay quiet after its one report (got: $out)"
  [ "$(count_health_calls "$log")" = "1" ] \
    || fail "a given-up cycle must cost ONE probe and attempt no relaunch (probes: $(count_health_calls "$log"))"
  pass "fm-logbook-reap surfaces a won't-start board once, then stops relaunching (no thrash)"
}

test_reap_crash_loop_gives_up_once_then_stops() {
  local home fakebin out rc health log n
  home="$TMP_ROOT/reap-crashloop"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  make_fake_node "$fakebin" "$home/projects/logbook"   # every relaunch revives the board
  health="$home/health.code"; log="$home/curl.log"
  printf '000' > "$health"

  # Cycle 1: first death -> the reap revives it (the fake node binds). Silent.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_HEALTH_FILE="$health" \
    FM_LOGBOOK_REAP_MAX_STRIKES=3 "$ROOT/bin/fm-logbook-reap.sh" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "reap crash-loop revive exit"
  [ -z "$out" ] || fail "the first revival must be silent (got: $out)"
  [ "$(cat "$health")" = "200" ] || fail "the reap must have revived the board"
  assert_grep "up 0 0 " "$home/state/logbook-reap.state" "the first revival records phase up, no strikes"

  # ...but the board keeps DYING before it proves stable. Each crash (flip back to 000)
  # then relaunch is a non-sticking revival, so the CRASH-LOOP streak climbs one per
  # crash, and the reap silently revives it again while the streak is short.
  n=1
  while [ "$n" -lt 3 ]; do
    printf '000' > "$health"   # the revived board dies again before STABLE_SECS
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
      LOGBOOK_URL=http://127.0.0.1:8137 FAKE_HEALTH_FILE="$health" \
      FM_LOGBOOK_REAP_MAX_STRIKES=3 "$ROOT/bin/fm-logbook-reap.sh" 2>/dev/null); rc=$?
    expect_code 0 "$rc" "reap crash-loop cycle $n exit"
    [ -z "$out" ] || fail "crash-loop cycle $n must stay quiet while the streak is short (got: $out)"
    [ "$(cat "$health")" = "200" ] || fail "crash-loop cycle $n must re-revive the board"
    assert_grep "up 0 $n " "$home/state/logbook-reap.state" \
      "crash-loop cycle $n must advance the crash streak to $n and re-revive"
    n=$((n + 1))
  done

  # The MAX_STRIKES-th non-sticking revival gives up: ONE diagnostic that says the board
  # is CRASH-LOOPING, and this time the reap does NOT relaunch - the board stays down.
  printf '000' > "$health"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_HEALTH_FILE="$health" \
    FM_LOGBOOK_REAP_MAX_STRIKES=3 "$ROOT/bin/fm-logbook-reap.sh" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "reap crash-loop give-up exit"
  assert_contains "$out" "logbook-error logbook board is crash-looping at http://127.0.0.1:8137" \
    "exhausting the crash-loop streak must surface exactly one crash-looping diagnostic"
  assert_contains "$out" "revived 3 times" "the diagnostic must report how many revivals did not stick"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] \
    || fail "the give-up must be ONE line (one wake), not a stream (got: $out)"
  [ "$(cat "$health")" = "000" ] || fail "the give-up cycle must NOT relaunch (board stays down)"
  assert_grep "crashloop 0 3 " "$home/state/logbook-reap.state" "give-up must record the crashloop phase"
  assert_present "$home/state/logbook-reap.error" "the give-up must write a dedupe marker"

  # Given up: a further cycle stays quiet, issues NO relaunch, and revives nothing.
  rm -f "$log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_HEALTH_FILE="$health" FAKE_CURL_LOG="$log" \
    FM_LOGBOOK_REAP_MAX_STRIKES=3 "$ROOT/bin/fm-logbook-reap.sh" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "reap crash-loop backed-off exit"
  [ -z "$out" ] || fail "a crash-looping board given up on must stay quiet (got: $out)"
  [ "$(count_health_calls "$log")" = "1" ] \
    || fail "a given-up crash-loop cycle must cost ONE probe and no relaunch"
  [ "$(cat "$health")" = "000" ] || fail "a given-up cycle must not revive the board"
  pass "fm-logbook-reap surfaces a crash-looping board once, then stops relaunching"
}

test_reap_single_death_is_not_a_crash_loop() {
  local home fakebin out rc health
  home="$TMP_ROOT/reap-single"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  make_fake_node "$fakebin" "$home/projects/logbook"
  health="$home/health.code"; printf '000' > "$health"
  # Cycle 1: first death -> revive.
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_HEALTH_FILE="$health" \
    FM_LOGBOOK_REAP_MAX_STRIKES=3 "$ROOT/bin/fm-logbook-reap.sh" >/dev/null 2>&1
  # ONE crash: the board dies once and is revived. A single non-sticking revival must
  # NEVER wake the captain; only MAX_STRIKES consecutive ones do. This is the false
  # crash-loop-from-one-unanswered-probe bug the streak model kills by construction.
  printf '000' > "$health"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_HEALTH_FILE="$health" \
    FM_LOGBOOK_REAP_MAX_STRIKES=3 "$ROOT/bin/fm-logbook-reap.sh" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "reap single-death exit"
  [ -z "$out" ] || fail "ONE non-sticking revival must not wake anyone (got: $out)"
  assert_absent "$home/state/logbook-reap.error" "one crash must not write a diagnostic marker"
  assert_grep "up 0 1 " "$home/state/logbook-reap.state" \
    "one crash records a crash streak of 1, well short of give-up"
  [ "$(cat "$health")" = "200" ] || fail "the reap must re-revive after a single crash"
  pass "fm-logbook-reap treats one non-sticking revival as harmless, not a crash-loop wake"
}

test_reap_stability_reset_clears_both_streaks() {
  local home fakebin out rc health now
  home="$TMP_ROOT/reap-stable"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  health="$home/health.code"; printf '200' > "$health"   # board healthy
  now=$(date +%s)
  # A revived board carrying live streaks, healthy since LONGER than STABLE_SECS: it has
  # proved stable, so BOTH streaks and the diagnostic clear. This monotone wall-clock
  # reset replaces the old decaying window.
  printf 'up 3 2 %s\n' "$((now - 200))" > "$home/state/logbook-reap.state"
  printf 'stale diagnostic\n' > "$home/state/logbook-reap.error"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_HEALTH_FILE="$health" \
    FM_LOGBOOK_REAP_STABLE_SECS=100 "$ROOT/bin/fm-logbook-reap.sh" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "reap stability-reset exit"
  [ -z "$out" ] || fail "a stabilised board must be silent (got: $out)"
  assert_absent "$home/state/logbook-reap.state" "STABLE_SECS of continuous health resets both streaks"
  assert_absent "$home/state/logbook-reap.error" "a stable board clears the diagnostic too"

  # But a board healthy for LESS than STABLE_SECS is still proving: nothing resets yet.
  printf 'up 3 2 %s\n' "$now" > "$home/state/logbook-reap.state"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_HEALTH_FILE="$health" \
    FM_LOGBOOK_REAP_STABLE_SECS=100 "$ROOT/bin/fm-logbook-reap.sh" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "reap not-yet-stable exit"
  [ -z "$out" ] || fail "a still-proving board must be silent (got: $out)"
  assert_grep "up 3 2 " "$home/state/logbook-reap.state" \
    "a board healthy for less than STABLE_SECS must keep its streaks (no premature reset)"
  pass "fm-logbook-reap resets both streaks only after STABLE_SECS of continuous health"
}

test_reap_give_up_is_by_cycle_not_wall_clock() {
  local home fakebin out rc health
  home="$TMP_ROOT/reap-cadence"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  health="$home/health.code"; printf '000' > "$health"
  # The give-up is driven by the CONSECUTIVE-cycle streak, never by a time window, so it
  # fires the same whether cycles are 15s apart (default) or 300s apart (away mode). Seed
  # a launching streak whose last relaunch is stamped an ANCIENT epoch: an events-per-
  # time-window model would have decayed it to nothing, leaving a broken board relaunched
  # forever with no diagnostic (the away-mode bug). The streak model just advances it.
  printf 'launching 1 0 1\n' > "$home/state/logbook-reap.state"   # since=1 (1970), aeons ago
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_HEALTH_FILE="$health" \
    FM_LOGBOOK_REAP_MAX_STRIKES=2 "$ROOT/bin/fm-logbook-reap.sh" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "reap cadence-independent give-up exit"
  assert_contains "$out" "logbook board won't start" \
    "the second consecutive failure must give up regardless of the wall-clock gap since the last try"
  assert_grep "wontstart 2 0 " "$home/state/logbook-reap.state" \
    "the streak advanced by one cycle to the give-up threshold, with no time-window decay"
  pass "fm-logbook-reap gives up by consecutive-cycle count, not wall clock (same at 15s and 300s)"
}

test_reap_recovery_rearms_the_report() {
  local home fakebin out rc health now
  home="$TMP_ROOT/reap-recover"; mkdir -p "$home/state"
  fakebin=$(make_fake_curl "$home")
  health="$home/health.code"
  printf '000' > "$health"
  # Drive it to give-up (MAX_STRIKES=1: the first failed relaunch gives up at once).
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_HEALTH_FILE="$health" \
    FM_LOGBOOK_REAP_MAX_STRIKES=1 "$ROOT/bin/fm-logbook-reap.sh" >/dev/null 2>&1
  assert_present "$home/state/logbook-reap.error" "setup: the reap must have given up"
  assert_grep "wontstart " "$home/state/logbook-reap.state" "setup: the reap must have recorded the give-up"

  # The board recovers externally (the captain fixes the cause, or the systemd unit
  # restarts it). The first healthy cycle re-arms the stability clock but does NOT clear
  # yet - a board must PROVE it is stable before the diagnostic is dropped.
  printf '200' > "$health"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_HEALTH_FILE="$health" \
    FM_LOGBOOK_REAP_MAX_STRIKES=1 "$ROOT/bin/fm-logbook-reap.sh"); rc=$?
  expect_code 0 "$rc" "reap recovery first-healthy exit"
  [ -z "$out" ] || fail "a recovering board must not wake anyone (got: $out)"
  assert_grep "up " "$home/state/logbook-reap.state" "recovery moves the board into the proving (up) phase"
  assert_present "$home/state/logbook-reap.error" "the diagnostic is held until the board proves stable"

  # Once it has been healthy for STABLE_SECS, both the streak state and the diagnostic
  # clear, re-arming the report so a LATER death is reaped and reported afresh instead of
  # being silently deduped against a stale diagnostic.
  now=$(date +%s)
  printf 'up 1 0 %s\n' "$((now - 200))" > "$home/state/logbook-reap.state"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_HEALTH_FILE="$health" \
    FM_LOGBOOK_REAP_STABLE_SECS=100 "$ROOT/bin/fm-logbook-reap.sh"); rc=$?
  expect_code 0 "$rc" "reap recovery stable exit"
  [ -z "$out" ] || fail "a fully recovered board must not wake anyone (got: $out)"
  assert_absent "$home/state/logbook-reap.error" "recovery must clear the diagnostic marker once stable"
  assert_absent "$home/state/logbook-reap.state" "recovery must clear the streak state once stable"
  pass "fm-logbook-reap clears its markers once a recovered board proves stable, re-arming the report"
}

# --- inbound connector ack (fm-logbook-ack.sh) ------------------------------

test_ack_dry_run_records() {
  local home out rc
  home="$TMP_ROOT/ack-dry"; mkdir -p "$home"
  # Dry-run, NO token: compose {response_id}, record it, never call the board.
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 \
    "$ROOT/bin/fm-logbook-ack.sh" resp-42 2>"$home/err"); rc=$?
  expect_code 0 "$rc" "ack dry-run exit"
  [ "$out" = "resp-42" ] || fail "ack dry-run must echo the response_id (got: $out)"
  assert_present "$home/state/logbook-outbox/resp-42.json" "ack dry-run must record the would-be body"
  [ "$(jq -r .response_id "$home/state/logbook-outbox/resp-42.json")" = "resp-42" ] \
    || fail "recorded ack body must carry the response_id"
  assert_grep "DRY RUN" "$home/err" "ack dry-run must surface a DRY RUN summary on stderr"
  pass "fm-logbook-ack dry-run records {response_id} with no network and no token"
}

test_ack_live_posts_with_bearer_no_leak() {
  local home fakebin log out rc data
  home="$TMP_ROOT/ack-live"; mkdir -p "$home"
  fakebin=$(make_fake_conn_curl "$home")
  log="$home/curl.log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_TOKEN=secrettok \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_CURL_LOG="$log" FAKE_ACK_CODE=200 \
    "$ROOT/bin/fm-logbook-ack.sh" resp-7); rc=$?
  expect_code 0 "$rc" "ack live exit"
  [ "$out" = "resp-7" ] || fail "ack must echo only the response_id (got: $out)"
  assert_grep "url=http://127.0.0.1:8137/api/connector/ack" "$log" "ack must POST to /api/connector/ack"
  assert_grep "method=POST" "$log" "ack must use POST"
  assert_grep "auth=Authorization: Bearer secrettok" "$log" "ack must send the bearer token"
  grep '^argv=' "$log" | grep -F 'secrettok' >/dev/null 2>&1 \
    && fail "ack must not expose the bearer token in curl argv"
  data=$(grep '^data=' "$log" | tail -1 | sed 's/^data=//')
  [ "$(printf '%s' "$data" | jq -r .response_id)" = "resp-7" ] || fail "ack must stream {response_id}"
  pass "fm-logbook-ack posts {response_id} with a bearer header and never leaks the token"
}

test_ack_live_non_2xx_fails() {
  local home fakebin out rc err
  home="$TMP_ROOT/ack-500"; mkdir -p "$home"
  fakebin=$(make_fake_conn_curl "$home")
  err="$home/err.txt"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_TOKEN=t \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_ACK_CODE=500 \
    "$ROOT/bin/fm-logbook-ack.sh" resp-7 2>"$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "ack must exit non-zero on a non-2xx response"
  [ -z "$out" ] || fail "failed ack must not echo the response_id (got: $out)"
  assert_grep "HTTP 500" "$err" "ack must report the failing status"
  pass "fm-logbook-ack exits non-zero on a non-2xx board response"
}

test_ack_rejects_bad_id() {
  local home rc
  home="$TMP_ROOT/ack-bad"; mkdir -p "$home"
  PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 "$ROOT/bin/fm-logbook-ack.sh" '../evil' >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "ack traversal id exit"
  PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 "$ROOT/bin/fm-logbook-ack.sh" '.hidden' >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "ack leading-dot id exit"
  PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 "$ROOT/bin/fm-logbook-ack.sh" 'a..b' >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "ack dotdot id exit"
  PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_DRY_RUN=1 "$ROOT/bin/fm-logbook-ack.sh" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "ack missing id exit"
  assert_absent "$home/state/logbook-outbox" "a rejected id must not write any outbox preview"
  pass "fm-logbook-ack rejects an unsafe or missing response_id (safe-slug guard)"
}

# --- attention-set compose (fm-logbook-compose.sh) --------------------------

# write_fleet_fixture <home>: a small but representative fleet - a project
# registry, an in-flight backlog, and four task metas: a PR-ready ship (action),
# a needs-decision ship (decision), an in-progress scout (fyi), and a persistent
# secondmate (which must NEVER become a card).
write_fleet_fixture() {
  local home=$1
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/projects.md" <<'EOF'
# Fleet project registry (firstmate-private)

- alpha [no-mistakes] - First project (added 2026-07-01)
- beta [direct-PR +yolo] - Second project (added 2026-07-02)
- gamma [local-only] - Idle project with no work (added 2026-07-03)
EOF
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] ship-pr-a1 - Ship the widget endpoint (repo: alpha) (kind: ship) (since 2026-07-10)
- [ ] decide-b2 - Redesign the beta nav (repo: beta) (kind: ship) (since 2026-07-10)
- [ ] scout-c3 - Investigate the slow query (repo: alpha) (kind: scout) (since 2026-07-10)
## Queued
- [ ] queued-z9 - Not dispatched yet (repo: gamma)
## Done
- [x] old-d0 - old thing - local main (merged 2026-07-01)
EOF
  fm_write_meta "$home/state/ship-pr-a1.meta" \
    "window=firstmate:fm-ship-pr-a1" "project=$home/projects/alpha" \
    "harness=claude" "kind=ship" "mode=direct-PR" "yolo=off" \
    "pr=https://github.com/acme/alpha/pull/42"
  fm_write_meta "$home/state/decide-b2.meta" \
    "window=firstmate:fm-decide-b2" "project=$home/projects/beta" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf 'working: sketching options\nneeds-decision: nav on top or side? (options: top, side)\n' \
    > "$home/state/decide-b2.status"
  fm_write_meta "$home/state/scout-c3.meta" \
    "window=firstmate:fm-scout-c3" "project=$home/projects/alpha" \
    "harness=claude" "kind=scout" "mode=direct-PR" "yolo=off"
  printf 'working: profiling the query\n' > "$home/state/scout-c3.status"
  fm_write_secondmate_meta "$home/state/triage-sm.meta" "$home" "firstmate:fm-triage-sm" "beta"
}

test_compose_hard_noop_when_disabled() {
  local home out rc
  home="$TMP_ROOT/compose-off"; write_fleet_fixture "$home"
  # Not opted in: a hard no-op - no output, and nothing on stdout to feed sync.
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE='' \
    "$ROOT/bin/fm-logbook-compose.sh"); rc=$?
  expect_code 0 "$rc" "compose disabled exit"
  [ -z "$out" ] || fail "compose must emit nothing when not opted in (got: $out)"
  pass "fm-logbook-compose is a hard no-op when not opted in (inert default)"
}

test_compose_baseline_from_fleet_state() {
  local home out
  home="$TMP_ROOT/compose-baseline"; write_fleet_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # Valid {projects, items} envelope.
  printf '%s' "$out" | jq -e '(.projects|type=="array") and (.items|type=="array")' >/dev/null \
    || fail "compose must emit a {projects, items} object"$'\n'"$out"
  # One card per in-flight task; the persistent secondmate is NOT a card.
  [ "$(printf '%s' "$out" | jq '.items | length')" = 3 ] \
    || fail "compose must emit one card per in-flight task (3), not the secondmate"
  printf '%s' "$out" | jq -e '.items[] | select(.id=="triage-sm")' >/dev/null \
    && fail "compose must skip a kind=secondmate meta (it is not an attention item)"
  # PR-ready ship -> action, with a Merge option and the PR carried in source.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="ship-pr-a1")
      | (.kind=="action") and (.project=="alpha")
      and ([.options[].value] | index("merge") != null)
      and (.source.pr=="https://github.com/acme/alpha/pull/42")' >/dev/null \
    || fail "a PR-ready task must be an action card carrying the PR"
  # needs-decision -> decision, with the decision text in the body.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="decide-b2")
      | (.kind=="decision") and (.body | test("top or side"))' >/dev/null \
    || fail "a needs-decision task must be a decision card"
  # In-progress scout -> fyi, with the status verb stripped from the body.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="scout-c3")
      | (.kind=="fyi") and (.body=="profiling the query")' >/dev/null \
    || fail "an in-progress task must be a plain fyi card"
  # No item title is empty and every kind is valid (the tool would reject otherwise).
  printf '%s' "$out" | jq -e 'all(.items[]; (.title|length>0) and (.kind|IN("decision","action","fyi")))' >/dev/null \
    || fail "every composed item must have a non-empty title and a valid kind"
  # Projects: the whole registry, active only where a card lives; idle gamma is off.
  [ "$(printf '%s' "$out" | jq '.projects | length')" = 3 ] \
    || fail "compose must carry every registry project"
  printf '%s' "$out" | jq -e '.projects[] | select(.name=="alpha") | .active==true' >/dev/null \
    || fail "a project with cards must be flagged active"
  printf '%s' "$out" | jq -e '.projects[] | select(.name=="gamma") | .active==false' >/dev/null \
    || fail "a project with no cards must be flagged inactive"
  printf '%s' "$out" | jq -e '.projects[] | select(.name=="beta") | .mode=="direct-PR"' >/dev/null \
    || fail "a project mode must drop the +yolo posture flag"
  pass "fm-logbook-compose derives a truthful {projects, items} baseline from fleet state"
}

test_refresh_hard_noop_when_disabled() {
  local home fakebin out rc log
  home="$TMP_ROOT/refresh-off"; write_fleet_fixture "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE='' FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-logbook-refresh.sh"); rc=$?
  expect_code 0 "$rc" "refresh disabled exit"
  [ -z "$out" ] || fail "refresh must be silent when not opted in (got: $out)"
  [ ! -f "$log" ] || fail "refresh must not call the board when not opted in"
  pass "fm-logbook-refresh is a hard no-op when not opted in (inert default)"
}

test_refresh_dry_run_records_sync() {
  local home out rc
  home="$TMP_ROOT/refresh-dry"; write_fleet_fixture "$home"
  # Dry-run: compose + sync must record the reconcile body and never post.
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 LOGBOOK_DRY_RUN=1 \
    "$ROOT/bin/fm-logbook-refresh.sh" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "refresh dry-run exit"
  assert_present "$home/state/logbook-outbox/sync.json" "refresh dry-run must record the sync body"
  jq -e '(.projects|type=="array") and (.items|length==3)' "$home/state/logbook-outbox/sync.json" >/dev/null \
    || fail "the recorded sync body must carry the composed attention set"
  pass "fm-logbook-refresh dry-run composes and records the sync body without posting"
}

test_refresh_live_posts_sync() {
  local home fakebin out rc log
  home="$TMP_ROOT/refresh-live"; write_fleet_fixture "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 LOGBOOK_TOKEN=reftok \
    LOGBOOK_URL=http://127.0.0.1:8137 FAKE_CURL_LOG="$log" FAKE_POST_CODE=200 \
    "$ROOT/bin/fm-logbook-refresh.sh"); rc=$?
  expect_code 0 "$rc" "refresh live exit"
  assert_grep "url=http://127.0.0.1:8137/api/sync" "$log" "refresh must POST the reconcile to /api/sync"
  assert_grep "method=POST" "$log" "refresh must use POST"
  grep '^argv=' "$log" | grep -F 'reftok' >/dev/null 2>&1 \
    && fail "refresh must not expose the bearer token in curl argv"
  pass "fm-logbook-refresh live composes and POSTs the reconcile to /api/sync"
}

test_bootstrap_opt_in_surfaces_link_and_autosyncs() {
  local home fakebin out log
  home="$TMP_ROOT/boot-link"; write_fleet_fixture "$home"; mkdir -p "$home/config"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  cat > "$home/config/logbook.env" <<'EOF'
LOGBOOK_ENABLE=1
LOGBOOK_URL=http://127.0.0.1:8137
LOGBOOK_TOKEN=boottok
EOF
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_HEALTH_CODE=200 FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  # The captain-facing board link is surfaced when the board is reachable.
  assert_contains "$out" "LOGBOOK: attention board: http://127.0.0.1:8137" \
    "bootstrap must surface the captain-facing board link on a reachable board"
  # The board was auto-synced (a POST /api/sync landed) with no failure line.
  assert_grep "url=http://127.0.0.1:8137/api/sync" "$log" \
    "bootstrap must auto-sync the board at session start"
  assert_not_contains "$out" "board not auto-synced" \
    "a healthy auto-sync must not print the failure diagnostic"
  pass "bootstrap opt-in surfaces the captain link and auto-syncs the board (reachable)"
}

test_bootstrap_unreachable_omits_link_and_autosync() {
  local home fakebin out
  home="$TMP_ROOT/boot-link-down"; mkdir -p "$home/config"
  fakebin=$(make_fake_curl "$home")
  cat > "$home/config/logbook.env" <<'EOF'
LOGBOOK_ENABLE=1
LOGBOOK_URL=http://127.0.0.1:8137
LOGBOOK_TOKEN=boottok
LOGBOOK_TOOL_DIR=/nonexistent/logbook
EOF
  # Board unreachable and unlaunchable: the degraded line prints, but no dead link
  # is handed to the captain and no auto-sync is attempted.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FAKE_HEALTH_CODE=000 \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "LOGBOOK: on - board at http://127.0.0.1:8137 (server not reachable yet" \
    "an unreachable board must still report the degraded feed line"
  assert_not_contains "$out" "LOGBOOK: attention board:" \
    "an unreachable board must not surface a dead link to the captain"
  pass "bootstrap omits the captain link and auto-sync when the board is unreachable"
}

test_config_defaults
test_config_from_file
test_config_env_wins_over_file
test_config_empty_env_url_falls_back_to_default
test_config_lone_url_derives_port
test_push_dry_run_records_no_network_no_token
test_push_dry_run_from_json_file
test_push_rejects_invalid_json
test_sync_dry_run_records
test_resolve_dry_run_records
test_resolve_live_posts_full_item
test_resolve_unknown_id_is_noop
test_resolve_board_unreadable_fails
test_resolve_rejects_bad_id
test_resolve_rejects_bad_status
test_push_live_posts_with_bearer_no_leak
test_push_live_non_2xx_fails
test_up_noops_when_healthy
test_up_hard_noop_when_disabled
test_bootstrap_opt_in_drops_poll_shim_and_cadence
test_bootstrap_opt_in_unhealthy_reports_degraded
test_bootstrap_opt_out_is_noop
test_bootstrap_opt_out_removes_poll_shim_and_cadence
test_bootstrap_detect_only_skips_logbook
test_poll_no_optin_is_hard_noop
test_poll_204_is_silent
test_poll_pending_stashes_and_marks
test_poll_empty_responses_is_silent
test_poll_error_reports_once
test_poll_rejects_unsafe_response_id
test_poll_missing_jq_reports_error
test_reap_hard_noop_when_disabled
test_reap_healthy_board_is_silent
test_reap_relaunches_dead_board_without_waking
test_reap_wont_start_gives_up_once_then_stops
test_reap_crash_loop_gives_up_once_then_stops
test_reap_single_death_is_not_a_crash_loop
test_reap_stability_reset_clears_both_streaks
test_reap_give_up_is_by_cycle_not_wall_clock
test_reap_recovery_rearms_the_report
test_ack_dry_run_records
test_ack_live_posts_with_bearer_no_leak
test_ack_live_non_2xx_fails
test_ack_rejects_bad_id
test_compose_hard_noop_when_disabled
test_compose_baseline_from_fleet_state
test_refresh_hard_noop_when_disabled
test_refresh_dry_run_records_sync
test_refresh_live_posts_sync
test_bootstrap_opt_in_surfaces_link_and_autosyncs
test_bootstrap_unreachable_omits_link_and_autosync
test_xmode_and_logbook_cadences_coexist
test_logbook_off_leaves_supervision_block_inert
