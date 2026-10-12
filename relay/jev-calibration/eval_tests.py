import sys,glob,os,re,json,difflib
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0,os.path.expanduser("~/.claude/relay")); import relay_jev as R
# usage: python -I eval_tests.py --labels <labels.txt> <workspace> [<workspace> ...]   (Jev venv)
# Re-measures relay_jev.py's `tests` question. For every .relay/mutants/<task> snapshot whose
# task was a clean PASS or is listed as a positive, it takes the test code the task added
# (diff against the previous snapshot holding the file) and asks Jev the gate's question.
# labels.txt, kept out of the repo, has one task id per line: `+<id>` for a task the
# validator failed for tests that re-implement or cannot catch the code, `-<id>` for a task
# to leave out (failed for some other reason).
args=sys.argv[1:]; pos,excl=set(),set()
if "--labels" in args:
    i=args.index("--labels")
    for l in open(args[i+1]):
        l=l.strip()
        if l.startswith("+"): pos.add(l[1:])
        elif l.startswith("-"): excl.add(l[1:])
    del args[i:i+2]
rows=[]
for ws in args:
    snaps=sorted(os.path.basename(p) for p in glob.glob(os.path.join(ws,".relay","mutants","*")))
    for i,b in enumerate(snaps):
        rp,res=os.path.join(ws,".relay","reports",b+".md"),os.path.join(ws,".relay","results",b+".md")
        if b in excl or not (os.path.exists(rp) and os.path.exists(res)): continue
        v=(re.search(r"^VERDICT:\s*(\S+)",R.read(rp),re.M) or [None,"?"])[1]
        if b not in pos and v!="PASS": continue
        for f in [f for f in R.changed_files(R.read(res)) if R.TEST_FILE.search(f)]:
            p=os.path.join(ws,".relay","mutants",b,f)
            if not os.path.isfile(p): continue
            after=R.read(p); before=None
            for pb in reversed(snaps[:i]):
                q=os.path.join(ws,".relay","mutants",pb,f)
                if os.path.isfile(q): before=R.read(q); break
            added=after if before is None else "\n".join(l for l in difflib.unified_diff(before.splitlines(),after.splitlines(),n=2,lineterm="") if not l.startswith(("---","+++")))
            if added.strip(): rows.append((ws,b,int(b in pos),f,after,added))
def run(r):
    ws,b,lab,f,after,added=r
    imp="\n".join(l for l in after.splitlines()[:60] if re.match(r"\s*(import |from \S+ import|const .*require\(|.*= require\()",l))[:1500]
    a=R.jev_call({"test_file":f,"imports":imp,"added_test_code":added[:9000]},{"r":R.TESTS_Q})["answers"]["r"]
    return (ws,b,lab,float(a.get("noul") or 0))
with ThreadPoolExecutor(6) as ex: res=list(ex.map(run,rows))
t={}
for ws,b,lab,p in res: t[(ws,b)]=(max(t.get((ws,b),(0,0))[0],p),lab)
P=[s for s,l in t.values() if l]; N=[s for s,l in t.values() if not l]
print(f"tasks: {len(P)} positive, {len(N)} clean passes; task-level AUC {sum((p>n)+.5*(p==n) for p in P for n in N)/max(1,len(P)*len(N)):.2f}")
for th in (0.3,0.5,0.7):
    print(f"  >= {th}: positives named {sum(p>=th for p in P)}/{len(P)}, passes named {sum(n>=th for n in N)}/{len(N)}")
