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
# Same for git: compose reads each project clone's "origin" to verify a PR is really
# that project's, and an unresolvable git would silently degrade the Merge gate to its
# marker fallback - which is exactly what these tests must be able to tell apart.
GIT_BIN_DIR=$(command -v git 2>/dev/null) && GIT_BIN_DIR=$(dirname "$GIT_BIN_DIR") || GIT_BIN_DIR=
[ -n "$GIT_BIN_DIR" ] && BASE_PATH="$GIT_BIN_DIR:$BASE_PATH"
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

# write_subproject_fixture <home>: a project that DECLARES sub-projects (the
# motivating zeigmal_mono monorepo with two integration-branch features), a plain
# project with none, and in-flight items - one tagged onto each sub-project by its
# base/integration branch, one ungrouped on the default branch, one in the plain
# project.
write_subproject_fixture() {
  local home=$1
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/projects.md" <<'EOF'
# Fleet project registry (firstmate-private)

- zeigmal_mono [no-mistakes +yolo] - Monorepo of integration features (added 2026-07-01)
  sub placement-tool | Placement Tool | feat/placement-tool
  sub outdoor-tour-navigation | Outdoor Tour Navigation | feat-outdoor-tour-navigation
- solo [direct-PR] - Plain project, no sub-projects (added 2026-07-02)
EOF
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] place-x1 - Wire the placement endpoint (repo: zeigmal_mono) (since 2026-07-10)
- [ ] tour-x3 - Add the tour route (repo: zeigmal_mono) (since 2026-07-10)
- [ ] main-x2 - Fix the shared header (repo: zeigmal_mono) (since 2026-07-10)
- [ ] solo-x4 - Tidy the solo app (repo: solo) (since 2026-07-10)
EOF
  # place-x1 targets a sub-project branch -> tagged placement-tool.
  fm_write_meta "$home/state/place-x1.meta" \
    "window=firstmate:fm-place-x1" "project=$home/projects/zeigmal_mono" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "base_branch=feat/placement-tool"
  # tour-x3 targets the other sub-project branch -> tagged outdoor-tour-navigation.
  fm_write_meta "$home/state/tour-x3.meta" \
    "window=firstmate:fm-tour-x3" "project=$home/projects/zeigmal_mono" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "base_branch=feat-outdoor-tour-navigation"
  # main-x2 targets the default branch (no base_branch) -> ungrouped.
  fm_write_meta "$home/state/main-x2.meta" \
    "window=firstmate:fm-main-x2" "project=$home/projects/zeigmal_mono" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  # solo-x4 lives in a project with no sub-projects -> ungrouped.
  fm_write_meta "$home/state/solo-x4.meta" \
    "window=firstmate:fm-solo-x4" "project=$home/projects/solo" \
    "harness=claude" "kind=ship" "mode=direct-PR" "yolo=off"
}

test_compose_declares_ordered_subprojects() {
  local home out
  home="$TMP_ROOT/compose-sub-declare"; write_subproject_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # The declaring project carries its sub-projects as an ORDERED {key,name,branch}
  # array, in declaration order.
  printf '%s' "$out" | jq -e '.projects[] | select(.name=="zeigmal_mono") | .subprojects
      == [ {"key":"placement-tool","name":"Placement Tool","branch":"feat/placement-tool"},
           {"key":"outdoor-tour-navigation","name":"Outdoor Tour Navigation","branch":"feat-outdoor-tour-navigation"} ]' >/dev/null \
    || fail "a declaring project must emit its ordered {key,name,branch} sub-project array"$'\n'"$out"
  # A project with no declarations emits an empty array, not a missing field.
  printf '%s' "$out" | jq -e '.projects[] | select(.name=="solo") | .subprojects == []' >/dev/null \
    || fail "a project with no sub-projects must emit an empty subprojects array"
  # The delivery mode still resolves correctly through the sub lines (a +yolo project).
  printf '%s' "$out" | jq -e '.projects[] | select(.name=="zeigmal_mono") | .mode=="no-mistakes"' >/dev/null \
    || fail "sub-project lines must not corrupt the project mode parse"
  pass "fm-logbook-compose declares a project's ordered sub-projects and leaves plain projects empty"
}

test_compose_tags_item_by_base_branch() {
  local home out
  home="$TMP_ROOT/compose-sub-tag"; write_subproject_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # An item whose base_branch matches a declared sub-project branch is tagged with
  # that sub-project's key; each item maps to its own sub-project.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="place-x1") | .subproject=="placement-tool"' >/dev/null \
    || fail "an item on a sub-project branch must be tagged with that sub-project key"
  printf '%s' "$out" | jq -e '.items[] | select(.id=="tour-x3") | .subproject=="outdoor-tour-navigation"' >/dev/null \
    || fail "each item maps to its own sub-project by branch"
  # The emitted subproject MUST match one of the parent project's declared keys.
  printf '%s' "$out" | jq -e '
      (.projects[] | select(.name=="zeigmal_mono") | [.subprojects[].key]) as $keys
      | .items[] | select(.id=="place-x1") | (.subproject | IN($keys[]))' >/dev/null \
    || fail "a tagged item's subproject must be a declared key of its project"
  # A default-branch item (no base_branch) is ungrouped: no subproject field at all.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="main-x2") | has("subproject") | not' >/dev/null \
    || fail "a default-branch item must emit no subproject"
  # An item in a project with no sub-projects is ungrouped too.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="solo-x4") | has("subproject") | not' >/dev/null \
    || fail "an item in a project with no sub-projects must emit no subproject"
  # The internal base-branch helper never leaks into the payload.
  printf '%s' "$out" | jq -e 'all(.items[]; has("_base_branch") | not)' >/dev/null \
    || fail "the internal _base_branch helper must be stripped from every item"
  pass "fm-logbook-compose tags each item onto its sub-project by base branch and leaves the rest ungrouped"
}

test_compose_no_declaration_is_backward_compatible() {
  local home out
  home="$TMP_ROOT/compose-sub-none"; write_fleet_fixture "$home"
  # The baseline fixture declares NO sub-projects: every project emits an empty
  # subprojects array and no item carries a subproject, so an adopter with no
  # declarations sees the exact prior payload plus empty grouping metadata.
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  printf '%s' "$out" | jq -e 'all(.projects[]; .subprojects == [])' >/dev/null \
    || fail "with no declarations every project must emit an empty subprojects array"
  printf '%s' "$out" | jq -e 'all(.items[]; has("subproject") | not)' >/dev/null \
    || fail "with no declarations no item may carry a subproject"
  # The rest of the payload is unchanged (same project and item counts as baseline).
  [ "$(printf '%s' "$out" | jq '.projects | length')" = 3 ] \
    || fail "no-declaration path must keep every registry project"
  [ "$(printf '%s' "$out" | jq '.items | length')" = 3 ] \
    || fail "no-declaration path must keep one card per in-flight task"
  pass "fm-logbook-compose is backward-compatible when no sub-projects are declared"
}

