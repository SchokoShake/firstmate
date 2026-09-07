# Evidence: each task's parent branch in the fleet snapshot

Two additive fields on every `fm-fleet-snapshot.v1` task row, as observed in the transcripts here.

| Field | Written by | Source | Default when unknown |
|---|---|---|---|
| `base` | `bin/fm-spawn.sh --base <branch>` | the branch the brief tells the crew to branch from | `""` |
| `pr_base` | `bin/fm-pr-check.sh` | `gh pr view --json baseRefName`; refreshed on every rerun; omitted on GitLab | `""` |

## Files

- `e2e-branch-parent-transcript.txt` - operator-level walkthrough produced by `e2e-branch-parent.sh`, run from the worktree root against an isolated home with a real git worktree, a fake tmux and a fake forge CLI.
  Steps 1-8 spawn with and without `--base`, record a GitHub PR, restack it, hit the unreadable-base and GitLab paths, and read the snapshot after each step.
  Steps 9-11 show the refusals (bad branch name, newline, secondmate, relaunch) and batch forwarding.
  Step 12 runs the base commit's `bin/fm-fleet-snapshot.sh` on the same home: neither key exists there, and the new contract test fails against it.
- `fixture-guards-transcript.txt` - produced by `fixture-guards.sh`: the untouched fixture passes, and four mutated copies of `tests/fixtures/snapshot-branch-parent/cases.json` each make `tests/fm-snapshot-branch-parent-contract.test.sh` fail with the message naming the case.

## What the snapshot rows looked like after the walkthrough

```
{"id":"tree-scout-d4","base":"feature/stack-1","pr_base":"","pr":null}
{"id":"tree-ship-a1","base":"release/2026.09","pr_base":"main","pr":"https://github.com/o/r/pull/11"}
{"id":"tree-ship-b2","base":"","pr_base":"","pr":"https://github.com/o/r/pull/12"}
{"id":"tree-ship-c3","base":"main","pr_base":"","pr":"https://gitlab.com/g/p/-/merge_requests/4"}
```

`tree-ship-a1` was spawned with `--base release/2026.09`, its PR first recorded with base `release/2026.09`, then re-recorded after a restack onto `main`.
Both values are carried separately, so a consumer can prefer `pr_base` and still see the declared base.
