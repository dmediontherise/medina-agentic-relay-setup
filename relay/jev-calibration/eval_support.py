import sys,glob,json,os,random
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0,os.path.expanduser("~/.claude/relay")); import relay_cite as C
sys.path.insert(0,os.path.expanduser("~/Jev-AI-Skill")); from jev_mcp import jev
# usage: python -I eval_support.py '<glob of JSON data files>' [field ...]   (Jev venv)
# The measurement behind NOT wiring a Jev "does the page support this claim?" step into the
# citation check (relay/jev-calibration.md). Takes records shaped {name, <field>: str,
# <field>_src: {url}}, already accepted by a validator, and asks Jev about each claim three
# ways: against its own page (should be supported), with the value of another record on the
# same page (value-swap), and against another record's page (page-swap). Re-run it when the
# fetch can render JavaScript - that, not Jev, is what held it back.
files=glob.glob(sys.argv[1]); fields=set(sys.argv[2:])
claims=[]
for f in files:
    try: data=json.load(open(f))
    except ValueError: continue
    for e in data if isinstance(data,list) else []:
        for k,v in e.items():
            if k.endswith("_src") and isinstance(v,dict) and v.get("url") and isinstance(e.get(k[:-4]),str) and (not fields or k[:-4] in fields):
                claims.append({"name":e.get("name","?"),"field":k[:-4],"value":e[k[:-4]],"url":v["url"]})
random.seed(3); random.shuffle(claims); claims=claims[:160]
urls=sorted({c["url"] for c in claims})
with ThreadPoolExecutor(12) as ex: pages=dict(zip(urls,ex.map(C.fetch,urls)))
claims=[c for c in claims if pages[c["url"]]["text"]]
say=lambda c:f'{c["name"]} - {c["field"].replace("_"," ")}: {c["value"]}'
cases=[]
for c in claims:
    cases.append(("real",say(c),c["url"]))
    o=[x for x in claims if x["field"]==c["field"] and x["value"].strip().lower()!=c["value"].strip().lower()]
    if o: cases.append(("value-swap",say({**c,"value":random.choice(o)["value"]}),c["url"]))
    o=[x for x in claims if x["name"]!=c["name"] and x["url"]!=c["url"]]
    if o: cases.append(("page-swap",say(c),random.choice(o)["url"]))
Q={"s":{"type":"noul","instructions":"Do the page excerpts state or directly support the claim?",
        "criteria":{"true":"The excerpts say what the claim says about this specific subject, or something that plainly implies it",
                    "false":"The excerpts are about something else, are generic, contradict it, or do not mention the specific fact the claim states"}}}
def ask(c):
    kind,claim,u=c; cw=set(C.words(claim)); t=pages[u]["text"]
    ex=sorted([t[i:i+500] for i in range(0,min(len(t),200_000),400)],key=lambda ch:-len(cw&set(C.words(ch))))[:5]
    return kind,jev("jev-latest",{"claim":claim,"cited_url":u,"page_excerpts":ex},Q)["answers"]["s"]["noul"]
with ThreadPoolExecutor(8) as ex: res=list(ex.map(ask,cases))
real=[p for k,p in res if k=="real"]
print(f"{len(claims)} claims with readable pages")
for kind in ("value-swap","page-swap"):
    bad=[p for k,p in res if k==kind]
    print(f"  {kind}: AUC {sum((r>b)+.5*(r==b) for r in real for b in bad)/len(real)/len(bad):.2f}, caught <0.2 {sum(b<0.2 for b in bad)}/{len(bad)}")
print(f"  accepted claims called unsupported (<0.2): {sum(r<0.2 for r in real)}/{len(real)}")