test_compose_skips_malformed_subproject_lines() {
  local home out err
  home="$TMP_ROOT/compose-sub-malformed"; mkdir -p "$home/data" "$home/state"
  cat > "$home/data/projects.md" <<'EOF'
# Registry

- mono [no-mistakes] - Monorepo (added 2026-07-02)
  sub good-key | Good Name | feat/good
  sub bad key | Bad Slug | feat/badslug
  sub emptyname |  | feat/x
  sub nodelims just words here
  sub piped | Display | With | Pipes | feat/piped
EOF
  : > "$home/data/backlog.md"
  err="$home/compose.err"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh" 2>"$err")
  # Only the two well-formed declarations survive; the invalid-key, empty-name, and
  # missing-delimiter lines are dropped (never emitted, so no item can map to them).
  printf '%s' "$out" | jq -e '.projects[] | select(.name=="mono") | [.subprojects[].key] == ["good-key","piped"]' >/dev/null \
    || fail "malformed and invalid-key sub-project lines must be skipped"$'\n'"$out"
  # A name may itself contain the " | " delimiter; the branch is always the last field.
  printf '%s' "$out" | jq -e '.projects[] | select(.name=="mono") | .subprojects[]
      | select(.key=="piped") | .name=="Display | With | Pipes" and .branch=="feat/piped"' >/dev/null \
    || fail "a sub-project name may contain the delimiter; the branch is the last field"
  # Each skip is reported (graceful, visible, never fatal).
  grep -q "skipping" "$err" || fail "a skipped sub-project line must warn on stderr"
  pass "fm-logbook-compose skips malformed sub-project lines gracefully and keeps the valid ones"
}

test_project_mode_unaffected_by_subproject_lines() {
  local home
  home="$TMP_ROOT/project-mode-sub"; write_subproject_fixture "$home"
  # The sub-project continuation lines must be invisible to fm-project-mode.sh: a
  # declaring project still resolves its exact mode and yolo, and a plain project
  # listed AFTER the sub lines resolves correctly too.
  [ "$(PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" zeigmal_mono)" = "no-mistakes on" ] \
    || fail "fm-project-mode must still read a declaring project's mode and yolo through its sub lines"
  [ "$(PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" solo)" = "direct-PR off" ] \
    || fail "fm-project-mode must read a plain project's mode after a declaring project's sub lines"
  pass "sub-project declarations do not break fm-project-mode.sh registry parsing"
}

# --- the item set comes from the durable backlog, not from live crew state ----

# write_hold_fixture <home>: the shape the board exists for. A crew's state/<id>.meta
# lives only while that crew runs, but the documented end-state for review-ready work
# is teardown + a captain hold (AGENTS.md section 7) - so here only ONE task still has
# a crew, and every task actually waiting on the captain has none. A meta-keyed board
# shows the one and hides the rest, which is exactly backwards.
write_hold_fixture() {
  local home=$1
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/projects.md" <<'EOF'
# Fleet project registry (firstmate-private)

- alpha [no-mistakes] - First project (added 2026-07-01)
- beta [direct-PR] - Second project (added 2026-07-02)
EOF
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] held-pr-h1 - Trim the AR forms https://github.com/acme/alpha/pull/699 (repo: alpha) (kind: ship) (since 2026-07-10) (hold: review-ready - CI green, review passed - captain reviews then merges) (hold-kind: captain)
- [ ] held-ask-h2 - Multi-line text answers (repo: beta) (kind: ship) (since 2026-07-10) (hold: designed with the captain, awaiting their go-ahead to dispatch) (hold-kind: captain)
- [ ] parked-h3 - Fix the batch spawn (repo: alpha) (kind: ship) (since 2026-07-05) blocked-by: held-ask-h2
- [ ] live-h4 - Wire the widget endpoint (repo: alpha) (kind: ship) (since 2026-07-10)
- [ ] holdprose-i2 - Chase the upstream fix (repo: alpha) (kind: ship) (since 2026-07-11) (hold: nothing to do until https://github.com/acme/other/pull/5 lands - say the word to close it out) (hold-kind: captain)
## Queued
- [ ] q-held-h5 - Reword the section 15 rule (repo: alpha) (kind: ship) (since 2026-07-16) (hold: awaiting the captain's word on reword vs delete) (hold-kind: captain)
- [ ] q-plain-h6 - Not dispatched yet (repo: beta) (kind: ship)
- [ ] norepo-i3 - Relay the captain's answer on the nav copy (since 2026-07-12) (hold: awaiting their word on reword vs delete) (hold-kind: captain)
## Done
- [x] done-h7 - Landed already - <https://github.com/acme/alpha/pull/600> (merged 2026-07-09)
EOF
  # ONLY live-h4 still has a crew. fm-teardown removes the meta AND the status
  # together, so every other task here has neither - the real post-teardown shape.
  fm_write_meta "$home/state/live-h4.meta" \
    "window=firstmate:fm-live-h4" "project=$home/projects/alpha" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf 'working: wiring the endpoint\n' > "$home/state/live-h4.status"
}

test_compose_captain_hold_survives_teardown() {
  local home out
  home="$TMP_ROOT/compose-hold-teardown"; write_hold_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # THE regression: a captain-held task whose crew is torn down has no meta at all,
  # and used to vanish from the board at the exact moment it started needing the
  # captain. It must compose a card carrying its own hold reason.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="held-pr-h1")' >/dev/null \
    || fail "a captain-held task with a torn-down crew must still compose a card"$'\n'"$out"
  printf '%s' "$out" | jq -e '.items[] | select(.id=="held-pr-h1")
      | (.project=="alpha") and (.title=="Trim the AR forms")
      and (.body | test("captain reviews then merges"))' >/dev/null \
    || fail "a captain-held card must carry its hold reason as the body"
  # It has a ready PR, so it is a concrete action, not a question: merge it.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="held-pr-h1")
      | (.kind=="action") and ([.options[].value] | index("merge") != null)
      and (.source.pr=="https://github.com/acme/alpha/pull/699")' >/dev/null \
    || fail "a captain-held task with a PR must be an action card carrying the PR"
  # And the PR must be CLICKABLE: the board's renderer linkifies "[text](http...)"
  # only - it never renders source.pr and never autolinks a bare url - so a markdown
  # link in the body is the only thing the captain can actually click.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="held-pr-h1")
      | .body | test("\\[alpha #699\\]\\(https://github\\.com/acme/alpha/pull/699\\)")' >/dev/null \
    || fail "a captain-held card's PR must appear as a markdown link in the body"$'\n'"$out"
  pass "fm-logbook-compose keeps a captain-held task on the board after its crew is torn down"
}

test_compose_pr_is_read_only_from_the_structured_position() {
  local home out
  home="$TMP_ROOT/compose-pr-position"; write_hold_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # A hold reason is free-form prose, and firstmate routinely writes one citing
  # ANOTHER task's PR. Harvesting that url would offer to merge an unrelated repo's
  # PR, and a "merge" answer on the board is genuine captain authorization - so a url
  # only in prose is not this task's PR, and the card stays a question to answer.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="holdprose-i2")
      | (.source | has("pr") | not) and (.kind=="decision") and (.options == [])' >/dev/null \
    || fail "a url only in hold prose must NOT be harvested as the task's PR"$'\n'"$out"
  # The prose itself is still the captain's context, url text and all.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="holdprose-i2")
      | .body | test("nothing to do until https://github\\.com/acme/other/pull/5 lands")' >/dev/null \
    || fail "a hold reason citing another PR must still read as the card body"$'\n'"$out"
  # The other side of the boundary: the structured position IS harvested, and the url
  # is then stripped from the title rather than read to the captain twice.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="held-pr-h1")
      | (.source.pr=="https://github.com/acme/alpha/pull/699")
      and (.title=="Trim the AR forms")' >/dev/null \
    || fail "a url in the structured title position must be harvested and left out of the title"$'\n'"$out"
  pass "fm-logbook-compose harvests a PR only from the structured position, never from prose"
}

# write_link_fixture <home>: the link run and the Merge gate. Nearly every task here
# carries a PR-shaped url in the structured title position, so what separates a Merge
# card from a plain one is only ever whether that url is really this task's and whether
# the work is ready - never the url's mere position. Each line is written the way
# tasks-axi itself emits it (verified against 0.2.2, which validates "--pr" as an
# http(s) url ending in "/pull/<number>" and "--report" as a "data/<id>/report.md"
# path, and appends both into the title in the order they were recorded).
#
# The blockers are deliberately of every STATE, not just unfinished ones: "blocked-by:"
# is never rewritten when a blocker lands, so a fixture whose blockers are all in flight
# cannot tell a gate that reads the dependency from one that reads the marker - they
# agree on every such line. cleared-j2/prunedblk-k3/multiblk-l4 are what separates them.
write_link_fixture() {
  local home=$1
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/projects.md" <<'EOF'
# Fleet project registry (firstmate-private)

- alpha [no-mistakes] - First project (added 2026-07-01)
EOF
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] promo-b2 - Other way round https://github.com/acme/alpha/pull/89 data/promo-b2/report.md (repo: alpha) (kind: ship) (hold: review-ready - captain reviews then merges) (hold-kind: captain)
- [ ] promo-a1 - Report first data/promo-a1/report.md https://github.com/acme/alpha/pull/90 (repo: alpha) (kind: ship) (hold: review-ready - captain reviews then merges) (hold-kind: captain)
- [ ] issueurl-c4 - Mirror the upstream fix https://github.com/acme/other/issues/9 (repo: alpha) (kind: ship)
- [ ] xrepo-d5 - Port the same change https://github.com/acme/other/pull/5 (repo: alpha) (kind: ship) (hold: review-ready - captain reviews then merges) (hold-kind: captain)
- [ ] extheld-e6 - Externally held https://github.com/acme/alpha/pull/12 (repo: alpha) (kind: ship) (hold: waiting on upstream CI) (hold-kind: external)
- [ ] nomarker-f7 - Relay the answer https://github.com/acme/alpha/pull/11 (kind: ship) (hold: review-ready) (hold-kind: captain)
- [ ] blocked-g8 - Held and blocked https://github.com/acme/alpha/pull/50 blocked-by: extheld-e6 (repo: alpha) (kind: ship) (hold: review-ready - captain reviews then merges) (hold-kind: captain)
- [ ] blockplain-h9 - Blocked, no hold https://github.com/acme/alpha/pull/51 blocked-by: extheld-e6 (repo: alpha) (kind: ship)
- [ ] blockdoc-i1 - Blocked the documented way https://github.com/acme/alpha/pull/52 (repo: alpha) blocked-by: extheld-e6 - waiting on the schema
- [ ] cleared-j2 - Blocker landed, now review-ready https://github.com/acme/alpha/pull/53 blocked-by: landed-w0 (repo: alpha) (kind: ship) (hold: review-ready - captain reviews then merges) (hold-kind: captain)
- [ ] prunedblk-k3 - Blocker pruned out of Done https://github.com/acme/alpha/pull/54 blocked-by: ghost-z9 (repo: alpha) (kind: ship) (hold: review-ready - captain reviews then merges) (hold-kind: captain)
- [ ] multiblk-l4 - One landed, one still running https://github.com/acme/alpha/pull/55 blocked-by: landed-w0 blocked-by: extheld-e6 (repo: alpha) (kind: ship) (hold: review-ready - captain reviews then merges) (hold-kind: captain)
- [ ] superseded-m5 - First PR closed, work moved https://github.com/acme/alpha/pull/682 https://github.com/acme/alpha/pull/687 (repo: alpha) (kind: ship) (hold: review-ready - captain reviews then merges) (hold-kind: captain)
## Done
- [x] landed-w0 - The blocker that landed https://github.com/acme/alpha/pull/49 (repo: alpha) (kind: ship) (merged 2026-07-13)
EOF
}

