#!/usr/bin/env python3
"""One actual-CI-app functional diagnostic capture, no source build or unit harness."""
import importlib.util,json,os,pathlib,shutil,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('snap',ROOT/'scripts/qa/scope-artifact-functional.py');snap=importlib.util.module_from_spec(spec);spec.loader.exec_module(snap)
r=ROOT/'docs/qa/pr50-45befb4/asset-error-ci'
app=r/'artifact/extracted/GitHubPet.app';binary=app/'Contents/MacOS/GitHubPet'
def saved():
    s=subprocess.run(['ps','-p','31897','-o','pid=,lstart=,comm='],capture_output=True,text=True,check=True).stdout.strip()
    assert s.endswith('/Users/chris/github-pet-builds/b0127f0/GitHubPet.app/Contents/MacOS/GitHubPet')
    return s
assert not any('GitHubPet.app/Contents/MacOS/GitHubPet' in line and '31897' not in line for line in subprocess.run(['ps','-axo','pid,comm'],capture_output=True,text=True,check=True).stdout.splitlines()), 'another QA app present'
case=r/'missing-pair';case.mkdir(mode=0o700)
pack=case/'pack';shutil.copytree(app/'Contents/Resources/MascotPacks/mona-pet-v1',pack)
manifest=pack/'manifest.json';data=json.loads(manifest.read_text())
common='frames/'+'shared-diagnostic-prefix-'*3+'/'
paths=[common+'missing-alpha.png',common+'missing-beta.png']
data['id']='qa-asset-error-pair';data['name']='QA asset error pair';data['states']['idle'].update(frames=paths,durationMs=[500,500],staticFallback=paths[0])
manifest.write_text(json.dumps(data,indent=2)+'\n');snap.save(case/'fixture.json',{'absentPaths':paths,'sharedPrefixLength':len(common),'manifest':str(manifest),'validator':'accumulates errors; checked-set deduplicates each path'})
trap=case/'tripwire';trap.mkdir();gh=trap/'gh';gh.write_text('#!/bin/sh\nprintf "invoked\\n" >> "'+str(trap/'invocations')+'"\nexit 1\n');gh.chmod(0o700)
output=case/'snapshots';output.mkdir(mode=0o700)
env=dict(os.environ,PATH=str(trap)+os.pathsep+os.environ['PATH'],GITHUB_PET_GH_PATH=str(gh),GITHUB_PET_PACK_DIR=str(pack))
before=snap.snapshot();saved_before=saved();snap.save(case/'before.json',{'preferences':before,'saved31897':saved_before})
argv=[str(binary),'--render-snapshots',str(output),'--fixtures']
with (case/'stdout.bin').open('wb') as stdout,(case/'stderr.bin').open('wb') as stderr:
    process=subprocess.Popen(argv,env=env,stdout=stdout,stderr=stderr)
    snap.save(case/'launch.json',{'pid':process.pid,'argv':argv})
    try:code=process.wait(timeout=300)
    except subprocess.TimeoutExpired:
        snap.save(case/'STOP.json',{'reason':'300s bound exceeded; no signals or quit attempted','pid':process.pid});print('QA50_STOP_TIMEOUT',process.pid,flush=True);sys.exit(2)
after=snap.snapshot();saved_after=saved();snap.save(case/'after.json',{'preferences':after,'saved31897':saved_after})
changed_domains=[k for k in set(before['domains'])|set(after['domains']) if before['domains'].get(k)!=after['domains'].get(k)]
changed_files=[k for k in set(before['files'])|set(after['files']) if before['files'].get(k)!=after['files'].get(k)]
line=[x for x in (case/'stderr.bin').read_text().splitlines() if x.startswith('GitHubPet: mascot ')]
result={'exit':code,'pid':process.pid,'launchLines':line,'ghTripwireInvoked':(trap/'invocations').exists(),'saved31897Unchanged':saved_before==saved_after,'changedDomains':changed_domains,'changedFiles':changed_files,'pngCount':len(list(output.glob('*.png'))),'verdict':'none: QA must inspect Settings/placeholder PNGs'}
snap.save(case/'completion.json',result);print('QA50_ASSET_COMPLETE',json.dumps(result),flush=True)
