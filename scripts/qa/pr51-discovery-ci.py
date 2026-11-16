#!/usr/bin/env python3
"""Wait once for existing CI watcher, acquire exact artifacts, run affected app flows only."""
import hashlib,json,pathlib,plistlib,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parents[2]
SHA='e57d1f3a8516d3bcdec6d8fb9edf821769052932'
RUN='43808396247'
r=ROOT/'docs/qa/pr51-e57d1f3'
def save(name,value): (r/name).write_text(json.dumps(value,indent=2)+'\n')
def run(argv,timeout=120):
    result=subprocess.run(argv,capture_output=True,text=True,timeout=timeout)
    if result.returncode: raise RuntimeError(f'{argv[:4]} failed {result.returncode}: {result.stderr[:500]}')
    return result.stdout
def ghjson(args): return json.loads(run(['gh']+args))
def notify(message):
    for target in ['t1r','t5p']:
        subprocess.run(['hc','send',target,message],capture_output=True,text=True,timeout=70)
try:
    r.mkdir(parents=True,exist_ok=False)
    save('checkpoint.json',{'state':'waiting once for existing watcher t5y, max900s','sha':SHA,'run':RUN})
    wait=json.loads(run(['hc','wait','t5y','--timeout','900','--json'],timeout=910));save('watcher-completion.json',wait)
    if not wait.get('ended') or wait.get('exit_code')!=0: raise RuntimeError('watcher did not finish successfully; no retry')
    ci=ghjson(['run','view',RUN,'--repo','christopherrbrown3/github-pet','--json','headSha,status,conclusion']);save('ci.json',ci)
    if ci!={'headSha':SHA,'status':'completed','conclusion':'success'}: raise RuntimeError('CI not exact-head completed SUCCESS')
    artifacts=ghjson(['api',f'repos/christopherrbrown3/github-pet/actions/runs/{RUN}/artifacts']);save('artifact-metadata.json',artifacts)
    for name in ['GitHubPet-app','render-check']:
        matches=[x for x in artifacts['artifacts'] if x['name']==name and not x['expired']]
        if len(matches)!=1: raise RuntimeError('missing/ambiguous uploaded artifact '+name)
        if matches[0].get('workflow_run',{}).get('head_sha')!=SHA: raise RuntimeError('artifact SHA mismatch')
        dest=r/('app-artifact' if name=='GitHubPet-app' else 'ci-render');dest.mkdir()
        run(['gh','run','download',RUN,'--repo','christopherrbrown3/github-pet','--name',name,'--dir',str(dest)])
    (r/'ci.log').write_text(run(['gh','run','view',RUN,'--repo','christopherrbrown3/github-pet','--log']))
    folder=r/'app-artifact';zips=list(folder.glob('*.zip'));checks=list(folder.glob('*.sha256'))
    if len(zips)!=1 or len(checks)!=1: raise RuntimeError('missing/ambiguous ZIP/sidecar')
    ziphash=hashlib.sha256(zips[0].read_bytes()).hexdigest()
    if ziphash!=checks[0].read_text().split()[0]: raise RuntimeError('ZIP checksum mismatch')
    run(['ditto','-xk',str(zips[0]),str(folder/'extracted')])
    app=folder/'extracted/GitHubPet.app';binary=app/'Contents/MacOS/GitHubPet'
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    if info['GitHubPetSourceRevision']!=SHA: raise RuntimeError('embedded revision mismatch')
    run(['codesign','--verify','--deep','--strict',str(app)])
    save('provenance.json',{'sha':SHA,'ci':RUN,'ZIPsha256':ziphash,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'strictSignature':'PASS','app':str(app)})
    steps=[{'action':'settings-find-suggestions','label':'a-find-initial'},
           {'action':'account','account':'B','label':'switch-b-clears-hints'},
           {'action':'account','account':'A','label':'return-a-hints-reset'},
           {'action':'settings-find-suggestions','label':'a-find-after-roundtrip'},
           {'action':'open-scope-settings','label':'settings-a-after-roundtrip'},
           {'action':'source','source':'fixtures','label':'switch-fixtures-clears-hints'},
           {'action':'source','source':'gh','label':'return-cli-hints-reset'},
           {'action':'settings-find-suggestions','label':'cli-find-after-roundtrip'},
           {'action':'open-scope-settings','label':'settings-cli-after-roundtrip'},
           {'action':'quit'}]
    custom=r/'discovery-roundtrips.json';custom.write_text(json.dumps({'name':'discovery-roundtrips','steps':steps},indent=2)+'\n')
    args=['python3',str(ROOT/'scripts/qa/scope-artifact-functional.py'),'--app',str(app),'--sha',SHA,'--output',str(r/'functional')]
    for scenario in ['settings-discovery-partial','settings-discovery-identity-mismatch',str(custom)]: args+=['--scenario',scenario]
    # Each actual process has the existing driver's180s bound; timeout means STOP/no signals.
    result=subprocess.run(args,cwd=ROOT,capture_output=True,text=True,timeout=650)
    (r/'functional-driver.stdout').write_text(result.stdout);(r/'functional-driver.stderr').write_text(result.stderr)
    if result.returncode: raise RuntimeError('functional driver stopped/failed; no retry, inspect preserved evidence')
    save('checkpoint.json',{'state':'artifacts verified;3affected actual-app runs completed; independent judgement pending','sha':SHA,'run':RUN})
    notify('QA51_AFFECTED_COMPLETE e57d1f3 exactCI'+RUN+' artifacts verified;3affected app flows completed. Evidence '+str(r)+'. No product verdict inferred; independent JSON/selectedPNG judgement pending. No retries/watcher duplication.')
    print('QA51_AFFECTED_COMPLETE',r,flush=True)
except Exception as error:
    if r.exists(): save('STOP.json',{'reason':str(error),'sha':SHA,'run':RUN,'policy':'no retries/forcequit/signals; any timed-out app remains intact'})
    notify('QA51_AFFECTED_STOP e57d1f3: '+str(error)+'. Evidence '+str(r)+'. No retry or workaround.')
    print('QA51_AFFECTED_STOP',str(error),flush=True);sys.exit(2)