test_compose_link_run_holds_reports_as_well_as_prs() {
  local home out
  home="$TMP_ROOT/compose-link-run"; write_link_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # tasks-axi appends BOTH "--pr" and "--report" links into the title, in whatever
  # order they were recorded - a promoted scout (AGENTS.md section 7) keeps its report
  # and gains a PR. Modelling the run as urls only stopped the peel dead at the report
  # path, losing the Merge option AND the clickable link of a review-ready PR: the very
  # regression this composer exists to fix. Both orders must peel clean and harvest.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="promo-b2")
      | (.title=="Other way round") and (.kind=="action")
      and (.source.pr=="https://github.com/acme/alpha/pull/89")
      and (.body | test("\\[alpha #89\\]\\(https://github\\.com/acme/alpha/pull/89\\)"))' >/dev/null \
    || fail "a report path AFTER the PR must not hide the PR behind it"$'\n'"$out"
  printf '%s' "$out" | jq -e '.items[] | select(.id=="promo-a1")
      | (.title=="Report first") and (.kind=="action")
      and (.source.pr=="https://github.com/acme/alpha/pull/90")' >/dev/null \
    || fail "a report path BEFORE the PR must peel out of the title too"$'\n'"$out"
  pass "fm-logbook-compose peels report paths and PRs from the link run in either order"
}

test_compose_keeps_a_url_the_captain_wrote_in_the_title() {
  local home out
  home="$TMP_ROOT/compose-title-url"; write_link_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # A trailing url that is NOT link-run bookkeeping - here an issue link a human wrote
  # into their own one-liner - is the captain's own words. Peeling every trailing url
  # deleted it with nothing rendered in its place; only the two shapes tasks-axi
  # appends are bookkeeping, so this one stays where the captain put it.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="issueurl-c4")
      | (.title=="Mirror the upstream fix https://github.com/acme/other/issues/9")
      and (.source | has("pr") | not)' >/dev/null \
    || fail "a non-link-run url must stay in the title, not vanish"$'\n'"$out"
  pass "fm-logbook-compose leaves a url the captain wrote into their one-liner in the title"
}

test_compose_merge_needs_a_repo_matched_pr() {
  local home out
  home="$TMP_ROOT/compose-pr-repo"; write_link_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # The structured position is necessary but not sufficient: a captain who ends their
  # own one-liner with ANOTHER repo's PR hands it that position. A "merge" answer on
  # the board is genuine captain authorization and merging is irreversible, so the
  # Merge option needs the url's repo to match the item's own "(repo: ...)" marker.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="xrepo-d5")
      | (.kind=="decision") and (.options == [])' >/dev/null \
    || fail "a PR naming another repo must NOT earn a Merge option"$'\n'"$out"
  # Only the one click is withheld: the url still reaches the captain as a link.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="xrepo-d5")
      | (.source.pr=="https://github.com/acme/other/pull/5")
      and (.body | test("\\[other #5\\]\\(https://github\\.com/acme/other/pull/5\\)"))' >/dev/null \
    || fail "an unverified PR must still render as a link in the body"$'\n'"$out"
  # And the matching case still merges, or the feature would be silently broken.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="promo-b2")
      | [.options[].value] | index("merge") != null' >/dev/null \
    || fail "a PR whose repo matches the item's marker must still offer Merge"$'\n'"$out"
  pass "fm-logbook-compose offers Merge only for a PR matching the item's own repo marker"
}

