#!/usr/bin/env python3
"""Jev gates for the medina relay: cheap typed decisions in front of expensive or stuck turns.

Called by relay.sh autopilot when RELAY_JEV=1. Every subcommand prints ONE decision word
on stdout (plus detail after a space) and never raises into the relay: on any error it
prints the conservative answer, so a Jev outage degrades to the pre-Jev behaviour.

  verdict  <workspace> <report.md>      -> FAIL | PASS-WITH-CONCERNS | UNKNOWN   (report has no VERDICT: line)
  sweep    <workspace> <mutation.md>... -> KEEP <paths...> | NONE                (before the paid mutation sweep)
  mutation <workspace> <base>           -> MUTATE | SKIP <reason>                (before the mutator)
  blocked  <workspace> <base>           -> ANSWERED <label> | ASK                (executor reported BLOCKED)
  pane     <workspace> <agent> <artifact> <elapsed_s> <progress_age_s> <screen.txt> <wait_id>
                                        -> LOGGED <state>                          (shadow mode: no action)

`pane` is the shadow-mode pane classifier: autopilot samples the screen of the agent it
is waiting on, Jev names the state it looks to be in, and the answer is only logged - the
relay never acts on it. Each wait's real outcome is logged next to it, and
relay/jev-calibration/eval_pane_shadow.py scores the two against each other.

Only `verdict`, `blocked` and `pane` call Jev; `sweep` and `mutation` are deterministic rules that
were safer than Jev on the historical data. Calibration against past runs, and the gate
that was tried and rejected (Jev predicting the validator's verdict - AUC 0.61), are in
relay/jev-calibration.md in the tracked repo. Every decision is appended to
<workspace>/.relay/jev/decisions.jsonl.
"""
import json
import os
import re
import sys
import time
from pathlib import Path

JEV_HOME = Path(os.environ.get("JEV_HOME", Path.home() / "Jev-AI-Skill"))
sys.path.insert(0, str(JEV_HOME))

MODEL = os.environ.get("RELAY_JEV_MODEL", "jev-latest")
# A recovered pass is accepted only above this; on 115 real reports, 0.9 left 1 error in 56.
VERDICT_PASS_CONF = float(os.environ.get("RELAY_JEV_VERDICT_CONF", "0.9"))
DECIDE_CONF = float(os.environ.get("RELAY_JEV_DECIDE_CONF", "0.7"))

ITEM, CTX = 500, 1500

# Mutation is skipped only when EVERY changed file is one of these. HTML, JSON, YAML and
# other markup/config are deliberately absent: html-only slide-deck tasks
# produced 3-6 real survivors each.
DOC_EXT = {".md", ".markdown", ".txt", ".rst", ".adoc", ".png", ".jpg", ".jpeg", ".gif",
           ".svg", ".ico", ".webp", ".pdf"}


# ---------------------------------------------------------------- parsing ---
def read(p):
    try:
        return Path(p).read_text(encoding="utf-8", errors="replace").replace("\r", "")
    except OSError:
        return ""


def clip(s, n):
    s = re.sub(r"[ \t]+", " ", (s or "").strip())
    return s if len(s) <= n else s[: n - 1] + "…"


def section(md, title):
    """Body of the first '## <title>...' section, up to the next '## ' heading."""
    m = re.search(rf"^##\s+{title}[^\n]*\n(.*?)(?=^##\s|\Z)", md, re.S | re.M | re.I)
    return m.group(1).strip() if m else ""


def bus(ws, kind, base):
    return Path(ws) / ".relay" / kind / f"{base}.md"


def record(ws, kind, data):
    try:
        d = Path(ws) / ".relay" / "jev"
        d.mkdir(parents=True, exist_ok=True)
        with open(d / "decisions.jsonl", "a", encoding="utf-8") as f:
            f.write(json.dumps({"t": time.strftime("%Y-%m-%d %H:%M:%S"), "kind": kind, **data}) + "\n")
    except OSError:
        pass


def jev_call(state, questions):
    from jev_mcp import jev
    return jev(MODEL, state, questions)


# -------------------------------------------------------------- verdict ---
VERDICTS = {
    "PASS": "Every requirement met; no defects",
    "PASS-WITH-CONCERNS": "Requirements met, but real non-disqualifying concerns are recorded",
    "FAIL": "At least one requirement is unmet or unproven, or a defect must be fixed; a follow-up is needed",
}


