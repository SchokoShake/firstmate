#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude) and `›` (codex) are a genuine empty
#      agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
#
# The invisible-Unicode-space contract, task fm-send-submit-verify:
#   5. A composer padded with an INVISIBLE Unicode space (claude 2.1.228 draws its
#      empty composer as `❯` + U+00A0, verified live 2026-08-12) reads `empty`.
#      Bash's [[:space:]] is ASCII-only, so every adapter's own trim left that byte
#      pair behind and an EMPTY composer classified as `pending` - the false
#      "Enter swallowed" bin/fm-send.sh reported on delivered sends, and the false
#      "pending input" the away-mode injector saw on every idle claude pane.
#   6. The fold must not weaken rules 1-4: an invisible space in front of REAL text
#      still reads `pending`, and a bare shell glyph padded with one still reads
#      `unknown`. Only rows that were already visually blank change verdict.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  for plain in '❯' '›'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  # Placeholder with no prompt glyph (grok's bordered empty composer).
  out=$(classify 1 'Type a message...' "$idle")
  [ "$out" = empty ] || fail "the grok idle placeholder should read empty, got '$out'"
  # Placeholder after an agent glyph (post-strip match).
  out=$(classify 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "the idle placeholder after a glyph should read empty, got '$out'"
  # Without the idle regex it is just text -> pending.
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: a known idle placeholder reads empty, before and after glyph stripping"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle")
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive)
  [ "$out" = empty ] || fail "an explicitly insensitive idle placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# --- Invisible Unicode space padding (task fm-send-submit-verify) -----------

# The invisible spaces the fold covers, as literal bytes. NBSP is the one verified
# live (claude 2.1.228); the others pin that the fold is harness-generic rather
# than an NBSP special case, so the next harness to pad with U+202F cannot
# reproduce the incident.
NBSP=$(printf '\302\240')          # U+00A0 no-break space
NNBSP=$(printf '\342\200\257')     # U+202F narrow no-break space
ZWSP=$(printf '\342\200\213')      # U+200B zero width space
IDSP=$(printf '\343\200\200')      # U+3000 ideographic space

test_normalize_spaces_folds_invisible_unicode_spaces() {
  local out
  out=$(fm_composer_normalize_spaces "a${NBSP}b")
  [ "$out" = 'a b' ] || fail "U+00A0 was not folded to an ASCII space, got '$out'"
  out=$(fm_composer_normalize_spaces "${NNBSP}${ZWSP}${IDSP}")
  [ "$out" = '   ' ] || fail "U+202F/U+200B/U+3000 were not all folded, got '$out'"
  # Idempotent: an adapter that already normalized may call it again.
  out=$(fm_composer_normalize_spaces "$(fm_composer_normalize_spaces "x${NBSP}y")")
  [ "$out" = 'x y' ] || fail "the fold is not idempotent, got '$out'"
  # Real text is untouched, including the agent glyphs and box borders.
  out=$(fm_composer_normalize_spaces '❯ │ fix findings 1 and 3 │')
  [ "$out" = '❯ │ fix findings 1 and 3 │' ] || fail "the fold altered real content, got '$out'"
  pass "fm_composer_normalize_spaces: folds invisible Unicode spaces, leaves real content alone"
}

test_nbsp_padded_empty_composer_is_empty() {
  local out
  # The exact live claude 2.1.228 empty composer: `❯` + U+00A0, no border.
  out=$(classify 0 "❯$NBSP" '' insensitive "❯$NBSP")
  [ "$out" = empty ] || fail "the claude '❯'+U+00A0 empty composer must read empty, got '$out'"
  # The same shape for codex's glyph, and inside a bordered box.
  out=$(classify 0 "›$NBSP" '' insensitive "›$NBSP")
  [ "$out" = empty ] || fail "'›'+U+00A0 must read empty, got '$out'"
  out=$(classify 1 "❯$NNBSP")
  [ "$out" = empty ] || fail "a bordered '❯'+U+202F composer must read empty, got '$out'"
  # A row holding nothing but invisible space is as blank as an all-ASCII one.
  out=$(classify 1 "$NBSP")
  [ "$out" = empty ] || fail "an invisible-space-only composer must read empty, got '$out'"
  pass "fm_composer_classify_content: an invisible-space-padded empty composer reads empty"
}

test_invisible_space_does_not_weaken_pending_or_unknown() {
  local out
  # Real typed text behind the padding is still a swallowed Enter - stay loud.
  out=$(classify 0 "❯${NBSP}stranded steer that never submitted" '' insensitive "❯${NBSP}stranded steer that never submitted")
  [ "$out" = pending ] || fail "real text behind U+00A0 padding must stay pending, got '$out'"
  out=$(classify 1 "${NBSP}deploy staging now$NBSP")
  [ "$out" = pending ] || fail "real text wrapped in invisible space must stay pending, got '$out'"
  # The dead-shell safety rule is unchanged: a BARE shell glyph is never empty.
  for out in '>' '$' '%' '#'; do
    [ "$(classify 0 "$out$NBSP" '' insensitive "$out$NBSP")" = unknown ] \
      || fail "bare shell glyph '$out' padded with U+00A0 must still read unknown"
  done
  out=$(classify 0 ">${NBSP}make build" '' insensitive ">${NBSP}make build")
  [ "$out" = pending ] || fail "a padded bare shell prompt carrying a command must stay pending, got '$out'"
  pass "fm_composer_classify_content: the space fold weakens neither the pending nor the dead-shell rule"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
test_normalize_spaces_folds_invisible_unicode_spaces
test_nbsp_padded_empty_composer_is_empty
test_invisible_space_does_not_weaken_pending_or_unknown