test_compose_merge_needs_a_repo_marker_to_verify_against() {
  local home out
  home="$TMP_ROOT/compose-pr-nomarker"; write_link_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # No "(repo: ...)" marker at all - the normal shape of the captain-gated thread
  # AGENTS.md section 10 recommends. The PR cannot be verified as this task's, so the
  # conservative reading of "only when it matches" withholds the Merge.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="nomarker-f7")
      | (.kind=="decision") and (.options == [])
      and (.body | test("\\[alpha #11\\]\\(https://github\\.com/acme/alpha/pull/11\\)"))' >/dev/null \
    || fail "an item with no repo marker must not offer Merge, but must keep the link"$'\n'"$out"
  pass "fm-logbook-compose withholds Merge when there is no repo marker to verify against"
}

# write_remote_fixture <home>: the Merge gate's repo verification. Every task here
# carries a PR-shaped url in the structured title position, so the only thing that can
# separate a Merge card from a plain one is whether that url names the repo the task's
# project actually pushes to. The clones are fixtures under THIS home's own projects/
# dir (FM_HOME scopes it), never the machine's real ones, and compose only ever reads
# their "origin" - which is why a bare "git init" with a remote and no commit is a
# complete fixture.
write_remote_fixture() {
  local home=$1
  mkdir -p "$home/data" "$home/state" "$home/projects"
  cat > "$home/data/projects.md" <<'EOF'
# Fleet project registry (firstmate-private)

- alpha [no-mistakes] - First project (added 2026-07-01)
- movebank-explorer [no-mistakes] - Cloned under a name of its own (added 2026-07-02)
- gone [no-mistakes] - Registered but not cloned here (added 2026-07-03)
- solo [local-only] - No remote at all (added 2026-07-04)
EOF
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] combined-a1 - Ship the widget endpoint https://github.com/acme/alpha/pull/42 (repo: alpha, since 2026-07-10)
- [ ] renamed-b2 - Ship the tracker view https://github.com/SchokoShake/movebank/pull/42 (repo: movebank-explorer) (kind: ship) (hold: review-ready - captain reviews then merges) (hold-kind: captain)
- [ ] spoof-c3 - Looks local, is not https://github.com/acme/movebank-explorer/pull/13 (repo: movebank-explorer) (kind: ship) (hold: review-ready - captain reviews then merges) (hold-kind: captain)
- [ ] noclone-d4 - Ship the uncloned thing https://github.com/acme/gone/pull/8 (repo: gone) (kind: ship) (hold: review-ready - captain reviews then merges) (hold-kind: captain)
- [ ] noremote-e5 - Ship the solo thing https://github.com/acme/solo/pull/9 (repo: solo) (kind: ship) (hold: review-ready - captain reviews then merges) (hold-kind: captain)
EOF
  git init -q "$home/projects/alpha"
  git -C "$home/projects/alpha" remote add origin https://github.com/acme/alpha.git
  # The clone-rename case, in the SSH remote form: the directory the captain chose and
  # the repo GitHub knows are simply different names.
  git init -q "$home/projects/movebank-explorer"
  git -C "$home/projects/movebank-explorer" remote add origin git@github.com:SchokoShake/movebank.git
  # A local-only project (AGENTS.md section 6): a real clone with no remote at all.
  git init -q "$home/projects/solo"
}

test_compose_merge_survives_the_documented_combined_repo_marker() {
  local home out
  home="$TMP_ROOT/compose-remote-combined"; write_remote_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # AGENTS.md section 10 documents the hand-maintained in-flight form as ONE combined
  # "(repo: <name>, since <date>)" marker. Reading the whole value as the project would
  # yield "alpha, since 2026-07-10": not a usable project name, not a repo any url can
  # match, and so - once the marker became load-bearing for the gate - no Merge for any
  # card under the manual backend this composer explicitly serves.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="combined-a1")
      | (.kind=="action") and ([.options[].value] | index("merge") != null)
      and (.project=="alpha") and (.title=="Ship the widget endpoint")' >/dev/null \
    || fail "the documented combined repo marker must still compose a Merge"$'\n'"$out"
  pass "fm-logbook-compose reads the bare project name out of a combined repo marker"
}

test_compose_merge_follows_the_clone_to_its_real_repo() {
  local home out
  home="$TMP_ROOT/compose-remote-rename"; write_remote_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # The local directory name is the captain's free choice ("git clone <url>
  # projects/<name>", AGENTS.md section 6), so it is only incidentally the repo name.
  # Verifying against the clone's real origin is what lets a renamed clone earn a
  # Merge; verifying against the marker text would withhold it forever.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="renamed-b2")
      | (.kind=="action") and ([.options[].value] | index("merge") != null)
      and (.source.pr=="https://github.com/SchokoShake/movebank/pull/42")' >/dev/null \
    || fail "a PR matching the clone's real origin must earn Merge even when the directory name differs"$'\n'"$out"
  # And the origin is the AUTHORITY, not merely a second chance: a url that matches the
  # marker text but NOT the repo the project really pushes to is a proven mismatch.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="spoof-c3")
      | (.kind=="decision") and (.options == [])
      and (.body | test("\\[movebank-explorer #13\\]\\(https://github\\.com/acme/movebank-explorer/pull/13\\)"))' >/dev/null \
    || fail "a resolved origin must overrule a matching marker, while keeping the link"$'\n'"$out"
  pass "fm-logbook-compose verifies a PR against the clone's real origin, not the directory name"
}

test_compose_merge_falls_back_when_no_remote_resolves() {
  local home out
  home="$TMP_ROOT/compose-remote-absent"; write_remote_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # No clone here at all: the infrastructure is absent, which proves nothing about the
  # PR. Withholding Merge on that would be the very regression this composer exists to
  # fix, so the marker still stands in.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="noclone-d4")
      | (.kind=="action") and ([.options[].value] | index("merge") != null)' >/dev/null \
    || fail "a missing clone must fall back to the marker, not withhold Merge"$'\n'"$out"
  # Same for a local-only project, which legitimately has no remote to resolve.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="noremote-e5")
      | (.kind=="action") and ([.options[].value] | index("merge") != null)' >/dev/null \
    || fail "a clone with no origin must fall back to the marker, not withhold Merge"$'\n'"$out"
  pass "fm-logbook-compose falls back to the repo marker when no remote resolves"
}

