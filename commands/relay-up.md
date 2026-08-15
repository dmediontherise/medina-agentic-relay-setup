---
description: "Bring up the agentic relay (agy executor + agy scout + agy mutator + Opus validator panes)"
---

Start the multi-agent relay for the current workspace.

Four agents in one psmux session: **executor** (agy) implements, **scout** (agy) gathers
evidence, **mutator** (agy) runs mutation testing in parallel on a frozen snapshot, and
**validator** (Opus) grades. Only the validator costs Claude quota.

To scaffold a brand-new project instead of using the current one, use `/relay-new`.

1. Run:
   ```
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" up -Workspace "<current workspace path>"
   ```
   Add `-Safe` if the user asked for gated approvals instead of unattended agents.

2. Report any preflight warning the script prints verbatim. A missing `agy` or `claude`
   binary means that pane will not start at all.

3. **Read the exit code, not the last line.** `up` now proves each agent answers before
   it reports success:
   - exit `0` and `Relay up - all four agents answered` — the relay is genuinely usable.
   - exit `3` and `RELAY IS NOT HEALTHY` — it lists which agent failed and why. Do not
     dispatch work. Fix it, then re-check with `health` (step 4).

   Never treat the panes existing as proof the agents work. Do not go looking for
   `READY` in a capture yourself — stale `READY` text sits in the scrollback of a pane
   that died hours ago, which is exactly how a dead scout went unnoticed for six task
   cycles on 2026-08-10.

4. Check health any time you are unsure — it is cheap and it is the only check that
   distinguishes a working agent from a wedged one:
   ```
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" health
   ```
   It sends each agy pane a liveness probe (free) and passively inspects the validator.
   Add `-Deep` to probe the validator too — that one costs Claude quota, so use it when
   you suspect the validator specifically, not routinely. Exit `1` means something is
   unhealthy; the output names the agent and the fault.

5. If an agent has faulted, restart **that pane only** — it keeps the other two agents'
   conversation context, which a full `down`/`up` throws away:
   ```
   powershell -NoProfile -File "$env:USERPROFILE\.claude\relay\relay.ps1" restart -Agent scout
   ```
   `-Agent all` restarts all four. `restart` re-verifies liveness and exits non-zero if
   the agent is still broken.

6. Tell the user they can watch it live with `psmux attach -t relay` (Ctrl+B d detaches),
   and that `/relay-auto` will run the whole queue unattended once tasks are written.

## The failure this relay actually has

The scout is the pane that breaks, and it breaks silently. Root-caused 2026-08-10:

agy's OAuth access token refreshes into a state the server rejects, after which every
request returns `401 UNAUTHENTICATED` — 1030 consecutive failures were logged before the
pane was killed. It **never recovers on its own**, and afterwards the pane drops back to a
normal-looking idle prompt showing `? for shortcuts`. The trigger is a long-lived process
that has also been idle a long time: the wedged pane had ~12.5h uptime and had let its
token sit expired for 3.5h. The scout hits this and the executor mostly does not, because
the scout only works during one step of each cycle and therefore idles the longest.

Practical consequences:

- **Long-running relays should be restarted, not trusted.** If `status` reports the agy
  panes have been up more than ~8h, `restart -Agent all` is cheap insurance.
- **A missing evidence file is a broken scout until proven otherwise.** It is never a
  reason to proceed to the validator without evidence.
- If the same fault recurs immediately after a restart, the credentials themselves are
  the problem — have the user re-authenticate agy — rather than something the relay
  can fix by restarting again.

### The second way it breaks: the process just exits

Added 2026-08-12. Panes launch with `-NoExit` so a crash stays inspectable, which means an
agent that dies leaves a **bare PowerShell prompt**. That matches no fault pattern, shows
no busy hint, and prints nothing alarming — it is invisible to every screen-based check.
psmux is no help either: `#{pane_current_command}` reports `powershell` for every relay
pane whether the agent is alive or not.

`health` now walks each pane's process tree for the agent's own executable (`agy.exe`, or
`claude.exe` for the validator) and reports `CRASHED` when it is gone. If you are ever
tempted to diagnose a quiet pane from a capture, that is the check that actually answers
it — a crashed pane and an idle one look identical on screen and completely different
here.

Autopilot runs the same check every 30s during a wait and restarts the pane itself.

You remain the orchestrator in this session. You do not implement relay tasks yourself.
