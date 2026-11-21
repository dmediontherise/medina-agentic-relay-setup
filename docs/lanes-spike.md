# Lanes spike: headless agent turns (Task 0)

Date: 2026-11-21 · WSL2 · throwaway git repo · prompt: "Write the single word LANEOK into
the file ok.txt in the current directory, then reply DONE."

| Command | Exit | Wall time | ok.txt | Notes |
|---|---|---|---|---|
| `agy -p … --model gemini-3.8-flash-medium --dangerously-skip-permissions --add-dir <ws>` | 0 | 10s | LANEOK | no trust or permission prompt |
| same, plus `--sandbox` | 0 | 8s | LANEOK | sandbox still writes inside its own cwd |
| `opencode run -m opencode/big-pickle …` | 1 | 2s | — | `Error: This API key has expired` (stored credential, see below) |
| same, with `XDG_DATA_HOME` pointed at an empty dir | 0 | 17s | LANEOK | free model, no login, no permission prompt in `run` mode |
| `claude -p --model claude-sonnet-5-5 --permission-mode acceptEdits …` | 0 | 7s | LANEOK | |

## Decision

Proceed with the plan as written. All three providers can complete a headless,
file-writing turn. No flag changes are needed in `lane_cmdline`, and `--sandbox` stays on
for the prebrief role.

## Environment finding (not a design issue)

`~/.local/share/opencode/auth.json` (dated 2026-09-07) holds an "OpenCode api"
credential that has expired. While it is present, every `opencode run` fails in about 2s,
**including the opencode fallback in today's `relay.sh`**. The free Zen models need no
credential, so removing that one entry (`opencode auth logout`, choosing OpenCode) restores
them. That is the owner's call. Until then, lanes classifies the error as a failed turn (it
does not match the quota or auth patterns), retries once, and reports the lane `failed`.