test_compose_never_writes_to_a_project_clone() {
  local home out before after
  home="$TMP_ROOT/compose-remote-readonly"; write_remote_fixture "$home"
  # Prime directive 1: firstmate must NEVER write to a project. Compose now reaches
  # into projects/ to read an origin, so pin that the reach stays read-only.
  before=$(cd "$home/projects" && find . -newer "$home/data/backlog.md" | sort; git -C "$home/projects/alpha" status --porcelain)
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  [ -n "$out" ] || fail "compose must still emit a board"
  after=$(cd "$home/projects" && find . -newer "$home/data/backlog.md" | sort; git -C "$home/projects/alpha" status --porcelain)
  [ "$before" = "$after" ] \
    || fail "compose must not write anything inside projects/"$'\n'"before: $before"$'\n'"after: $after"
  pass "fm-logbook-compose reads a project clone's origin without writing to it"
}

test_compose_non_captain_hold_with_a_pr_is_not_a_merge() {
  local home out
  home="$TMP_ROOT/compose-ext-hold"; write_link_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # An ACTIVE non-captain hold is the fleet's own record that the work is not ready.
  # Offering Merge there would caption the button with the very reason the work is
  # blocked, so it drops to an fyi that simply says why it is sitting still.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="extheld-e6")
      | (.kind=="fyi") and (.options == [])
      and (.body | test("waiting on upstream CI"))
      and (.body | test("\\[alpha #12\\]\\(https://github\\.com/acme/alpha/pull/12\\)"))' >/dev/null \
    || fail "an externally-held task's PR must not be offered for merge"$'\n'"$out"
  pass "fm-logbook-compose never offers Merge on work the fleet has recorded as not-ready"
}

test_compose_blocked_by_is_not_a_merge() {
  local home out
  home="$TMP_ROOT/compose-blocked"; write_link_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # "blocked-by: <id>" is the OTHER form of firstmate's not-ready record (AGENTS.md
  # section 10), so it gates the Merge exactly as an active hold does: merging is
  # irreversible, and landing a change over the fleet's own record that it waits on an
  # unfinished dependency is the same contradiction either way.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="blocked-g8")
      | (.options == [])' >/dev/null \
    || fail "a task blocked by an unfinished dependency must NOT offer Merge"$'\n'"$out"
  # The captain is still holding it, so it stays the question that hold poses - and the
  # url still reaches them as a link. Only the one click is withheld.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="blocked-g8")
      | (.kind=="decision")
      and (.body | test("\\[alpha #50\\]\\(https://github\\.com/acme/alpha/pull/50\\)"))' >/dev/null \
    || fail "a blocked captain-held task must stay a decision carrying its link"$'\n'"$out"
  # With no captain hold, it falls through to fyi, exactly like an active hold does.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="blockplain-h9")
      | (.kind=="fyi") and (.options == [])
      and (.body | test("\\[alpha #51\\]\\(https://github\\.com/acme/alpha/pull/51\\)"))' >/dev/null \
    || fail "an unheld blocked task must fall through to fyi with no Merge"$'\n'"$out"
  # BOTH documented placements gate. AGENTS.md section 10 writes "blocked-by:" AFTER the
  # "(repo: ...)" marker, where the tasks-axi backend puts it BEFORE the marker tail -
  # so reading the record off the title alone would gate one backend and silently never
  # gate the hand-maintained one this composer explicitly serves.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="blockdoc-i1")
      | (.kind=="fyi") and (.options == [])' >/dev/null \
    || fail "the documented blocked-by placement must gate the Merge too"$'\n'"$out"
  # And the gate is the dependency record, not the mere presence of a PR: an identical
  # captain-held task with nothing blocking it still merges in one click.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="promo-b2")
      | (.kind=="action") and ([.options[].value] | index("merge") != null)' >/dev/null \
    || fail "an unblocked captain-held task must still offer Merge"$'\n'"$out"
  pass "fm-logbook-compose withholds Merge from a task blocked by an unfinished dependency"
}

test_compose_blocked_by_gate_clears_when_the_blocker_lands() {
  local home out
  home="$TMP_ROOT/compose-blocked-clears"; write_link_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # The other half of the gate, and the one a marker-presence read gets wrong: NOTHING
  # ever rewrites "blocked-by: <id>" when the blocker lands - tasks-axi resolves a
  # dependency by looking up the blocker's state (verified against 0.2.2). So this line
  # is what a task filed with --blocked-by looks like AFTER its blocker merged, it was
  # dispatched, shipped, and left review-ready on a captain hold: the marker is still
  # there, and reading it as the answer withholds Merge from ready work forever.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="cleared-j2")
      | (.kind=="action") and ([.options[].value] | index("merge") != null)' >/dev/null \
    || fail "a blocker that has landed must stop gating the Merge"$'\n'"$out"
  # An UNKNOWN blocker is the same answer, and is the steady state rather than an edge:
  # "done_keep = 10" prunes finished tasks out of the backlog into data/done-archive.md
  # (AGENTS.md section 10) while every dependent's marker survives, so a long-landed
  # blocker is normally absent entirely. Counting absence as unresolved would re-break
  # this gate the moment a blocker aged out of Done.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="prunedblk-k3")
      | (.kind=="action") and ([.options[].value] | index("merge") != null)' >/dev/null \
    || fail "a blocker pruned out of Done must not gate the Merge forever"$'\n'"$out"
  # Several blockers gate on ANY unfinished one: "tasks-axi block" and "--blocked-by" are
  # repeatable, and the backend emits one marker each, so reading only the first record
  # would clear this the moment the earlier blocker landed.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="multiblk-l4")
      | (.kind=="decision") and (.options == [])' >/dev/null \
    || fail "one landed blocker must not clear the gate while another is unfinished"$'\n'"$out"
  # The bookkeeping still never reaches the captain, however many records the line holds.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="multiblk-l4")
      | .title=="One landed, one still running"' >/dev/null \
    || fail "repeated blocked-by records must not leak into the title"$'\n'"$out"
  pass "fm-logbook-compose clears the blocked-by gate once the blocker is finished"
}

test_compose_newest_pr_wins_a_superseded_link_run() {
  local home out
  home="$TMP_ROOT/compose-superseded"; write_link_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # A link run can hold SEVERAL PRs: "tasks-axi update --pr" is a no-op only for a url
  # already recorded, so re-recording a DIFFERENT one appends it, oldest-first (verified
  # against 0.2.2). That is a task whose PR was superseded - the first closed, the work
  # moved on - and offering Merge on the leftmost hands the captain the DEAD PR.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="superseded-m5")
      | (.source.pr=="https://github.com/acme/alpha/pull/687")
      and (.kind=="action") and ([.options[].value] | index("merge") != null)' >/dev/null \
    || fail "the newest PR in a link run must win, not the superseded one"$'\n'"$out"
  # The whole run still peels off the title, and only the live PR is read to the captain.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="superseded-m5")
      | (.title=="First PR closed, work moved")
      and (.body | test("\\[alpha #687\\]\\(https://github\\.com/acme/alpha/pull/687\\)"))
      and (.body | test("682") | not)' >/dev/null \
    || fail "a superseded run must peel clean and link only the newest PR"$'\n'"$out"
  pass "fm-logbook-compose picks the newest PR when a link run holds a superseded one"
}

