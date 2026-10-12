import sys,glob,os,re,tempfile,json,subprocess
from collections import Counter
# usage: python3 -I eval_cite.py [--defects <labels.txt>] <workspace> [<workspace> ...]
# Replays relay_cite.py over every .relay/mutants/<task> snapshot (the tree as the executor
# left it), in task order, so each task is judged only on the citations it added. Reports
# go to a temp dir, never into the workspace. Needs network: it fetches every cited page,
# and pages drift, so a rerun months later will not match these numbers exactly.
CITE=os.path.join(os.path.dirname(os.path.abspath(__file__)),"..","relay_cite.py")
# Labels stay out of the repo: --defects <file> lists, one per line, the task ids whose
# validator report (or the follow-up written right after it) names a citation defect - a
# cited page that does not carry the claim, a dead or redirected source.
args=sys.argv[1:]; CITATION_DEFECT=set()
if "--defects" in args:
    i=args.index("--defects"); CITATION_DEFECT={l.strip() for l in open(args[i+1]) if l.strip() and not l.startswith("#")}; del args[i:i+2]
out=tempfile.mkdtemp(prefix="eval-cite-"); rows=[]
for ws in args:
    snaps=sorted(os.path.basename(p) for p in glob.glob(os.path.join(ws,".relay","mutants","*")))
    for b in snaps:
        if not os.path.exists(os.path.join(ws,".relay","results",b+".md")): continue
        rp=os.path.join(ws,".relay","reports",b+".md")
        v=re.search(r"^VERDICT:\s*(\S+)",open(rp,encoding="utf-8",errors="replace").read(),re.M) if os.path.exists(rp) else None
        r=subprocess.run([sys.executable,"-I",CITE,ws,b,"--root",os.path.join(ws,".relay","mutants",b),
                          "--out",os.path.join(out,os.path.basename(ws.rstrip("/"))),"--no-git"],capture_output=True,text=True).stdout.strip()
        if r.startswith("NONE"): continue
        rows.append((os.path.basename(ws.rstrip("/")),b,v.group(1) if v else "-",b in CITATION_DEFECT,r))
print(f"{'workspace':24} {'task':48} {'verdict':20} defect  check")
for w,b,v,d,r in rows: print(f"{w[:24]:24} {b[:48]:48} {v[:20]:20} {'yes' if d else 'no ':3}     {r}")
flag=lambda r:r.startswith("FLAGGED")
c=Counter((d,flag(r)) for *_,d,r in rows)
print(f"\ncitation-defect tasks flagged {c[(True,True)]}/{c[(True,True)]+c[(True,False)]}; "
      f"other tasks flagged {c[(False,True)]}/{c[(False,True)]+c[(False,False)]}   (reports in {out})")