def verdict(ws, report):
    md = read(report)
    if not md.strip():
        return "UNKNOWN", {"reason": "empty report"}
    st = {"report_requirements": clip(section(md, "Requirement-by-requirement") or section(md, "Requirement"), CTX),
          "defects": clip(section(md, "Defects"), 1200), "concerns": clip(section(md, "Concerns"), 800),
          "recommended_next": clip(section(md, "Recommended next"), 600), "opening": clip(md[:1200], 1200)}
    a = jev_call(st, {"v": {"type": "choice", "criteria": VERDICTS,
                            "instructions": "Which verdict did this validator report reach?"}})["answers"]["v"]
    choice, conf = a.get("choice"), a.get("confidence")
    info = {"report": str(report), "choice": choice, "confidence": conf, "probabilities": a.get("probabilities")}
    # Asymmetric on purpose: reading a FAIL costs at most one follow-up cycle, reading a
    # pass wrongly launders unfinished work - so a pass needs high confidence and is
    # never upgraded past PASS-WITH-CONCERNS.
    if choice == "FAIL":
        return "FAIL", info
    if choice in ("PASS", "PASS-WITH-CONCERNS") and conf is not None and float(conf) >= VERDICT_PASS_CONF:
        return "PASS-WITH-CONCERNS", info
    return "UNKNOWN", info


# ---------------------------------------------------------------- sweep ---
def nothing_to_act_on(md):
    """True only for a report that explicitly says there are no survivors on a GREEN baseline."""
    base = section(md, "Baseline")
    if not re.match(r"\s*GREEN\b", base, re.I):
        return False            # RED or missing baseline: the validator should see it
    if re.search(r"\bSURVIVED\b", section(md, "Mutant zero")):
        return False
    srv = section(md, "Survivors")
    if re.search(r"^#{3,}\s", srv, re.M):
        return False            # survivors written as ### subsections
    rows = [l for l in srv.splitlines() if l.strip().startswith("|")
            and not re.match(r"^\s*\|[\s:|-]+\|\s*$", l)]
    if len(rows) > 1:           # a header plus at least one data row
        return False
    text = re.sub(r"\|[^\n]*", "", srv).strip().lower()
    return bool(re.match(r"^(none|zero survivors|no survivors|0 survivors)\b", text))


def sweep(ws, reports):
    keep, why = [], {}
    for r in reports:
        empty = nothing_to_act_on(read(r))
        why[r] = "no survivors on a green baseline" if empty else "has survivors or an unclear/red baseline"
        if not empty:
            keep.append(r)
    return ("KEEP " + " ".join(keep)) if keep else "NONE", {"reports": why}


# ------------------------------------------------------------- mutation ---
def changed_files(result_md):
    files = []
    for line in section(result_md, "Changed").splitlines():
        m = re.match(r"^\s*[-*]\s+`?([\w./\\-]+\.[\w-]+|[\w./\\-]*/[\w./\\-]+)`?", line)
        if m:
            files.append(m.group(1))
    return files


def mutation(ws, base):
    files = changed_files(read(bus(ws, "results", base)))
    if not files:
        return "MUTATE", {"reason": "could not tell what changed - mutating to be safe"}
    exts = {Path(f).suffix.lower() for f in files}
    if exts <= DOC_EXT:
        return "SKIP", {"reason": f"docs/images only ({', '.join(sorted(exts))})", "files": files}
    return "MUTATE", {"reason": "changes beyond docs", "files": files}