# write_nested_home_fixture <home>: a firstmate home that is itself inside a git repo -
# the SHIPPED layout, where FM_HOME is firstmate's own checkout - with a projects/<name>
# that exists but is not a clone. git's repo discovery walks UP from its -C directory,
# so an unbounded lookup answers with the enclosing repo's origin here.
write_nested_home_fixture() {
  local home=$1 outer
  outer="$home/outer"
  mkdir -p "$outer"
  git init -q "$outer"
  git -C "$outer" remote add origin https://github.com/SchokoShake/firstmate.git
  mkdir -p "$outer/home/data" "$outer/home/state" "$outer/home/projects/alpha"
  cat > "$outer/home/data/projects.md" <<'EOF'
# Fleet project registry (firstmate-private)

- alpha [no-mistakes] - First project (added 2026-07-01)
EOF
  cat > "$outer/home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] nested-a1 - Ship the widget https://github.com/acme/alpha/pull/11 (repo: alpha) (kind: ship) (hold: review-ready - captain reviews then merges) (hold-kind: captain)
EOF
}

test_compose_remote_lookup_cannot_escape_a_non_repo_project_dir() {
  local home out
  home="$TMP_ROOT/compose-nested-home"; write_nested_home_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home/outer/home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # projects/alpha is a directory but not a clone, which proves NOTHING about the PR -
  # so the repo marker stands in and the Merge holds (the absent-clone fallback). Let
  # discovery escape and it resolves the ENCLOSING repo's origin instead: every card
  # would read "firstmate" as the repo its project pushes to, call the match a proven
  # mismatch, and silently withhold every Merge on the board - inverting the fallback
  # into the exact regression this composer exists to fix.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="nested-a1")
      | (.kind=="action") and ([.options[].value] | index("merge") != null)' >/dev/null \
    || fail "a non-repo projects/<name> must fall back to the marker, not resolve the enclosing repo"$'\n'"$out"
  pass "fm-logbook-compose bounds its remote lookup at projects/ and cannot escape upward"
}

test_compose_title_drops_the_marker_tail_without_a_repo() {
  local home out
  home="$TMP_ROOT/compose-norepo"; write_hold_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # "--repo" is optional, and the captain-gated thread AGENTS.md section 10 recommends
  # normally has none. Every marker ends the title, not "(repo: " alone, or the whole
  # tail would be read to the captain as their one-liner.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="norepo-i3")
      | (.title=="Relay the captain'"'"'s answer on the nav copy") and (.kind=="decision")
      and (.project=="") and (.body | test("reword vs delete"))' >/dev/null \
    || fail "an item with no repo marker must still get a clean title"$'\n'"$out"
  pass "fm-logbook-compose keeps the marker tail out of a title when the item has no repo"
}

test_compose_captain_hold_without_pr_is_a_decision() {
  local home out
  home="$TMP_ROOT/compose-hold-ask"; write_hold_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # No PR to merge: the captain owes an answer, not an action.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="held-ask-h2")
      | (.kind=="decision") and (.project=="beta")
      and (.body | test("awaiting their go-ahead"))
      and (.options == []) and (.source | has("pr") | not)' >/dev/null \
    || fail "a captain-held task with no PR must be a decision card carrying its hold reason"$'\n'"$out"
  pass "fm-logbook-compose makes a captain hold with no PR a decision, with its reason as the body"
}

test_compose_queued_captain_hold_is_carded() {
  local home out
  home="$TMP_ROOT/compose-hold-queued"; write_hold_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # A captain hold is waiting on the captain whatever the task's state, so a QUEUED
  # one earns a card too - it is the captain's word that would start it.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="q-held-h5")
      | (.kind=="decision") and (.body | test("reword vs delete"))' >/dev/null \
    || fail "a captain-held QUEUED task must compose a decision card"$'\n'"$out"
  pass "fm-logbook-compose cards a captain-held task even from Queued"
}

test_compose_board_is_not_a_backlog_mirror() {
  local home out
  home="$TMP_ROOT/compose-not-mirror"; write_hold_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # The board is "what needs the captain", not every row of the backlog: queued work
  # behind no captain gate is firstmate's to run, and Done work has landed.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="q-plain-h6")' >/dev/null \
    && fail "ungated queued work must NOT be on the board"
  printf '%s' "$out" | jq -e '.items[] | select(.id=="done-h7")' >/dev/null \
    && fail "Done work must NOT be on the board"
  # In flight (with or without a crew) and captain-held: 7 cards, no more.
  [ "$(printf '%s' "$out" | jq '.items | length')" = 7 ] \
    || fail "the board must carry exactly the in-flight and captain-held tasks"$'\n'"$out"
  pass "fm-logbook-compose keeps ungated queued work and Done off the board"
}

test_compose_in_flight_without_crew_is_carded() {
  local home out
  home="$TMP_ROOT/compose-parked"; write_hold_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # In-flight work whose crew is gone (parked, blocked) is still live work: it stays
  # visible as a plain fyi, and the "blocked-by:" bookkeeping never reaches the title.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="parked-h3")
      | (.kind=="fyi") and (.title=="Fix the batch spawn")' >/dev/null \
    || fail "in-flight work with no crew must still compose an fyi card, with a clean title"$'\n'"$out"
  pass "fm-logbook-compose keeps crewless in-flight work on the board as an fyi"
}

test_compose_live_crew_enriches_the_backlog_item() {
  local home out
  home="$TMP_ROOT/compose-enrich"; write_hold_fixture "$home"
  # A live crew's meta is the authority on the RUNNING crew: its recorded pr= wins
  # over the backlog, and its status drives the card's kind.
  fm_write_meta "$home/state/held-ask-h2.meta" \
    "window=firstmate:fm-held-ask-h2" "project=$home/projects/beta" \
    "harness=claude" "kind=ship" "mode=direct-PR" "yolo=off" \
    "pr=https://github.com/acme/beta/pull/7"
  printf 'working: drafting\nneeds-decision: newline key - shift+enter or enter?\n' \
    > "$home/state/held-ask-h2.status"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # A live crew's open question outranks the captain hold (decision > action), and its
  # meta-recorded PR still rides along as a clickable link.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="held-ask-h2")
      | (.kind=="decision") and (.body | test("shift\\+enter or enter"))
      and (.source.pr=="https://github.com/acme/beta/pull/7")
      and (.body | test("\\[beta #7\\]\\(https://github\\.com/acme/beta/pull/7\\)"))' >/dev/null \
    || fail "a live crew's meta and status must enrich the backlog-derived item"$'\n'"$out"
  pass "fm-logbook-compose enriches a backlog item from its live crew's meta and status"
}

test_compose_live_crew_missing_from_backlog_is_carded() {
  local home out
  home="$TMP_ROOT/compose-orphan"; write_hold_fixture "$home"
  # The window between fm-spawn and the backlog write: a running crew whose task is
  # not in the backlog at all must never be hidden by a bookkeeping gap.
  fm_write_meta "$home/state/unlogged-h8.meta" \
    "window=firstmate:fm-unlogged-h8" "project=$home/projects/alpha" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf 'working: just started\n' > "$home/state/unlogged-h8.status"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  printf '%s' "$out" | jq -e '.items[] | select(.id=="unlogged-h8")
      | (.kind=="fyi") and (.project=="alpha") and (.body=="just started")' >/dev/null \
    || fail "a live crew missing from the backlog must still compose a card"$'\n'"$out"
  pass "fm-logbook-compose still cards a live crew the backlog has not recorded yet"
}

test_compose_done_drops_even_with_a_lingering_meta() {
  local home out
  home="$TMP_ROOT/compose-done-meta"; write_hold_fixture "$home"
  # Between the merge and the teardown a Done task still has its meta. The backlog
  # decides: the work landed, so nothing is owed and the stale "ready to merge" card
  # must not linger.
  fm_write_meta "$home/state/done-h7.meta" \
    "window=firstmate:fm-done-h7" "project=$home/projects/alpha" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "pr=https://github.com/acme/alpha/pull/600"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  printf '%s' "$out" | jq -e '.items[] | select(.id=="done-h7")' >/dev/null \
    && fail "a Done task must drop off the board even while its meta lingers"$'\n'"$out"
  pass "fm-logbook-compose drops a Done task even before its crew is torn down"
}

test_compose_expired_hold_gate_is_not_a_hold() {
  local home out
  home="$TMP_ROOT/compose-hold-until"; mkdir -p "$home/data" "$home/state"
  printf '# Registry\n\n- alpha [no-mistakes] - First project (added 2026-07-01)\n' > "$home/data/projects.md"
  # A "(hold-until: <date>)" gate is inactive ON and after that date - which is what
  # tasks-axi itself reports as "held: no" - so an arrived gate must not pin a card.
  # The past gate expires (in-flight -> plain fyi); the future one still holds.
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] gate-past-h9 - Past gate (repo: alpha) (kind: ship) (hold: waited long enough) (hold-kind: captain) (hold-until: 2020-01-01)
- [ ] gate-future-i1 - Future gate (repo: alpha) (kind: ship) (hold: not yet) (hold-kind: captain) (hold-until: 2099-01-01)
## Queued
## Done
EOF
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # The lapsed gate drops the hold AND its now-stale prose, so nothing reads as a
  # live reason on the card; the future gate keeps both.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="gate-past-h9")
      | (.kind=="fyi") and (.body=="Work is underway.")' >/dev/null \
    || fail "an ARRIVED hold-until gate must stop being a captain hold, reason and all"$'\n'"$out"
  printf '%s' "$out" | jq -e '.items[] | select(.id=="gate-future-i1")
      | (.kind=="decision") and (.body=="not yet")' >/dev/null \
    || fail "a future hold-until gate must still be an active captain hold"$'\n'"$out"
  pass "fm-logbook-compose expires a hold-until gate exactly as tasks-axi reports it"
}

