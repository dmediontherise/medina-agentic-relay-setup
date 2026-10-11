import sys,glob,os,re
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0,os.path.expanduser("~/.claude/relay")); import relay_jev as R
cases=[]
# usage: python -I eval_verdict.py <workspace> [<workspace> ...]   (run with the Jev venv)
for rp in sorted(p for ws in sys.argv[1:] for p in glob.glob(os.path.join(ws, ".relay", "reports", "*.md"))):
    md=R.read(rp); m=re.search(r"^VERDICT:\s*(PASS-WITH-CONCERNS|FAIL|PASS)",md[:300],re.M)
    body=re.sub(r"(?im)^(VERDICT|NEXT-TASK):.*\n?","",md)
    body=re.sub(r"(?i)verdict:?\s*(PASS-WITH-CONCERNS|PASS|FAIL)","verdict: [redacted]",body)  # no title leak
    cases.append((rp,m.group(1) if m else None,body))
CR={"PASS":"Every requirement met; no defects","PASS-WITH-CONCERNS":"Requirements met, but real non-disqualifying concerns are recorded","FAIL":"At least one requirement is unmet or unproven, or a defect must be fixed; a follow-up is needed"}
def run(c):
    rp,truth,body=c
    st={"report_requirements":R.clip(R.section(body,"Requirement-by-requirement") or R.section(body,"Requirement"),1500),
        "defects":R.clip(R.section(body,"Defects"),1200),"concerns":R.clip(R.section(body,"Concerns"),800),
        "recommended_next":R.clip(R.section(body,"Recommended next"),600),"opening":R.clip(body[:1200],1200)}
    a=R.jev_call(st,{"v":{"type":"choice","criteria":CR,"instructions":"Which verdict did this validator report reach?"}})["answers"]["v"]
    return rp,truth,a.get("choice"),a.get("confidence")
with ThreadPoolExecutor(8) as ex: res=list(ex.map(run,cases))
lab=[r for r in res if r[1]]; unl=[r for r in res if not r[1]]
ok=sum((r[1]=="FAIL")==(r[2]=="FAIL") for r in lab)
print(f"labeled {len(lab)}: FAIL-vs-not accuracy {ok}/{len(lab)}; exact {sum(r[1]==r[2] for r in lab)}/{len(lab)}")
from collections import Counter
print("confusion (truth,pred):",Counter((r[1],r[2]) for r in lab))
for th in (0.5,0.7,0.8,0.9):
    hi=[r for r in lab if r[3] is not None and float(r[3])>=th]
    print(f" conf>={th}: covered {len(hi)}/{len(lab)}, FAIL-vs-not errors {sum((r[1]=='FAIL')!=(r[2]=='FAIL') for r in hi)}, missed FAILs {sum(r[1]=='FAIL' and r[2]!='FAIL' for r in hi)}")
print("unlabeled reports:",[(os.path.basename(r[0])[:30],r[2],r[3]) for r in unl])
