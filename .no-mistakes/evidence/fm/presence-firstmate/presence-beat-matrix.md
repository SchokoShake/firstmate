# Crew presence beat, as observed by driving the real generated wiring

Every row below was produced by running the real `bin/fm-spawn.sh` into an isolated
firstmate home, then firing that adapter's own turn-boundary artifact with a recording
stand-in on PATH in place of bridge-axi's `agent-presence` CLI. "Board saw" is the
literal argv the artifact invoked.

| Adapter | Artifact driven | Board saw | Matches SKILL.md row |
|---|---|---|---|
| claude crewmate | `.claude/settings.local.json` hooks through `sh` | `beat --state working`, `beat --state waiting` (Stop), `beat --state waiting` (StopFailure), `end` (SessionEnd) | yes, all four states |
| claude scout | same, after a `--scout` spawn | `beat --state working`, `beat --state waiting`, `end` | yes, scouts are covered |
| codex crewmate | notify program recovered from the launch command fm-spawn sent to the pane | `beat --state waiting` only | yes, turn-end only |
| opencode crewmate | generated plugin in a plain Node host | `beat --state working`, `beat --state waiting`, latched session only | yes, never `end` |
| pi crewmate | generated extension in a plain Node host | `beat --state working` (agent_start), `beat --state waiting` (confirmed settle); nothing on turn_end or a continuing settle | yes, semantic edges only |
| grok crewmate | global `~/.grok/hooks/fm-turn-end.sh` with a real workspace root | `beat --state waiting`, run in the task worktree | yes, turn-end only, cd'd to the authorised worktree |
| kimi crewmate | global `~/.kimi-code/fm-turn-end.sh` with a real Stop payload | `beat --state waiting`, run in the task worktree | yes, turn-end only, cd'd to the authorised worktree |
| cursor crewmate | real spawn, every generated artifact inspected | nothing: no hook, no beat, only a pull-source sidecar | yes, NOT COVERED |
| muse crewmate | real spawn, every generated artifact inspected | nothing: no hook, no beat, only a pull-source sidecar | yes, NONE |
| secondmate | real seeded secondmate spawn | nothing: no hook settings, no plugin, nothing in the launch command | yes, crewmates and scouts only |

## Boundaries driven adversarially

| Probe | Result |
|---|---|
| bridge-axi not installed (hermetic PATH with no resolvable `agent-presence`) | every hook exit 0, stdout empty, firstmate's own busy record unchanged |
| `agent-presence` installed but exiting 3 and noisy on stdout and stderr | every hook exit 0, stdout empty, busy record unchanged; the CLI was still invoked 4 times |
| grok hook fired for a workspace with a forged, unregistered token | exit 0, silent, no beat at all |
| kimi hook fired for a workspace with no firstmate token | exit 0, silent, no beat at all |
| a foreign opencode session going idle | no `waiting` beat for this worker |
| pi `turn_end` (an inner turn boundary, not a run boundary) | no beat, so a settled worker is never flipped back to working |
| a raw `__PRESENCEWAITING__` placeholder surviving into any artifact | zero occurrences across every spawn |
| a user-level `~/.claude/settings.json` written by any spawn | zero, as the captain decision requires |
| feature removed (mutation) | all three suites fail; they observe the beat, not the source text |