test_compose_hold_reason_survives_the_captains_own_parentheses() {
  local home out
  home="$TMP_ROOT/compose-hold-parens"; mkdir -p "$home/data" "$home/state"
  printf '# Registry\n\n- alpha [no-mistakes] - First project (added 2026-07-01)\n' > "$home/data/projects.md"
  # A hold reason is free-form human prose and becomes the card body VERBATIM, so it is
  # the one marker value that can itself contain ")". The tasks-axi backend rejects a
  # "--reason" with parentheses ("Parentheses are reserved for markdown hold tags"), but
  # a backlog hand-maintained under config/backlog-backend=manual has no such gate - and
  # this composer explicitly serves both backends. Ending the reason at the FIRST ")"
  # dropped everything after the captain's own parenthetical: the actionable half.
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] paren-mid-j1 - Roll out v2 (repo: alpha) (kind: ship) (hold: waiting on the API (v2) rollout - your call) (hold-kind: captain)
- [ ] paren-eol-j2 - Nothing after it (repo: alpha) (kind: ship) (hold: waiting on the API (v2) rollout - your call)
- [ ] paren-gate-j3 - Gated too (repo: alpha) (kind: ship) (hold: blocked by the (legacy) importer - say the word) (hold-kind: captain) (hold-until: 2099-01-01)
- [ ] paren-none-j4 - Plain prose (repo: alpha) (kind: ship) (hold: review-ready - captain reviews then merges) (hold-kind: captain)
## Queued
## Done
EOF
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # The reason ends where the marker tail resumes, not at the first ")".
  printf '%s' "$out" | jq -e '.items[] | select(.id=="paren-mid-j1")
      | .body=="waiting on the API (v2) rollout - your call"' >/dev/null \
    || fail "a parenthetical in a hold reason must not truncate the card body"$'\n'"$out"
  # ... or at end-of-line, when no marker follows to end it.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="paren-eol-j2")
      | .body=="waiting on the API (v2) rollout - your call"' >/dev/null \
    || fail "a trailing hold reason must keep its parenthetical too"$'\n'"$out"
  printf '%s' "$out" | jq -e '.items[] | select(.id=="paren-gate-j3")
      | .body=="blocked by the (legacy) importer - say the word"' >/dev/null \
    || fail "a hold-until gate after the reason must not truncate its parenthetical"$'\n'"$out"
  # The ordinary no-parenthesis reason the tasks-axi backend emits is unchanged.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="paren-none-j4")
      | .body=="review-ready - captain reviews then merges"' >/dev/null \
    || fail "a plain hold reason must still read exactly as written"$'\n'"$out"
  pass "fm-logbook-compose keeps a hold reason's own parentheses out of the truncation"
}

test_compose_memoizes_each_projects_remote_once() {
  local home out log shim
  home="$TMP_ROOT/compose-remote-memo"; mkdir -p "$home/data" "$home/state" "$home/projects"
  # Two projects whose names are SUFFIX-related ("app" is the tail of "myapp"), each
  # carrying two cards, plus a remote-less project cached as an EMPTY answer. The remote
  # lookup is the composer's only git call, so it is memoized per PROJECT - in a plain
  # string, not an associative array, so this composes on bash 3.2 as well as 4+
  # (bin/fm-classify-lib.sh's stance; a "declare -A" aborts the whole script there under
  # "set -e" and takes the board down with it). A string cache has two ways to go wrong
  # an associative array does not: matching a name that merely ENDS another, and missing
  # a legitimately EMPTY entry so its git call re-runs forever.
  printf '# Registry\n\n- app [no-mistakes] - One (added 2026-07-01)\n- myapp [no-mistakes] - Two (added 2026-07-01)\n- solo [local-only] - No remote (added 2026-07-01)\n' > "$home/data/projects.md"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] app-one-k1 - First in app https://github.com/acme/app/pull/1 (repo: app) (kind: ship) (hold: review-ready) (hold-kind: captain)
