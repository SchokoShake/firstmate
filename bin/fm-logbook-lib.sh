#!/usr/bin/env bash
# Shared config resolution and the POST helper for the logbook attention-board
# client (fm-logbook-up.sh, fm-logbook-push.sh, fm-logbook-sync.sh, and
# fm-logbook-resolve.sh). logbook is a local, loopback-only "what needs you" board
# that firstmate FEEDS; this is the mirror of fm-x-lib.sh with the public relay
# swapped for a 127.0.0.1 tool server. It ships for every user but is inert unless
# opted in via config/logbook.env with a truthy LOGBOOK_ENABLE (section 15).
#
# This file is sourced, never executed. It defines:
#   logbook_env_get <key> <file>  - read one KEY=VALUE from a .env-style file
#   logbook_load_config           - resolve LOGBOOK_ENABLE, LOGBOOK_URL,
#                                   LOGBOOK_TOKEN, LOGBOOK_TOOL_DIR, LOGBOOK_PORT,
#                                   and LOGBOOK_DRY (an explicit environment value
#                                   wins over config/logbook.env)
#   logbook_enabled               - succeed when LOGBOOK_ENABLE is truthy
#   logbook_valid_id <id>         - validate an item id as the tool's safe slug
#                                   (starts alphanumeric, then [A-Za-z0-9._:-],
#                                   <=200 chars, no "..")
#   logbook_auth_header_file      - write the bearer header to a 0600 temp file
#   logbook_post_json <api-path> <json-file|-> [outbox-name] - bounded curl POST
#                                   to $LOGBOOK_URL<api-path>; under LOGBOOK_DRY it
#                                   records the would-be body to
#                                   state/logbook-outbox/<name>.json and skips the
#                                   network AND the token entirely (mirrors
#                                   FMX_DRY_RUN)
# Callers must have FM_HOME set before calling logbook_load_config.

LOGBOOK_DEFAULT_URL="http://127.0.0.1:8137"
LOGBOOK_DEFAULT_PORT="8137"

# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset".
logbook_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}   # strip leading whitespace
  val=${val%"${val##*[![:space:]]}"}   # strip trailing whitespace (incl. CR)
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

