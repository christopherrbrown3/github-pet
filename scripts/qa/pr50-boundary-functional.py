"""One actual-app boundary fixture after preserved t52 exits; no unit/core harness."""
import pathlib,subprocess,json,os,hashlib,datetime,traceback
root=pathlib.Path('/Users/chris/github-pet-worktrees/qa-engineer')
out=root/'docs/qa/pr50-d0448c1'; out.mkdir(exist_ok=True)
bundle=pathlib.Path('/Users/chris/github-pet-builds/pr50-d0448c1/GitHubPet.app')
binary=bundle/'Contents/MacOS/GitHubPet'
sha='d0448c17b49060797cfb5ebaaab905eb68d96b97'
result={'sha':sha,'started':datetime.datetime.now(datetime.timezone.utc).isoformat()}
def snapshot():
 p=pathlib.Path.home()/'Library/Preferences'
 return {f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in p.glob('dev.github-pet.*') if f.is_file()}
def execute():
 w=subprocess.run(['hc','wait','t52','--timeout','600'],capture_output=True,text=True,timeout=610)
 (out/'old-helper-wait.json').write_text(w.stdout+w.stderr)
 state=json.loads(subprocess.run(['hc','get','t52'],capture_output=True,text=True,check=True).stdout)
 result['old_helper']={k:state.get(k) for k in ('state','exit_code','signal')}
 if state.get('state')!='finished':raise RuntimeError('Old helper not finished; new app not launched')
 processes=subprocess.run(['ps','-axo','pid=,comm='],capture_output=True,text=True,check=True).stdout
 apps=[s for s in processes.splitlines() if s.strip().endswith('/Contents/MacOS/GitHubPet') and not s.strip().startswith('31897 ')]
 if apps:raise RuntimeError('Another QA app remains; new app not launched: '+repr(apps))
 revision=subprocess.run(['/usr/libexec/PlistBuddy','-c','Print :GitHubPetSourceRevision',str(bundle/'Contents/Info.plist')],capture_output=True,text=True,check=True).stdout.strip()
 assert revision==sha,revision
 result['binary_sha256']=hashlib.sha256(binary.read_bytes()).hexdigest()
 result['preferences_before']=snapshot()
 render=out/'boundary-render'
 assert not render.exists(),'Refusing mixed render directory'
 fixture=pathlib.Path('/Users/chris/github-pet-builds/pr50-d0448c1/boundary-pack')
 result['stored_id']=json.loads((fixture/'manifest.json').read_text())['id']
 p=subprocess.Popen([str(binary),'--render-snapshots',str(render)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env={'HOME':str(pathlib.Path.home()),'PATH':'/usr/bin:/bin','GITHUB_PET_PACK_DIR':str(fixture)})
 result['pid']=p.pid
 try:stdout,stderr=p.communicate(timeout=300)
 except subprocess.TimeoutExpired:
  result['hung_pid']=p.pid
  raise RuntimeError('300-second bound exceeded; process left untouched; no second app may run')
 (out/'stdout.log').write_bytes(stdout);(out/'stderr.bin').write_bytes(stderr)
 result['exit']=p.returncode
 lines=[s for s in stderr.decode().splitlines() if s.startswith('GitHubPet: mascot pack ')]
 assert len(lines)==1,lines
 label=lines[0].split('GitHubPet: mascot pack ',1)[1].split(' loaded from ',1)[0]
 result['displayed_label']=label;result['displayed_scalars']=len(label)
 result['pack_loaded']=' loaded from ' in lines[0]
 result['png_count']=len(list(render.glob('*.png')))
 result['preferences_after']=snapshot()
 result['preferences_changed']=[k for k in result['preferences_before'] if result['preferences_after'].get(k)!=result['preferences_before'][k]]
 result['new_plists']=sorted(set(result['preferences_after'])-set(result['preferences_before']))
 result['mechanical_boundary_ok']=p.returncode==0 and result['pack_loaded'] and len(label)==256 and label.endswith('…')
 result['verdict']='AWAIT_VISUAL_INSPECTION'
try:execute()
except Exception as e:result['error']=str(e);result['traceback']=traceback.format_exc();result['verdict']='INCOMPLETE'
finally:
 result['finished']=datetime.datetime.now(datetime.timezone.utc).isoformat()
 (out/'completion.json').write_text(json.dumps(result,indent=2,ensure_ascii=True)+'\n')
 message='PR50 bounded functional helper completed: '+result['verdict']+'; '+str(out/'completion.json')+'; inspect old33 final results and newd044 PNGs. No kills or units.'
 subprocess.run(['hc','send','t55',message],timeout=70)
 subprocess.run(['hc','send','t1r',message],timeout=70)
 print(message,flush=True)