- [ ] app-two-k2 - Second in app https://github.com/acme/app/pull/2 (repo: app) (kind: ship) (hold: review-ready) (hold-kind: captain)
- [ ] myapp-one-k3 - First in myapp https://github.com/acme/myapp/pull/3 (repo: myapp) (kind: ship) (hold: review-ready) (hold-kind: captain)
- [ ] myapp-two-k4 - Second in myapp https://github.com/acme/myapp/pull/4 (repo: myapp) (kind: ship) (hold: review-ready) (hold-kind: captain)
- [ ] crossed-k5 - A myapp PR filed under app https://github.com/acme/myapp/pull/5 (repo: app) (kind: ship) (hold: review-ready) (hold-kind: captain)
- [ ] solo-one-k6 - First in solo https://github.com/acme/solo/pull/6 (repo: solo) (kind: ship) (hold: review-ready) (hold-kind: captain)
- [ ] solo-two-k7 - Second in solo https://github.com/acme/solo/pull/7 (repo: solo) (kind: ship) (hold: review-ready) (hold-kind: captain)
## Queued
## Done
EOF
  git init -q "$home/projects/app"
  git -C "$home/projects/app" remote add origin https://github.com/acme/app.git
  git init -q "$home/projects/myapp"
  git -C "$home/projects/myapp" remote add origin https://github.com/acme/myapp.git
  git init -q "$home/projects/solo"
  # Count the composer's real git calls by shimming git ahead of it on PATH.
  log="$home/git-calls.log"; shim="$home/shim"; mkdir -p "$shim"
  { printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >> %s\n' "$(printf '%q' "$log")"
    printf 'exec %s "$@"\n' "$(printf '%q' "$(command -v git)")"
  } > "$shim/git"
  chmod +x "$shim/git"
  : > "$log"
  out=$(PATH="$shim:$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # Seven cards, three projects: one lookup each, including solo's empty answer.
  [ "$(wc -l < "$log")" -eq 3 ] \
    || fail "each project's remote must be looked up exactly once, got:"$'\n'"$(cat "$log")"
  # The suffix-related names must not read each other's cache record.
  printf '%s' "$out" | jq -e '[ .items[] | select(.id=="app-one-k1" or .id=="app-two-k2"
        or .id=="myapp-one-k3" or .id=="myapp-two-k4")
      | (.kind=="action") and ([.options[].value] | index("merge") != null) ] | all' >/dev/null \
    || fail "a cached remote must still verify its own project's PRs"$'\n'"$out"
  printf '%s' "$out" | jq -e '.items[] | select(.id=="crossed-k5")
      | (.kind=="decision") and ([.options[].value] | index("merge") == null)' >/dev/null \
    || fail "a resolved remote that disagrees is a proven mismatch: no Merge"$'\n'"$out"
  # The empty (no-origin) entry memoizes as a HIT, and still falls back to the marker.
  printf '%s' "$out" | jq -e '[ .items[] | select(.id=="solo-one-k6" or .id=="solo-two-k7")
      | (.kind=="action") and ([.options[].value] | index("merge") != null) ] | all' >/dev/null \
    || fail "a project with no remote must fall back to the marker on every card"$'\n'"$out"
  pass "fm-logbook-compose memoizes each project's remote once, portably"
}

test_compose_action_body_carries_a_clickable_pr_link() {
  local home out
  home="$TMP_ROOT/compose-pr-link"; write_fleet_fixture "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # A standing captain rule: a card referencing a PR carries the full url as a
  # markdown link in the BODY. The board renders "[text](http...)" and nothing else -
  # not source.pr, not a bare url - so a plain "PR: <url>" line was dead text.
  printf '%s' "$out" | jq -e '.items[] | select(.id=="ship-pr-a1")
      | (.body | test("\\[alpha #42\\]\\(https://github\\.com/acme/alpha/pull/42\\)"))
      and (.body | test("Ready for your review"))' >/dev/null \
    || fail "a ready-PR card must carry the PR as a markdown link in the body"$'\n'"$out"
  pass "fm-logbook-compose renders a ready PR as a clickable markdown link in the card body"
}

test_compose_runaway_body_never_truncates_the_pr_link() {
  local home out reason repo url link
  home="$TMP_ROOT/compose-body-clip"; mkdir -p "$home/data" "$home/state"
  printf '# Registry\n\n- alpha [no-mistakes] - First project (added 2026-07-01)\n' > "$home/data/projects.md"
  # Both halves at their worst: a runaway hold reason, and the longest link the url
  # bound (400 bytes) still admits - the link's label is drawn from the url, so it
  # roughly doubles it. A fixed body margin cannot cover this; the room has to be
  # measured from the rendered link.
  repo=$(awk 'BEGIN { while (i++ < 340) printf "r" }')
  url="https://github.com/acme/$repo/pull/42"
  link="[$repo #42]($url)"
  reason=$(awk 'BEGIN { while (i++ < 3000) printf "reason words here " }')
  { printf '# Backlog\n\n## In flight\n'
    printf -- '- [ ] huge-j1 - Big one %s (repo: alpha) (kind: ship) (hold: %s) (hold-kind: captain)\n' "$url" "$reason"
    printf '## Queued\n## Done\n'
  } > "$home/data/backlog.md"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" LOGBOOK_ENABLE=1 \
    "$ROOT/bin/fm-logbook-compose.sh")
  # The link is the higher-value half: a link clipped mid-way strands "[...](https://"
  # as dead text, the exact failure rendering it as a link exists to avoid. So the BODY
  # yields the room, and the link always survives whole.
  printf '%s' "$out" | jq -e --arg link "$link" '.items[] | select(.id=="huge-j1")
      | (.body | endswith($link)) and (.body | length <= 19000)
      and (.body | startswith("reason words here"))' >/dev/null \
    || fail "a runaway body must be clipped to fit the PR link whole, not truncate it"$'\n'"tail: $(printf '%s' "$out" | jq -r '.items[] | select(.id=="huge-j1") | .body[-60:]')"
  pass "fm-logbook-compose clips a runaway body to keep the PR link intact"
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
test_compose_declares_ordered_subprojects
test_compose_tags_item_by_base_branch
test_compose_no_declaration_is_backward_compatible
test_compose_skips_malformed_subproject_lines
test_project_mode_unaffected_by_subproject_lines
test_compose_captain_hold_survives_teardown
test_compose_pr_is_read_only_from_the_structured_position
test_compose_link_run_holds_reports_as_well_as_prs
test_compose_keeps_a_url_the_captain_wrote_in_the_title
test_compose_merge_needs_a_repo_matched_pr
test_compose_merge_needs_a_repo_marker_to_verify_against
test_compose_merge_survives_the_documented_combined_repo_marker
test_compose_merge_follows_the_clone_to_its_real_repo
test_compose_merge_falls_back_when_no_remote_resolves
test_compose_never_writes_to_a_project_clone
test_compose_non_captain_hold_with_a_pr_is_not_a_merge
test_compose_blocked_by_is_not_a_merge
test_compose_blocked_by_gate_clears_when_the_blocker_lands
test_compose_newest_pr_wins_a_superseded_link_run
test_compose_remote_lookup_cannot_escape_a_non_repo_project_dir
test_compose_title_drops_the_marker_tail_without_a_repo
test_compose_captain_hold_without_pr_is_a_decision
test_compose_queued_captain_hold_is_carded
test_compose_board_is_not_a_backlog_mirror
test_compose_in_flight_without_crew_is_carded
test_compose_live_crew_enriches_the_backlog_item
test_compose_live_crew_missing_from_backlog_is_carded
test_compose_done_drops_even_with_a_lingering_meta
test_compose_expired_hold_gate_is_not_a_hold
test_compose_hold_reason_survives_the_captains_own_parentheses
test_compose_memoizes_each_projects_remote_once
test_compose_action_body_carries_a_clickable_pr_link
test_compose_runaway_body_never_truncates_the_pr_link
test_refresh_hard_noop_when_disabled
test_refresh_dry_run_records_sync
test_refresh_live_posts_sync
test_bootstrap_opt_in_surfaces_link_and_autosyncs
test_bootstrap_unreachable_omits_link_and_autosync
test_xmode_and_logbook_cadences_coexist
test_logbook_off_leaves_supervision_block_inert
