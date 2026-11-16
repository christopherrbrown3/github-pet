#!/usr/bin/env python3
"""PR66 9818b9d: acquire exact green CI artifact, verify it, run ONE simulated in-flight Refresh label flow.
No CI waiting, retries, builds, signals or force quits. Records evidence; no product verdict.
"""
import hashlib,json,pathlib,plistlib,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parents[2]
SHA='9818b9def60fec23de490885e9b2c3f7e812eac0'
RUN='43930832600'
REPO='christopherrbrown3/github-pet'
r=ROOT/'docs/qa/pr66-9818b9d'
def save(name,value): (r/name).write_text(json.dumps(value,indent=2)+'\n')
def run(argv,timeout=180):
    result=subprocess.run(argv,capture_output=True,text=True,timeout=timeout)
    if result.returncode: raise RuntimeError(f'{argv[:4]} failed {result.returncode}: {result.stderr[:500]}')
    return result.stdout
def ghjson(args): return json.loads(run(['gh']+args))
try:
    r.mkdir(parents=True,exist_ok=False)
    ci=ghjson(['run','view',RUN,'--repo',REPO,'--json','headSha,status,conclusion']);save('ci.json',ci)
    if ci!={'headSha':SHA,'status':'completed','conclusion':'success'}: raise RuntimeError('CI not exact-head completed SUCCESS')
    artifacts=ghjson(['api',f'repos/{REPO}/actions/runs/{RUN}/artifacts']);save('artifact-metadata.json',artifacts)
    for name in ['GitHubPet-app','render-check']:
        matches=[x for x in artifacts['artifacts'] if x['name']==name and not x['expired']]
        if len(matches)!=1: raise RuntimeError('missing/ambiguous uploaded artifact '+name)
        if matches[0].get('workflow_run',{}).get('head_sha')!=SHA: raise RuntimeError('artifact SHA mismatch')
        dest=r/('app-artifact' if name=='GitHubPet-app' else 'ci-render');dest.mkdir()
        run(['gh','run','download',RUN,'--repo',REPO,'--name',name,'--dir',str(dest)])
    folder=r/'app-artifact';zips=list(folder.glob('*.zip'));checks=list(folder.glob('*.sha256'))
    if len(zips)!=1 or len(checks)!=1: raise RuntimeError('missing/ambiguous ZIP/sidecar')
    ziphash=hashlib.sha256(zips[0].read_bytes()).hexdigest()
    if ziphash!=checks[0].read_text().split()[0]: raise RuntimeError('ZIP checksum mismatch')
    run(['ditto','-xk',str(zips[0]),str(folder/'extracted')])
    app=folder/'extracted/GitHubPet.app';binary=app/'Contents/MacOS/GitHubPet'
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    if info['GitHubPetSourceRevision']!=SHA: raise RuntimeError('embedded revision mismatch')
    run(['codesign','--verify','--deep','--strict',str(app)])
    save('provenance.json',{'sha':SHA,'ci':RUN,'ZIPsha256':ziphash,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),
        'revision':info['GitHubPetSourceRevision'],'build':info.get('CFBundleVersion'),'strictSignature':'PASS','app':str(app)})
    # Existing actions only: hold one reply so a poll is in flight (footer should say Refreshing...), then deliver.
    steps=[{'action':'hold','count':1,'refresh':True,'label':'poll-in-flight'},
           {'action':'deliver-all','label':'reply-delivered'},{'action':'quit'}]
    custom=r/'refresh-in-flight.json'
    custom.write_text(json.dumps({'name':'refresh-in-flight','steps':steps},indent=2)+'\n')
    args=['python3',str(ROOT/'scripts/qa/scope-artifact-functional.py'),'--app',str(app),'--sha',SHA,'--output',str(r/'functional')]
    for scenario in [str(custom)]:
        args+=['--scenario',scenario]
    result=subprocess.run(args,cwd=ROOT,capture_output=True,text=True,timeout=800)
    (r/'functional-driver.stdout').write_text(result.stdout);(r/'functional-driver.stderr').write_text(result.stderr)
    if result.returncode: raise RuntimeError('functional driver stopped/failed; no retry, inspect preserved evidence')
    save('checkpoint.json',{'state':'artifacts verified; 1 affected actual-app run completed; independent judgement pending','sha':SHA,'run':RUN})
    print('QA51_AFFECTED_COMPLETE',r,flush=True)
except Exception as error:
    if r.exists(): save('STOP.json',{'reason':str(error),'sha':SHA,'run':RUN,'policy':'no retries/forcequit/signals; any timed-out app remains intact'})
    print('QA51_AFFECTED_STOP',str(error),flush=True);sys.exit(2)
