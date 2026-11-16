#!/usr/bin/env python3
"""PR50 49f3a17: exact green CI artifact, then ONE missing-alpha/missing-beta asset-error launch.
Same fixture and offscreen renderer mode as pr50-asset-error-ci.py. No retries, signals or quits.
"""
import hashlib,importlib.util,json,os,pathlib,plistlib,shutil,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parents[2]
SHA='49f3a17c75d4a6e3d4d0da832a946782c9b30f7f'
RUN='43884718129'
REPO='christopherrbrown3/github-pet'
spec=importlib.util.spec_from_file_location('snap',ROOT/'scripts/qa/scope-artifact-functional.py');snap=importlib.util.module_from_spec(spec);spec.loader.exec_module(snap)
r=ROOT/'docs/qa/pr50-49f3a17'
def run(argv,timeout=180):
    result=subprocess.run(argv,capture_output=True,text=True,timeout=timeout)
    if result.returncode: raise RuntimeError(f'{argv[:4]} failed {result.returncode}: {result.stderr[:500]}')
    return result.stdout
def saved():
    s=subprocess.run(['ps','-p','31897','-o','pid=,lstart=,comm='],capture_output=True,text=True,check=True).stdout.strip()
    assert s.endswith('/Users/chris/github-pet-builds/b0127f0/GitHubPet.app/Contents/MacOS/GitHubPet')
    return s
try:
    r.mkdir(parents=True,exist_ok=False)
    ci=json.loads(run(['gh','run','view',RUN,'--repo',REPO,'--json','headSha,status,conclusion']));snap.save(r/'ci.json',ci)
    if ci!={'headSha':SHA,'status':'completed','conclusion':'success'}: raise RuntimeError('CI not exact-head completed SUCCESS')
    artifacts=json.loads(run(['gh','api',f'repos/{REPO}/actions/runs/{RUN}/artifacts']));snap.save(r/'artifact-metadata.json',artifacts)
    matches=[x for x in artifacts['artifacts'] if x['name']=='GitHubPet-app' and not x['expired']]
    if len(matches)!=1 or matches[0].get('workflow_run',{}).get('head_sha')!=SHA: raise RuntimeError('missing/ambiguous/mismatched app artifact')
    folder=r/'artifact';folder.mkdir()
    run(['gh','run','download',RUN,'--repo',REPO,'--name','GitHubPet-app','--dir',str(folder)])
    zips=list(folder.glob('*.zip'));checks=list(folder.glob('*.sha256'))
    if len(zips)!=1 or len(checks)!=1: raise RuntimeError('missing/ambiguous ZIP/sidecar')
    ziphash=hashlib.sha256(zips[0].read_bytes()).hexdigest()
    if ziphash!=checks[0].read_text().split()[0]: raise RuntimeError('ZIP checksum mismatch')
    run(['ditto','-xk',str(zips[0]),str(folder/'extracted')])
    app=folder/'extracted/GitHubPet.app';binary=app/'Contents/MacOS/GitHubPet'
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    if info['GitHubPetSourceRevision']!=SHA: raise RuntimeError('embedded revision mismatch')
    run(['codesign','--verify','--deep','--strict',str(app)])
    snap.save(r/'provenance.json',{'sha':SHA,'ci':RUN,'ZIPsha256':ziphash,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),
        'revision':info['GitHubPetSourceRevision'],'build':info.get('CFBundleVersion'),'strictSignature':'PASS'})
    assert not any('GitHubPet.app/Contents/MacOS/GitHubPet' in line and '31897' not in line for line in run(['ps','-axo','pid,comm']).splitlines()), 'another QA app present'
    # Identical fixture to docs/qa/pr50-45befb4/asset-error-ci/missing-pair.
    case=r/'missing-pair';case.mkdir(mode=0o700)
    pack=case/'pack';shutil.copytree(app/'Contents/Resources/MascotPacks/mona-pet-v1',pack)
    manifest=pack/'manifest.json';data=json.loads(manifest.read_text())
    common='frames/'+'shared-diagnostic-prefix-'*3+'/'
    paths=[common+'missing-alpha.png',common+'missing-beta.png']
    data['id']='qa-asset-error-pair';data['name']='QA asset error pair';data['states']['idle'].update(frames=paths,durationMs=[500,500],staticFallback=paths[0])
    manifest.write_text(json.dumps(data,indent=2)+'\n');snap.save(case/'fixture.json',{'absentPaths':paths,'sharedPrefixLength':len(common),'sameAs':'docs/qa/pr50-45befb4/asset-error-ci/missing-pair'})
    trap=case/'tripwire';trap.mkdir();gh=trap/'gh';gh.write_text('#!/bin/sh\nprintf "invoked\\n" >> "'+str(trap/'invocations')+'"\nexit 1\n');gh.chmod(0o700)
    output=case/'snapshots';output.mkdir(mode=0o700)
    env=dict(os.environ,PATH=str(trap)+os.pathsep+os.environ['PATH'],GITHUB_PET_GH_PATH=str(gh),GITHUB_PET_PACK_DIR=str(pack))
    before=snap.snapshot();saved_before=saved();snap.save(case/'before.json',{'preferences':before,'saved31897':saved_before})
    argv=[str(binary),'--render-snapshots',str(output),'--fixtures']
    with (case/'stdout.bin').open('wb') as stdout,(case/'stderr.bin').open('wb') as stderr:
        process=subprocess.Popen(argv,env=env,stdout=stdout,stderr=stderr)
        snap.save(case/'launch.json',{'pid':process.pid,'argv':argv})
        try: code=process.wait(timeout=300)
        except subprocess.TimeoutExpired:
            snap.save(case/'STOP.json',{'reason':'300s bound exceeded; no signals or quit attempted','pid':process.pid});print('QA50_STOP_TIMEOUT',process.pid,flush=True);sys.exit(2)
    after=snap.snapshot();saved_after=saved();snap.save(case/'after.json',{'preferences':after,'saved31897':saved_after})
    changed_domains=sorted(k for k in set(before['domains'])|set(after['domains']) if before['domains'].get(k)!=after['domains'].get(k))
    changed_files=sorted(k for k in set(before['files'])|set(after['files']) if before['files'].get(k)!=after['files'].get(k))
    line=[x for x in (case/'stderr.bin').read_text().splitlines() if x.startswith('GitHubPet: mascot ')]
    result={'exit':code,'pid':process.pid,'launchLines':line,'ghTripwireInvoked':(trap/'invocations').exists(),'saved31897Unchanged':saved_before==saved_after,
        'changedDomains':changed_domains,'changedFiles':changed_files,'pngCount':len(list(output.glob('*.png'))),'verdict':'none: QA must inspect Settings/placeholder PNGs'}
    snap.save(case/'completion.json',result);print('QA50_ASSET_COMPLETE',json.dumps(result),flush=True)
except Exception as error:
    if r.exists(): snap.save(r/'STOP.json',{'reason':str(error),'sha':SHA,'run':RUN,'policy':'no retries/forcequit/signals'})
    print('QA50_ASSET_STOP',str(error),flush=True);sys.exit(2)