# Extract the explicit port from a URL (scheme://host[:port][/path]); print nothing
# (and succeed) when the URL carries no explicit numeric port. POSIX parameter
# expansion only, so it is set -eu/set -u safe and needs no external tools.
logbook_url_port() {
  local url=${1-} rest hostport port
  rest=${url#*://}       # strip scheme://
  hostport=${rest%%/*}   # strip any /path
  case "$hostport" in
    \[*\]) port= ;;                    # bracketed IPv6 literal, no port
    \[*\]:*) port=${hostport##*:} ;;   # [ipv6]:port
    *:*) port=${hostport##*:} ;;       # host:port
    *) port= ;;
  esac
  case "$port" in
    ''|*[!0-9]*) return 0 ;;           # no port or non-numeric: print nothing
  esac
  printf '%s' "$port"
}

# Resolve the logbook settings into LOGBOOK_ENABLE, LOGBOOK_URL, LOGBOOK_TOKEN,
# LOGBOOK_TOOL_DIR, LOGBOOK_PORT, and LOGBOOK_DRY. An explicit environment variable
# (even when empty) always wins over config/logbook.env. The board URL defaults to
# the loopback address and the tool dir to this home's projects/logbook clone; the
# port, when not set explicitly, is derived from the resolved LOGBOOK_URL (falling
# back to 8137 only when the URL carries no explicit port) so a lone URL override
# cannot mismatch the server bind port and the client URL. All are resolved at
# runtime; LOGBOOK_DRY is "1" when LOGBOOK_DRY_RUN is truthy (anything other than
# unset/empty/0/false/no/off) and "" otherwise.
logbook_load_config() {
  local config_file dry
  config_file="${LOGBOOK_ENV_FILE:-${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/logbook.env}"

  if [ -n "${LOGBOOK_ENABLE+x}" ]; then
    LOGBOOK_ENABLE=${LOGBOOK_ENABLE-}
  else
    LOGBOOK_ENABLE=$(logbook_env_get LOGBOOK_ENABLE "$config_file")
  fi

  if [ -n "${LOGBOOK_URL+x}" ]; then
    LOGBOOK_URL=${LOGBOOK_URL-}
  else
    LOGBOOK_URL=$(logbook_env_get LOGBOOK_URL "$config_file")
  fi
  [ -n "$LOGBOOK_URL" ] || LOGBOOK_URL="$LOGBOOK_DEFAULT_URL"
  LOGBOOK_URL=${LOGBOOK_URL%/}

  if [ -n "${LOGBOOK_TOKEN+x}" ]; then
    LOGBOOK_TOKEN=${LOGBOOK_TOKEN-}
  else
    LOGBOOK_TOKEN=$(logbook_env_get LOGBOOK_TOKEN "$config_file")
  fi

  if [ -n "${LOGBOOK_TOOL_DIR+x}" ]; then
    LOGBOOK_TOOL_DIR=${LOGBOOK_TOOL_DIR-}
  else
    LOGBOOK_TOOL_DIR=$(logbook_env_get LOGBOOK_TOOL_DIR "$config_file")
  fi
  [ -n "$LOGBOOK_TOOL_DIR" ] || LOGBOOK_TOOL_DIR="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}/logbook"

  # An explicit LOGBOOK_PORT (env or file) wins. Otherwise derive the port from the
  # already-resolved LOGBOOK_URL so a lone URL override cannot silently mismatch the
  # server bind port and the client/health-check URL; fall back to 8137 only when
  # the URL carries no explicit port.
  if [ -n "${LOGBOOK_PORT+x}" ]; then
    LOGBOOK_PORT=${LOGBOOK_PORT-}
  else
    LOGBOOK_PORT=$(logbook_env_get LOGBOOK_PORT "$config_file")
  fi
  if [ -z "$LOGBOOK_PORT" ]; then
    LOGBOOK_PORT=$(logbook_url_port "$LOGBOOK_URL")
    [ -n "$LOGBOOK_PORT" ] || LOGBOOK_PORT="$LOGBOOK_DEFAULT_PORT"
  fi

  if [ -n "${LOGBOOK_DRY_RUN+x}" ]; then
    dry=${LOGBOOK_DRY_RUN-}
  else
    dry=$(logbook_env_get LOGBOOK_DRY_RUN "$config_file")
  fi
  case "$(printf '%s' "$dry" | tr '[:upper:]' '[:lower:]')" in
    ''|0|false|no|off) LOGBOOK_DRY="" ;;
    *) LOGBOOK_DRY=1 ;;
  esac

  # Where dry-run previews are recorded; mirrors the client scripts' own STATE.
  LOGBOOK_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

  # Mark the resolved config surface as read: LOGBOOK_TOOL_DIR/LOGBOOK_PORT are
  # consumed by fm-logbook-up.sh and LOGBOOK_ENABLE by logbook_enabled after
  # sourcing, so shellcheck must not flag them as unused within this library.
  : "$LOGBOOK_ENABLE" "$LOGBOOK_TOKEN" "$LOGBOOK_TOOL_DIR" "$LOGBOOK_PORT" \
    "$LOGBOOK_URL" "$LOGBOOK_DRY" "$LOGBOOK_STATE"
}

# Succeed when LOGBOOK_ENABLE is truthy (anything other than unset/empty/0/false/
# no/off). Callers gate opt-in behavior on this after logbook_load_config.
logbook_enabled() {
  case "$(printf '%s' "${LOGBOOK_ENABLE:-}" | tr '[:upper:]' '[:lower:]')" in
    ''|0|false|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

# Validate an item id as the tool's safe slug before it is used in a path or body:
# it must start alphanumeric, contain only [A-Za-z0-9._:-] thereafter, be at most
# 200 characters, and never contain "..". This is the exact rule the tool enforces.
logbook_valid_id() {
  local id=${1-}
  [ -n "$id" ] || return 1
  [ "${#id}" -le 200 ] || return 1
  case "$id" in
    [!A-Za-z0-9]*) return 1 ;;
    *..*) return 1 ;;
    *[!A-Za-z0-9._:-]*) return 1 ;;
  esac
  return 0
}

# Write the bearer auth header to a private 0600 temp file and print its path, so
# the token never appears in curl's argv (which is world-readable via ps). Returns
# non-zero if the token contains a newline or the temp file cannot be created.
logbook_auth_header_file() {
  local file
  case "$LOGBOOK_TOKEN" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-logbook-auth.XXXXXX") || return 1
  chmod 600 "$file" 2>/dev/null || { rm -f "$file"; return 1; }
  printf 'Authorization: Bearer %s\n' "$LOGBOOK_TOKEN" > "$file" || { rm -f "$file"; return 1; }
  printf '%s\n' "$file"
}

# logbook_post_json <api-path> <json-file|-> [outbox-name]
# POST the JSON in <json-file> (or stdin when "-") to $LOGBOOK_URL<api-path> with
# the bearer token. Under LOGBOOK_DRY it records the would-be body to
# state/logbook-outbox/<outbox-name>.json and skips the network AND the token
# entirely (mirrors FMX_DRY_RUN); <outbox-name> defaults to the last path segment.
# The body is streamed from a file, never inlined into an argument, so composed
# item text (title/body from fleet internals) can never break out of a shell word.
# On a live post it prints the HTTP status code and returns 0 for a 2xx, non-zero
# otherwise (with a stderr diagnostic). Runs in a subshell so its EXIT trap and
# temp files never leak into the caller.
logbook_post_json() (
  local path=$1 src=$2 outbox_name=${3:-} body_file tmp_body="" auth_header_file="" code rc outbox_dir outbox_file
  command -v jq >/dev/null 2>&1 || { echo "logbook: jq not found" >&2; return 1; }

  # Resolve the body source into a real file (slurp stdin when "-").
  if [ "$src" = "-" ]; then
    tmp_body=$(mktemp "${TMPDIR:-/tmp}/fm-logbook-body.XXXXXX") || { echo "logbook: cannot create body temp file" >&2; return 1; }
    body_file=$tmp_body
    trap 'rm -f "$tmp_body" "$auth_header_file" 2>/dev/null || true' EXIT
    cat > "$body_file" || { echo "logbook: cannot read body from stdin" >&2; return 1; }
  else
    body_file=$src
    trap 'rm -f "$tmp_body" "$auth_header_file" 2>/dev/null || true' EXIT
  fi
  [ -r "$body_file" ] || { echo "logbook: body not readable: $body_file" >&2; return 2; }

  # Default the outbox record name to the last path segment (items, sync, ...).
  if [ -z "$outbox_name" ]; then
    outbox_name=${path##*/}
    [ -n "$outbox_name" ] || outbox_name=post
  fi
  # Guard the outbox filename against traversal (resolve passes item ids here).
  case "$outbox_name" in
    ''|*/*|*..*) echo "logbook: unsafe outbox name: $outbox_name" >&2; return 2 ;;
  esac

  # Preview / dry-run: record the would-be body and stop, without auth or network.
  if [ -n "$LOGBOOK_DRY" ]; then
    outbox_dir="$LOGBOOK_STATE/logbook-outbox"
    outbox_file="$outbox_dir/$outbox_name.json"
    mkdir -p "$outbox_dir" 2>/dev/null || { echo "logbook: cannot create dry-run outbox: $outbox_dir" >&2; return 1; }
    if ! jq -c '.' "$body_file" > "$outbox_file" 2>/dev/null; then
      rm -f "$outbox_file"
      echo "logbook: cannot record dry-run outbox: $outbox_file" >&2
      return 1
    fi
    printf 'logbook: DRY RUN - would POST to %s%s (recorded: state/logbook-outbox/%s.json)\n' \
      "$LOGBOOK_URL" "$path" "$outbox_name" >&2
    return 0
  fi

  # Live post: needs curl and a token.
  command -v curl >/dev/null 2>&1 || { echo "logbook: curl not found" >&2; return 1; }
  [ -n "$LOGBOOK_TOKEN" ] || { echo "logbook: no LOGBOOK_TOKEN configured for a live post" >&2; return 1; }
  auth_header_file=$(logbook_auth_header_file) || { echo "logbook: invalid LOGBOOK_TOKEN" >&2; return 3; }

  rc=0
  code=$(curl -m 10 -s -o /dev/null -w '%{http_code}' \
    -X POST \
    -H "@$auth_header_file" \
    -H 'Content-Type: application/json' \
    --data-binary "@$body_file" \
    "$LOGBOOK_URL$path" 2>/dev/null) || rc=$?
  if [ "$rc" != 0 ]; then
    echo "logbook: request to the board failed" >&2
    return 4
  fi
  case "$code" in
    2[0-9][0-9]) printf '%s\n' "$code"; return 0 ;;
    *) echo "logbook: board returned HTTP $code" >&2; return 1 ;;
  esac
)
