"""Score the Jev pane shadow against what each wait actually did.

usage: python -I eval_pane_shadow.py [--rescore] <workspace> [<workspace> ...]   (Jev venv)

autopilot, with RELAY_JEV=1, logs a `pane` record every couple of minutes while it waits on
an agent (Jev's guess at the pane's state) and a `pane_outcome` record when the wait ends
(ok / stalled / timeout / fault:... / stopped). This joins them per wait and answers the one
question that decides whether the shadow should ever be allowed to act:

  * on waits that ended BADLY (stalled, timeout, fault), how many minutes before the relay
    gave up did Jev first say the pane was not working - the time an acting gate would save;
  * on waits that ended OK, how often did Jev say "not working" while the agent was in fact
    still going to deliver - the cost of acting on it (a needless nudge or restart).

A sample within GRACE_S of a successful wait's end is not counted as a false alarm: an agent
legitimately finishes a little before autopilot's next poll sees the file.

--rescore re-asks Jev about every saved screen with the CURRENT state labels in
relay_jev.py, so a label change can be judged on the screens already collected.
"""
import glob
import json
import os
import sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
GRACE_S = 60
BAD = ("stalled", "timeout", "fault")


def load(workspaces):
    samples, outcomes = defaultdict(list), {}
    for ws in workspaces:
        for path in glob.glob(os.path.join(ws, ".relay", "jev", "decisions.jsonl")):
            for line in open(path, encoding="utf-8", errors="replace"):
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if d.get("kind") == "pane" and d.get("state"):
                    samples[d["wait_id"]].append(d)
                elif d.get("kind") == "pane_outcome":
                    outcomes[d["wait_id"]] = d
    return samples, outcomes


def rescore(samples):
    import relay_jev as R
    for wid, ss in samples.items():
        for d in ss:
            if not os.path.exists(d.get("screen", "")):
                continue
            ws = d["screen"].split(os.sep + ".relay" + os.sep)[0]
            try:
                _, info = R.pane(ws, d["agent"], d["artifact"], d["elapsed_s"], d["progress_age_s"],
                                 d["screen"], wid)
                d["state"], d["confidence"] = info["state"], info["confidence"]
            except Exception as e:  # keep the logged answer if Jev is unreachable
                print(f"rescore failed for {d['screen']}: {e}", file=sys.stderr)


def flagged(d, t):
    return d["state"] != "working" and float(d.get("confidence") or 0) >= t


def main(argv):
    do_rescore = "--rescore" in argv
    workspaces = [a for a in argv if a != "--rescore"]
    if not workspaces:
        print(__doc__)
        return 2
    samples, outcomes = load(workspaces)
    if do_rescore:
        rescore(samples)
    joined = {w: (sorted(samples.get(w, []), key=lambda d: d["elapsed_s"]), o) for w, o in outcomes.items()}
    sampled = {w: v for w, v in joined.items() if v[0]}
    kinds = Counter(o["result"].split(":")[0] for _, o in joined.values())
    print(f"waits with an outcome: {len(joined)} ({dict(kinds)}); with at least one sample: {len(sampled)}")
    print(f"samples: {sum(len(s) for s, _ in sampled.values())}  states: "
          f"{dict(Counter(d['state'] for s, _ in sampled.values() for d in s))}")
    if not sampled:
        print("nothing to score yet - run autopilot with RELAY_JEV=1 and come back")
        return 0

    print("\nstate by outcome (all samples):")
    by = defaultdict(Counter)
    for s, o in sampled.values():
        for d in s:
            by[o["result"].split(":")[0]][d["state"]] += 1
    for k, c in sorted(by.items()):
        print(f"  {k:<8} {dict(c)}")

    print(f"\nconf>=t | bad waits caught / total, median lead (min) | ok waits with a false alarm / total")
    for t in (0.5, 0.7, 0.8, 0.9):
        caught, leads, bad_n, fa, ok_n = 0, [], 0, 0, 0
        for s, o in sampled.values():
            kind, end = o["result"].split(":")[0], o["elapsed_s"]
            if kind in BAD:
                bad_n += 1
                first = next((d for d in s if flagged(d, t)), None)
                if first:
                    caught += 1
                    leads.append((end - first["elapsed_s"]) / 60)
            elif kind == "ok":
                ok_n += 1
                if any(flagged(d, t) and d["elapsed_s"] < end - GRACE_S for d in s):
                    fa += 1
        med = sorted(leads)[len(leads) // 2] if leads else 0
        print(f"  {t:<6} | {caught}/{bad_n}, {med:.1f} | {fa}/{ok_n}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
