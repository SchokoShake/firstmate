#!/usr/bin/env bash
# tests/fm-pr-slug-contract.test.sh - pins bin/fm-merge-policy-lib.sh's
# fm_merge_slug and fm_merge_same_part against tests/fixtures/pr-slug/, the
# shared statement of the PR-slug contract. docs/architecture.md ("Cross-repo
# contracts are stated as fixtures") owns why that contract lives in a fixture.
#
# Every declared divergence is asserted to STILL diverge from the peer's
# recorded value, so narrowing this side back to the connector's parse fails
# here rather than silently reopening a merge bypass.
#
# Pure shell, no jq: this guards a permission path, so it must run wherever the
# suite runs and never gate-skip on an optional binary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-merge-policy-lib.sh disable=SC1091
. "$ROOT/bin/fm-merge-policy-lib.sh"

CASES="$ROOT/tests/fixtures/pr-slug/cases.tsv"
SAME="$ROOT/tests/fixtures/pr-slug/same-part.tsv"
[ -f "$CASES" ] || fail "missing fixture: $CASES"
[ -f "$SAME" ] || fail "missing fixture: $SAME"

# "~" is the fixture's empty string; every other value is literal.
unsentinel() {
  case "$1" in
    '~') printf '%s' '' ;;
    *) printf '%s' "$1" ;;
  esac
}

# --- fm_merge_slug against every case ---------------------------------------

slug_rows=0
slug_url=0
slug_remote=0
slug_diverge=0
while IFS=$'\t' read -r kind input owner repo peer peer_owner peer_repo note; do
  case "$kind" in ''|'#'*) continue ;; esac
  # read always assigns, so a short row shows up as an EMPTY trailing field
  # rather than an unset one. Every fixture row carries a note, so requiring it
  # is what catches a row that lost a column to a stray edit.
  [ -n "$note" ] || fail "fixture row is missing fields or its note: [$kind] [$input]"
  input=$(unsentinel "$input")
  owner=$(unsentinel "$owner")
  repo=$(unsentinel "$repo")
  case "$kind" in
    url) slug_url=$((slug_url + 1)) ;;
    remote) slug_remote=$((slug_remote + 1)) ;;
    *) fail "fixture kind must be url or remote, got \"$kind\"" ;;
  esac
  fm_merge_slug "$input"
  [ "$FM_MERGE_SLUG_OWNER" = "$owner" ] || \
    fail "slug owner for [$input]: want [$owner], got [$FM_MERGE_SLUG_OWNER] ($note)"
  [ "$FM_MERGE_SLUG_REPO" = "$repo" ] || \
    fail "slug repo for [$input]: want [$repo], got [$FM_MERGE_SLUG_REPO] ($note)"
  case "$peer" in
    agree)
      [ "$peer_owner" = '=' ] && [ "$peer_repo" = '=' ] || \
        fail "an \"agree\" row must carry \"=\" in both peer columns: $input"
      ;;
    diverge)
      slug_diverge=$((slug_diverge + 1))
      peer_owner=$(unsentinel "$peer_owner")
      peer_repo=$(unsentinel "$peer_repo")
      # The point of a declared divergence: this side must NOT answer what the
      # connector answers. A row that quietly converged is a fixture that stopped
      # describing anything, so it fails rather than passing vacuously.
      [ "$owner" != "$peer_owner" ] || [ "$repo" != "$peer_repo" ] || \
        fail "declared divergence for [$input] no longer diverges; re-record it as an agreement ($note)"
      ;;
    *) fail "fixture peer must be agree or diverge, got \"$peer\" for [$input]" ;;
  esac
  slug_rows=$((slug_rows + 1))
done < "$CASES"

[ "$slug_rows" -ge 20 ] || fail "the slug fixture went thin: only $slug_rows cases"
[ "$slug_url" -ge 1 ] || fail "the slug fixture covers no url case"
[ "$slug_remote" -ge 1 ] || fail "the slug fixture covers no remote case"
[ "$slug_diverge" -ge 1 ] || fail "the slug fixture declares no divergence; the peer columns have stopped saying anything"
pass "fm_merge_slug matches all $slug_rows fixture cases ($slug_url url, $slug_remote remote, $slug_diverge declared divergences from the logbook connector)"

# --- fm_merge_same_part against every case ----------------------------------

same_rows=0
while IFS=$'\t' read -r a b expect peer note; do
  case "$a" in ''|'#'*) continue ;; esac
  [ -n "$note" ] || fail "same-part row is missing fields or its note: [$a] [$b]"
  a=$(unsentinel "$a")
  b=$(unsentinel "$b")
  if fm_merge_same_part "$a" "$b"; then got=same; else got=differ; fi
  [ "$got" = "$expect" ] || \
    fail "fm_merge_same_part [$a] [$b]: want $expect, got $got ($note)"
  case "$peer" in
    agree|diverge) ;;
    *) fail "same-part peer must be agree or diverge, got \"$peer\"" ;;
  esac
  same_rows=$((same_rows + 1))
done < "$SAME"

[ "$same_rows" -ge 8 ] || fail "the same-part fixture went thin: only $same_rows cases"
pass "fm_merge_same_part matches all $same_rows fixture cases (case-folded equality, and an empty half never matches)"

# --- the two halves compose the way the guard uses them ----------------------
#
# The guard's whole job is "does this PR url name the repo this clone pushes to",
# which is fm_merge_slug on both inputs and fm_merge_same_part on each half. The
# fixture pins the halves; this pins that they still compose - including across
# the forms the connector reads differently, which is where a bypass would open.
matches() {
  local url=$1 origin=$2 u_owner u_repo
  fm_merge_slug "$url"
  u_owner=$FM_MERGE_SLUG_OWNER
  u_repo=$FM_MERGE_SLUG_REPO
  fm_merge_slug "$origin"
  fm_merge_same_part "$u_owner" "$FM_MERGE_SLUG_OWNER" &&
    fm_merge_same_part "$u_repo" "$FM_MERGE_SLUG_REPO"
}

matches https://github.com/acme/guarded/pull/7 https://github.com/acme/guarded.git ||
  fail "the canonical url must trace to its clone's origin"
matches https://github.com/acme/guarded/pull/7/ https://github.com/acme/guarded.git ||
  fail "a trailing-slash url must still trace to its clone's origin"
matches https://github.com/acme/guarded.git/pull/7 https://github.com/acme/guarded.git ||
  fail "a .git url component must still trace to its clone's origin"
matches https://github.com/acme/guarded/pull/7 https://github.com/acme/guarded.git/ ||
  fail "an origin ending .git/ must still be traced to by its PR url"
matches https://github.com/ACME/Guarded/pull/7 https://github.com/acme/guarded.git ||
  fail "a case-only difference between url and origin must still trace"
matches https://github.com/acme/other/pull/7 https://github.com/acme/guarded.git &&
  fail "a different repo must not trace to this clone"
matches https://github.com/other/guarded/pull/7 https://github.com/acme/guarded.git &&
  fail "a different owner must not trace to this clone"
pass "the slug and same-part halves compose into the guard's url-to-origin match, including on the four forms the logbook connector reads differently"

echo "# fm-pr-slug-contract.test.sh: all assertions passed"
