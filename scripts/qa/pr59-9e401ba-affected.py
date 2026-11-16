#!/usr/bin/env python3
"""PR59 9e401ba: acquire exact green CI artifact, verify it, run the 2 affected #35 hidden-results flows only.
No CI waiting, retries, builds, signals or force quits. Records evidence; no product verdict.
"""
import hashlib,json,pathlib,plistlib,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parents[2]
SHA='9e401baded33611f2fdbcfbb238093c9d38d7207'
RUN='43885610761'
REPO='christopherrbrown3/github-pet'
r=ROOT/'docs/qa/pr59-9e401ba'
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
    # Existing actions only: org+covered repo overlap, hidden/hidden-only, then a full 30-node page with more matches.
    steps=[{'action':'settings-add','kind':'repository','text':'demo-a/pet','label':'draft-add-covered-repo'},
           {'action':'settings-apply','label':'apply-org-plus-covered-repo'},
           {'action':'visibility','mode':'hidden','label':'overlap-rows-plus-hidden'},
           {'action':'visibility','mode':'hidden-only','label':'overlap-zero-visible-hidden'},
           {'action':'visibility','mode':'hidden','label':'overlap-hidden-before-fill'}]
    steps+=[{'action':'inject-row','label':f'fill-{n:02d}'} for n in range(1,30)]
    steps+=[{'action':'visibility','mode':'complete','label':'full-page-all-visible'},{'action':'quit'}]
    custom=r/'hidden-overlap-fullpage.json'
    custom.write_text(json.dumps({'name':'hidden-overlap-fullpage','steps':steps},indent=2)+'\n')
    args=['python3',str(ROOT/'scripts/qa/scope-artifact-functional.py'),'--app',str(app),'--sha',SHA,'--output',str(r/'functional')]
    for scenario in ['hidden-results',str(custom)]:
        args+=['--scenario',scenario]
    result=subprocess.run(args,cwd=ROOT,capture_output=True,text=True,timeout=800)
    (r/'functional-driver.stdout').write_text(result.stdout);(r/'functional-driver.stderr').write_text(result.stderr)
    if result.returncode: raise RuntimeError('functional driver stopped/failed; no retry, inspect preserved evidence')
    save('checkpoint.json',{'state':'artifacts verified; 2 affected actual-app runs completed; independent judgement pending','sha':SHA,'run':RUN})
    print('QA51_AFFECTED_COMPLETE',r,flush=True)
except Exception as error:
    if r.exists(): save('STOP.json',{'reason':str(error),'sha':SHA,'run':RUN,'policy':'no retries/forcequit/signals; any timed-out app remains intact'})
    print('QA51_AFFECTED_STOP',str(error),flush=True);sys.exit(2)
