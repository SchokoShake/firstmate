#!/usr/bin/env bash
# Pins the local-skill extension seam: an out-of-tree feature installs its agent
# playbook as an ordinary directory under .agents/skills/ that carries its own
# .gitignore, and firstmate keeps loading it without ever tracking it.
#
# This is a CONTRACT test, not a behavior test - firstmate ships no code for this
# seam, which is the point. It exists because the seam is load-bearing for an
# out-of-tree extension while being invisible in the tree, so a future change that
# broke it (a CI rule requiring every skill to be tracked, a discovery path that
# stopped following .claude/skills, a repo-wide .gitignore that swallowed the
# install root) would otherwise fail silently, at the extension's expense.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-local-skills)

# A skill dir whose own .gitignore is `*` is invisible to git: the pattern matches
# every path in that directory INCLUDING the .gitignore itself, so nothing there is
# ever reported untracked, and no repo-level .gitignore entry naming the extension
# is needed. Verified in a throwaway repo so the check cannot be satisfied by this
# repo's own ignore rules.
test_directory_local_ignore_hides_an_installed_skill() {
  local repo out
  repo="$TMP_ROOT/repo"
  fm_git_init_commit "$repo"
  mkdir -p "$repo/.agents/skills/tracked-skill" "$repo/.agents/skills/installed-skill"
  printf -- '---\nname: tracked-skill\n---\nbody\n' > "$repo/.agents/skills/tracked-skill/SKILL.md"
  git -C "$repo" add -A >/dev/null
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm base >/dev/null

  printf -- '---\nname: installed-skill\n---\nbody\n' > "$repo/.agents/skills/installed-skill/SKILL.md"
  out=$(git -C "$repo" status --porcelain)
  assert_contains "$out" "installed-skill" "an installed skill with no directory ignore should be visible, or the test proves nothing"

  printf '*\n' > "$repo/.agents/skills/installed-skill/.gitignore"
  out=$(git -C "$repo" status --porcelain)
  assert_not_contains "$out" "installed-skill" "a directory-ignored skill must not appear as untracked work"
  out=$(git -C "$repo" status --porcelain --ignored)
  assert_contains "$out" "installed-skill" "a directory-ignored skill must still be reported under --ignored"
  pass "an installed skill carrying its own .gitignore is invisible to git status"
}

# The seam only works because the harness discovery glob is `skills/*/SKILL.md`
# against the .claude/skills symlink - one level deep, so the skill must be a
# DIRECT child of .agents/skills/ and cannot be tucked under an install subdir.
test_installed_skill_is_reachable_through_the_discovery_path() {
  local probe found=0 f
  probe="$ROOT/.agents/skills/fm-local-skills-probe"
  mkdir -p "$probe"
  printf '*\n' > "$probe/.gitignore"
  printf -- '---\nname: fm-local-skills-probe\n---\nbody\n' > "$probe/SKILL.md"
  for f in "$ROOT"/.claude/skills/*/SKILL.md; do
    case "$f" in *fm-local-skills-probe*) found=1 ;; esac
  done
  rm -rf "$probe"
  [ "$found" -eq 1 ] || fail "an installed skill was not reachable through .claude/skills/*/SKILL.md"
  pass "an installed skill is reachable through the one-level harness discovery glob"
}

# The install root must not be swallowed wholesale: an extension needs the skills
# it did NOT install to stay tracked, so the repo may never blanket-ignore
# .agents/skills/ (which would also stop a genuinely new firstmate skill from
# showing up as untracked work).
test_repo_does_not_blanket_ignore_the_skills_root() {
  local tracked
  tracked=$(git -C "$ROOT" ls-files -- .agents/skills | head -1)
  [ -n "$tracked" ] || fail "no tracked skill found under .agents/skills"
  git -C "$ROOT" check-ignore -q .agents/skills/ 2>/dev/null \
    && fail ".agents/skills/ is blanket-ignored; a new firstmate skill would vanish from git status"
  pass "the skills root itself stays tracked and unignored"
}

test_directory_local_ignore_hides_an_installed_skill
test_installed_skill_is_reachable_through_the_discovery_path
test_repo_does_not_blanket_ignore_the_skills_root
