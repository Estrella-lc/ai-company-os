"""Generic declarative connector. Installs a pinned local wheel; never evaluates model code."""
import contextlib,hashlib,importlib,io,json,pathlib,re,socket,subprocess,sys,zipfile,os,types

def member(value,path):
 if not path or path=='@':return value
 for part in path.split('.'):
  if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*',part):raise ValueError('member_policy')
  value=getattr(value,part)
 return value

def run():
 cfg=json.loads(pathlib.Path('/request/config.json').read_text());wheel=pathlib.Path('/request')/cfg['filename'];manifest=cfg['manifest']
 if not re.fullmatch(r'[A-Za-z0-9_.+\-]+\.whl',cfg['filename']) or wheel.stat().st_size>10000000 or hashlib.sha256(wheel.read_bytes()).hexdigest()!=cfg['sha256']:raise ValueError('wheel_integrity')
 with zipfile.ZipFile(wheel) as archive:
  names=archive.namelist()
  if sum(i.file_size for i in archive.infolist())>50000000 or any(n.startswith('/') or '..' in n.split('/') or '\\' in n for n in names):raise ValueError('wheel_paths')
  root=manifest['call'].split('.')[0]
  if root in sys.stdlib_module_names or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*',root) or not any(n.startswith(root+'/') or n==root+'.py' for n in names):raise ValueError('module_origin')
 subprocess.run([sys.executable,'-m','pip','--isolated','install','--disable-pip-version-check','--no-index','--no-deps','--no-compile','--target','/tmp/site',str(wheel)],check=True,capture_output=True,timeout=25)
 sys.path.insert(0,'/tmp/site')
 def argument(v):
  if isinstance(v,dict) and set(v)=={'input'}:return cfg['input'][v['input']]
  if isinstance(v,(str,int,float,bool)) or v is None:return v
  raise ValueError('argument_policy')
 with contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):
  module=importlib.import_module(root);function=member(module,'.'.join(manifest['call'].split('.')[1:]))
  if not callable(function):raise ValueError('call_policy')
  result=function(**{k:argument(v) for k,v in manifest['kwargs'].items()})
  collection=member(result,manifest.get('collection','@'));events=[]
  for i,item in enumerate(collection):
   if i>=200:raise ValueError('event_limit')
   event={}
   for key in ['text','start','end']:
    field=manifest['fields'][key];value=member(item,field['path'])
    if field.get('call') is True:value=value()
    event[key]=str(value) if key=='text' else float(value)*float(field.get('scale',1))
   events.append(event)
 readonly=False
 try:pathlib.Path('/root-probe').write_text('blocked')
 except OSError:readonly=True
 network=False
 try:socket.create_connection(('1.1.1.1',443),timeout=0.5).close()
 except OSError:network=True
 return {'events':events,'isolation':{'read_only':readonly,'network_blocked':network,'non_root':os.getuid()!=0,'secret_free':not any(k.startswith(('GEMINI_','SUPABASE_','ACTIONS_','GITHUB_TOKEN')) for k in os.environ)}}
try:print(json.dumps(run(),ensure_ascii=True,allow_nan=False))
except Exception as e:
 known={'wheel_integrity','wheel_paths','module_origin','member_policy','call_policy','argument_policy','event_limit'}
 print(json.dumps({'error':str(e) if str(e) in known else type(e).__name__}));sys.exit(1)
