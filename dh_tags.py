import json,base64,urllib.request,sys
cfg=json.load(open("/root/.docker/config.json"))
auth=None
for k,v in cfg.get("auths",{}).items():
    if "auth" in v: auth=v["auth"]; break
if not auth: print("no docker auth"); sys.exit(1)
def tok(repo):
    u="https://auth.docker.io/token?service=registry.docker.io&scope=repository:foundationbot/%s:pull"%repo
    r=urllib.request.Request(u); r.add_header("Authorization","Basic "+auth)
    return json.load(urllib.request.urlopen(r,timeout=20))["token"]
def tags(repo):
    try:
        t=tok(repo)
        u="https://registry-1.docker.io/v2/foundationbot/%s/tags/list"%repo
        r=urllib.request.Request(u); r.add_header("Authorization","Bearer "+t)
        return json.load(urllib.request.urlopen(r,timeout=20)).get("tags",[]) or []
    except Exception as e:
        return ["ERR:"+str(e)]
repos=["gaia-vector","gaia-tools","dma-streams","dma-ethercat","argus.vr.web.react",
"argus.gateway","nimbus.s3_dynamo_athena","positronic-control","phantom-cuda",
"okvis2x","okvis2x-models","cpp-robot-state-estimator","dma_bridge"]
for repo in repos:
    ts=tags(repo)
    beta=sorted([x for x in ts if isinstance(x,str) and x.lower().startswith("beta")])
    if beta:
        print("%-28s BETA: %s"%(repo,", ".join(beta)))
    elif ts and str(ts[0]).startswith("ERR:"):
        print("%-28s %s"%(repo,ts[0]))
    else:
        print("%-28s (no beta) sample=%s"%(repo,ts[-4:]))
