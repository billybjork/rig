# usage: bws-migrate.py <tier> <project_id> <token-service>  ; reads repos' .env, uploads the tier's keys, prints names only
import sys,re,subprocess,json,os
tier,pid,svc=sys.argv[1:4]
DEPLOY={"heaters":{"SUPABASE_PROJECT_REF","SUPABASE_DB_PASSWORD","PROD_DATABASE_URL","PROD_DATABASE_POOLER_URL","RENDER_ENV_GROUP_ID","RENDER_SERVICE_ID_WEB","RENDER_API_KEY","NTFY_TOPIC"},"soco":{"NTFY_TOPIC"}}
tok=subprocess.run(["security","find-generic-password","-a",os.environ["USER"],"-s",svc,"-w"],capture_output=True,text=True,check=True).stdout.strip()
env=dict(os.environ,BWS_ACCESS_TOKEN=tok)
have={s["key"] for s in json.loads(subprocess.run(["bws","secret","list",pid,"-o","json"],env=env,capture_output=True,text=True,check=True).stdout)}
made=skipped=0
for repo in ["soco","heaters","red-hot-xtra","billybjork.com"]:
    for l in open(os.path.expanduser(f"~/dev/{repo}/.env")).read().splitlines():
        m=re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$',l.strip())
        if not m or m.group(2)=="": continue
        k,v=m.groups()
        if (k in DEPLOY.get(repo,set())) != (tier=="deploy"): continue
        key=f"{repo}-{k}"
        if key in have: skipped+=1; continue
        import time; time.sleep(4)
        r=subprocess.run(["bws","secret","create",key,v,pid,"-o","none"],env=env,capture_output=True,text=True)
        if r.returncode: print("FAILED",key, r.stderr.splitlines()[1][:120] if len(r.stderr.splitlines())>1 else ""); continue
        made+=1
print(f"{tier}: created {made}, already there {skipped}")
