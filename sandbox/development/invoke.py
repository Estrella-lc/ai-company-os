"""Trusted invocation wrapper. No acceptance answers or credentials are mounted here."""
import ast,contextlib,importlib.util,io,json,os,pathlib,socket,sys

def probe():
 readonly=False
 try:pathlib.Path('/root-write-probe').write_text('blocked')
 except OSError:readonly=True
 network=False
 try:socket.create_connection(('1.1.1.1',443),timeout=0.5).close()
 except OSError:network=True
 secret_free=not any(k.startswith(('ACTIONS_','GITHUB_TOKEN','SUPABASE_','GEMINI_')) for k in os.environ)
 return {'read_only':readonly,'network_blocked':network,'secret_free':secret_free,'non_root':os.getuid()!=0}

def invoke():
 source=pathlib.Path('/candidate/skill.py').read_text(encoding='utf-8')
 if len(source)>24000:raise ValueError('source_size')
 tree=ast.parse(source)
 allowed_modules={'re','json','math','typing','unicodedata'}
 banned={'open','exec','eval','compile','__import__','getattr','setattr','delattr','globals','locals','vars','input','breakpoint','help','exit','quit'}
 for node in ast.walk(tree):
  if isinstance(node,ast.Import) and any(n.name not in allowed_modules for n in node.names):raise ValueError('import_policy')
  if isinstance(node,ast.ImportFrom) and (node.level or node.module not in allowed_modules):raise ValueError('import_policy')
  if isinstance(node,ast.Name) and (node.id in banned or node.id.startswith('__')):raise ValueError('name_policy')
  if isinstance(node,ast.Attribute) and node.attr.startswith('__'):raise ValueError('attribute_policy')
  if isinstance(node,(ast.Global,ast.Nonlocal,ast.ClassDef,ast.AsyncFunctionDef,ast.Await)):raise ValueError('syntax_policy')
 if any(not isinstance(n,(ast.Import,ast.ImportFrom,ast.FunctionDef,ast.Assign,ast.AnnAssign,ast.Expr)) for n in tree.body):raise ValueError('module_policy')
 payload=json.loads(sys.stdin.read(100000))
 spec=importlib.util.spec_from_file_location('company_candidate','/candidate/skill.py');module=importlib.util.module_from_spec(spec)
 with contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):
  spec.loader.exec_module(module)
  result=module.analyze_srt(payload['text'],payload.get('duration_seconds'))
 encoded=json.dumps(result,ensure_ascii=True,allow_nan=False)
 if len(encoded)>8000:raise ValueError('output_size')
 return {'result':result}

try:
 result=probe() if '--probe' in sys.argv else invoke()
 print(json.dumps(result,ensure_ascii=True,allow_nan=False))
except Exception as error:
 # Never expose a candidate traceback or arbitrary subprocess output.
 known={'source_size','import_policy','name_policy','attribute_policy','syntax_policy','module_policy','output_size'}
 print(json.dumps({'error':str(error) if str(error) in known else type(error).__name__}));sys.exit(1)
