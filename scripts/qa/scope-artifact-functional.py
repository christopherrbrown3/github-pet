#!/usr/bin/env python3
"""Exercise an immutable CI app; record functional evidence, never infer product PASS.
No builds, source linking, preference writes, shell evaluation, or forced quits.
"""
import argparse, hashlib, json, os, pathlib, plistlib, subprocess, sys, time

PREFS = pathlib.Path.home() / 'Library/Preferences'
def digest(data): return hashlib.sha256(data).hexdigest()
def command(args): return subprocess.run(args, capture_output=True, check=False)
def snapshot():
    # Read in memory; persist hashes only. Never save configured names/values.
    result = {'files': {}, 'domains': {}}
    for p in sorted(PREFS.glob('dev.github-pet.*.plist')):
        result['files'][p.name] = digest(p.read_bytes())
    domains = command(['defaults','domains']).stdout.decode().strip().split(', ')
    for domain in sorted(set(domains) | {'dev.github-pet.GitHubPet', 'NSGlobalDomain'}):
        if not (domain.startswith('dev.github-pet.') or domain == 'NSGlobalDomain'): continue
        raw = command(['defaults','export',domain,'-'])
        if raw.returncode: result['domains'][domain] = {'present':False}; continue
        try:
            data = plistlib.loads(raw.stdout)
            frames = {k:v for k,v in data.items() if k.startswith('NSWindow Frame GitHubPet.')}
            canonical = lambda obj: plistlib.dumps(obj, fmt=plistlib.FMT_BINARY, sort_keys=True)
            result['domains'][domain] = {'present':True,'hash':digest(canonical(data)),
                'framesHash':digest(canonical(frames)), 'framesCount':len(frames)}
        except Exception: result['domains'][domain] = {'parseError':True,'hash':digest(raw.stdout)}
    return result

def save(path, value): path.write_text(json.dumps(value,indent=2)+'\n')

def main():
    p=argparse.ArgumentParser(); p.add_argument('--app',required=True); p.add_argument('--sha',required=True)
    p.add_argument('--output',required=True); p.add_argument('--scenario',action='append',default=[])
    p.add_argument('--snapshot-only',action='store_true'); a=p.parse_args()
    out=pathlib.Path(a.output).resolve(); out.mkdir(parents=True,exist_ok=False)
    if a.snapshot_only: save(out/'preferences.json',snapshot()); return
    app=pathlib.Path(a.app).resolve(); binary=app/'Contents/MacOS/GitHubPet'
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    assert info['GitHubPetSourceRevision']==a.sha, 'artifact revision mismatch'
    assert not any('GitHubPet' in line and '31897' not in line for line in command(['ps','-axo','pid,comm']).stdout.decode().splitlines()), 'another QA app exists'
    save(out/'provenance.json',{'sha':a.sha,'app':str(app),'binarySHA256':digest(binary.read_bytes())})
    trap=out/'tripwire'; trap.mkdir(); gh=trap/'gh'
    gh.write_text('#!/bin/sh\nprintf "invoked\\n" >> "'+str(trap/'invocations')+'"\nexit 1\n'); gh.chmod(0o700)
    env=dict(os.environ,PATH=str(trap)+os.pathsep+os.environ['PATH'],GITHUB_PET_GH_PATH=str(gh))
    before=snapshot(); save(out/'preferences-before.json',before)
    results=[]
    for scenario in a.scenario:
        label=pathlib.Path(scenario).stem; run=out/label; run.mkdir(); records=run/'records'; records.mkdir()
        argv=[str(binary),'--simulate-monitoring-scope','--qa-scenario',scenario,'--qa-output',str(records)]
        with (run/'stdout.log').open('wb') as stdout,(run/'stderr.log').open('wb') as stderr:
            process=subprocess.Popen(argv,env=env,stdout=stdout,stderr=stderr)
            save(run/'launch.json',{'pid':process.pid,'argv':argv})
            try: code=process.wait(timeout=180)
            except subprocess.TimeoutExpired:
                save(out/'STOPPED.json',{'reason':'180s bound exceeded; own app left intact for path-verified normal quit','pid':process.pid})
                return 2
        steps=list(records.glob('step-*.json'))
        for step in steps: json.loads(step.read_text())
        results.append({'scenario':label,'exit':code,'steps':len(steps),'completed':(records/'runner.json').exists()})
        save(out/'progress.json',results)
        if code: break
    after=snapshot(); save(out/'preferences-after.json',after)
    save(out/'completion.json',{'results':results,'preferencesEqual':before==after,
        'ghInvoked':(trap/'invocations').exists(),'saved31897Present':command(['ps','-p','31897','-o','comm=']).stdout.decode().strip()=='/Users/chris/github-pet-builds/b0127f0/GitHubPet.app/Contents/MacOS/GitHubPet',
        'productVerdict':'none: independent judgement required'})
    print('QA_ARTIFACT_COMPLETE',out,flush=True)
    return int(any(r['exit'] for r in results))
if __name__=='__main__': sys.exit(main() or 0)