# -------------------------------------------------------------- blocked ---
def blocked(ws, base):
    tpath, rpath = bus(ws, "tasks", base), bus(ws, "results", base)
    task_md, result_md = read(tpath), read(rpath)
    if "## Clarification (Jev)" in task_md:
        return "ASK", {"reason": "Jev already answered once for this task and it is still BLOCKED"}
    opts = {}
    for line in section(result_md, "Options").splitlines():
        m = re.match(r"^\s*(?:[-*]|\d+[.)])\s*\**`?([A-Za-z0-9_-]{1,40})`?\**\s*[:—–]\s*(.+)", line)
        if m:
            opts[m.group(1)] = clip(m.group(2), ITEM)
    if not 2 <= len(opts) <= 12:
        return "ASK", {"reason": f"no usable '## Options' list in the result ({len(opts)} parsed)"}
    question = clip(section(result_md, "Question") or section(result_md, "Not done"), ITEM)
    if not question:
        return "ASK", {"reason": "no '## Question' section in the result"}
    rec = re.search(r"(?im)^\s*recommended\s*:\s*`?([A-Za-z0-9_-]+)", result_md)
    from jev_mcp import gate_decide
    d = gate_decide(question, opts,
                    context=clip(section(task_md, "Objective") + "\n" + section(task_md, "Requirements")
                                 + "\nOut of scope: " + section(task_md, "Scope"), CTX),
                    recommended=rec.group(1) if rec and rec.group(1) in opts else "",
                    policy=os.environ.get("RELAY_JEV_POLICY", ""), model=MODEL, min_confidence=DECIDE_CONF)
    d.pop("probabilities", None)
    if not d["proceed"]:
        return "ASK", d
    # Move the result aside first: os.replace overwrites a stale .blocked.md on Windows too,
    # and if it fails nothing has been appended, so the error path leaves the task untouched.
    os.replace(rpath, rpath.with_name(f"{base}.blocked.md"))
    with open(tpath, "a", encoding="utf-8") as f:
        f.write(f"\n\n## Clarification (Jev)\nThe executor reported BLOCKED on: {question}\n\n"
                f"Decided by the relay's Jev gate (confidence {d['confidence']}, p_ask_owner "
                f"{d['p_ask_owner']}): **{d['choice']}** - {opts[d['choice']]}\n\n"
                "This is now part of the spec. Validator: grade against it, and say in Concerns if it "
                "looks like the wrong call.\n")
    return f"ANSWERED {d['choice']}", d


# --------------------------------------------------------- pane (shadow) ---
PANE_STATES = {
    "working": "Actively producing: a spinner, an elapsed-time or progress line, tool calls running, output streaming",
    "finished-no-artifact": "Its turn is over and nothing is pending: it printed a DONE line or sits at an EMPTY "
                            "input prompt (a bare `>` or `❯`), yet the expected artifact is not there",
    "unsent-input": "A message sits typed in the input box after the prompt marker but was never submitted",
    "waiting-for-input": "A specific question, y/n confirmation, approval, trust or permission dialog is on "
                         "screen and needs an answer",
    "error": "An error, stack trace, crash, auth or sign-in failure, or a bare shell with no agent in it",
    "quota": "A quota, rate-limit or usage-limit message is blocking it",
}


def pane(ws, agent, artifact, elapsed_s, progress_age_s, screen_file, wait_id):
    screen = read(screen_file)
    # The tail matters most: that is where the prompt, a spinner or an error banner sits.
    screen = screen[-3000:] if len(screen) > 3000 else screen
    st = {"agent": agent, "expected_artifact": artifact,
          "minutes_waiting": round(int(elapsed_s) / 60, 1),
          "minutes_since_any_file_was_written": round(int(progress_age_s) / 60, 1),
          "screen_tail": screen}
    a = jev_call(st, {"s": {"type": "choice", "criteria": PANE_STATES,
                            "instructions": "This is the terminal screen of an AI coding agent that the relay "
                                            "is waiting on to write `expected_artifact`. Which state is the "
                                            "agent in right now?"}})["answers"]["s"]
    return f"LOGGED {a.get('choice')}", {"wait_id": wait_id, "agent": agent, "artifact": artifact,
                                         "elapsed_s": int(elapsed_s), "progress_age_s": int(progress_age_s),
                                         "state": a.get("choice"), "confidence": a.get("confidence"),
                                         "probabilities": a.get("probabilities"), "screen": str(screen_file)}


# ----------------------------------------------------------------- main ---
SAFE = {"verdict": "UNKNOWN", "mutation": "MUTATE", "blocked": "ASK"}


def main(argv):
    cmd, ws, args = argv[1], argv[2], argv[3:]
    try:
        if cmd == "verdict":
            decision, info = verdict(ws, args[0])
        elif cmd == "sweep":
            decision, info = sweep(ws, args)
        elif cmd == "mutation":
            decision, info = mutation(ws, args[0])
        elif cmd == "blocked":
            decision, info = blocked(ws, args[0])
        elif cmd == "pane":
            decision, info = pane(ws, *args[:6])
        else:
            print(f"unknown subcommand {cmd}", file=sys.stderr)
            return 2
        record(ws, cmd, {"args": args, "decision": decision, **info})
        reason = info.get("reason", "")
        print(f"{decision} {reason}".rstrip() if cmd in ("mutation", "blocked") else decision)
    except Exception as e:  # never break the relay: fall back to the pre-Jev behaviour
        safe = "KEEP " + " ".join(args) if cmd == "sweep" else SAFE.get(cmd, "")
        record(ws, cmd, {"args": args, "decision": safe, "error": str(e)[:300]})
        print(f"{safe} jev-error: {clip(str(e), 160)}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv))
