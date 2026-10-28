import sys,re,os,hashlib
repo=sys.argv[1]; skip=set(sys.argv[2:]); ok=bad=0; miss=[]
h=lambda v: hashlib.sha256(v.encode()).hexdigest()
for l in open(os.path.expanduser(f"~/dev/{repo}/.env")).read().splitlines():
    m=re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$',l.strip())
    if not m or m.group(2)=="" or m.group(1) in skip: continue
    k,v=m.groups()
    if k not in os.environ: miss.append(k)
    elif h(os.environ[k])==h(v): ok+=1
    else: bad+=1; print("  MISMATCH",k)
print(f"{repo}: {ok} match, {bad} mismatch, missing {miss}")
