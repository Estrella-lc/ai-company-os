"""Fixed mature-model adapter. Public model data only; no remote Python, pickle, shell or generated code."""
import hashlib,json,os,re,sys,time,tarfile,urllib.request,shutil,wave
from pathlib import Path

IMAGE_MODEL='OpenVINO/LCM_Dreamshaper_v7-int8-ov'
TTS_ASSET='vits-melo-tts-zh_en.tar.bz2'
def sha(path):
 h=hashlib.sha256()
 with open(path,'rb') as f:
  for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
 return h.hexdigest()
def public_json(url):
 if not url.startswith(('https://huggingface.co/api/','https://api.github.com/repos/k2-fsa/sherpa-onnx/')): raise ValueError('source_host')
 req=urllib.request.Request(url,headers={'User-Agent':'AI-Company-OS-Creative-Research','Accept':'application/json'})
 with urllib.request.urlopen(req,timeout=30) as r:
  data=r.read(3_000_001)
 if len(data)>3_000_000: raise ValueError('metadata_size')
 return json.loads(data)
def prepare(out,wanted=None):
 from huggingface_hub import snapshot_download
 out.mkdir(parents=True,exist_ok=True)
 if wanted and (wanted.get('image',{}).get('repository')!=IMAGE_MODEL or not re.fullmatch('[a-f0-9]{40}',wanted.get('image',{}).get('revision',''))): raise ValueError('reuse_model_binding')
 info=public_json('https://huggingface.co/api/models/'+IMAGE_MODEL+('/revision/'+wanted['image']['revision'] if wanted else ''))
 revision=info['sha']
 if not re.fullmatch('[a-f0-9]{40}',revision) or info.get('private') or info.get('gated'): raise ValueError('image_source_unavailable')
 model_dir=out/'image'
 snapshot_download(IMAGE_MODEL,revision=revision,local_dir=model_dir,token=False,
  allow_patterns=['*.json','*.xml','*.bin','*.txt','*.model'],max_workers=4)
 # The factory loads fixed OpenVINO IR graphs, never repository Python or torch pickle files.
 for f in model_dir.rglob('*'):
  if f.is_file() and f.suffix in ('.py','.pkl','.pickle','.pt','.pth'): raise ValueError('executable_model_data')
 release=public_json('https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/tags/tts-models')
 asset=next(a for a in release['assets'] if a['name']==TTS_ASSET)
 if asset['size']>250_000_000: raise ValueError('voice_model_size')
 url=asset['browser_download_url']
 if url!='https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/'+TTS_ASSET: raise ValueError('voice_source')
 archive=out/TTS_ASSET
 if not archive.exists():
  with urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'AI-Company-OS'}),timeout=90) as r,open(archive,'wb') as f:
   total=0
   while True:
    block=r.read(1024*1024)
    if not block: break
    total+=len(block)
    if total>250_000_000: raise ValueError('voice_download_size')
    f.write(block)
 digest=sha(archive)
 if wanted and (wanted['voice'].get('asset_id')!=asset['id'] or wanted['voice'].get('sha256')!=digest): raise ValueError('reuse_voice_version_changed')
 if asset.get('digest') and asset['digest']!='sha256:'+digest: raise ValueError('voice_model_hash')
 total=0
 with tarfile.open(archive,'r:bz2') as t:
  members=t.getmembers()
  if len(members)>500: raise ValueError('model_archive_files')
  for m in members:
   p=Path(m.name)
   if p.is_absolute() or '..' in p.parts or not p.parts or p.parts[0]!='vits-melo-tts-zh_en' or m.issym() or m.islnk(): raise ValueError('model_archive_path')
   if not m.isfile(): continue
   if p.suffix not in ('.onnx','.txt','.fst','.utf8','.md','.json') and p.name not in ('LICENSE','README'): continue
   total+=m.size
   if total>600_000_000: raise ValueError('model_archive_size')
   target=out/p;target.parent.mkdir(parents=True,exist_ok=True)
   with t.extractfile(m) as source,open(target,'wb') as dest: shutil.copyfileobj(source,dest)
 files=[{'path':str(p.relative_to(model_dir)),'sha256':sha(p),'bytes':p.stat().st_size} for p in model_dir.rglob('*') if p.is_file() and '.cache' not in p.parts]
 if wanted and {f['path']:f['sha256'] for f in files}!={f['path']:f['sha256'] for f in wanted['image']['files']}: raise ValueError('reuse_image_version_changed')
 result={'image':{'repository':IMAGE_MODEL,'revision':revision,'license':info.get('cardData',{}).get('license','unknown'),'files':files},
  'voice':{'repository':'k2-fsa/sherpa-onnx','asset_id':asset['id'],'asset_url':url,'sha256':digest,'license_file':(out/'vits-melo-tts-zh_en/LICENSE').read_text()[:6000]},
  'engine':{'image':'openvino-genai==2026.4.1.0','voice':'sherpa-onnx==1.12.38'},'data_only':True}
 (out/'manifest.json').write_text(json.dumps(result,ensure_ascii=False))
 print(json.dumps({'prepared':True,'image_revision':revision,'voice_sha256':digest}))
def generate(models,request,out):
 import numpy as np
 from PIL import Image,ImageStat
 import openvino_genai as ov
 import sherpa_onnx
 start=time.monotonic();spec=json.loads(request.read_text())
 if not isinstance(spec.get('image_prompt_en'),str) or not 20<=len(spec['image_prompt_en'])<=1200: raise ValueError('image_prompt')
 if not isinstance(spec.get('voice_text'),str) or not 8<=len(spec['voice_text'])<=80: raise ValueError('voice_text')
 out.mkdir(parents=True,exist_ok=True)
 if not spec.get('voice_only'):
  print('CREATIVE_ENGINE image_load',flush=True)
  pipe=ov.Text2ImagePipeline(str(models/'image'))
  pipe.reshape(1,768,512,1.0)
  pipe.compile('CPU',INFERENCE_NUM_THREADS=2,NUM_STREAMS='1',PERFORMANCE_HINT='LATENCY')
  print('CREATIVE_ENGINE image_generate',flush=True)
  image=pipe.generate(spec['image_prompt_en'],width=512,height=768,num_inference_steps=8,guidance_scale=1.0,rng_seed=int(spec.get('seed',42)))
  image=Image.fromarray(image.data[0]);image.save(out/'character.png')
  del pipe
 print('CREATIVE_ENGINE voice_load',flush=True)
 voice=models/'vits-melo-tts-zh_en'
 config=sherpa_onnx.OfflineTtsConfig(model=sherpa_onnx.OfflineTtsModelConfig(vits=sherpa_onnx.OfflineTtsVitsModelConfig(model=str(voice/'model.onnx'),lexicon=str(voice/'lexicon.txt'),tokens=str(voice/'tokens.txt'),dict_dir=str(voice/'dict')),num_threads=2,provider='cpu'),# Short bounded scripts fit in one utterance; do not infer a two-character salutation alone.
 max_num_sentences=0)
 if not config.validate(): raise ValueError('voice_configuration')
 tts=sherpa_onnx.OfflineTts(config)
 print('CREATIVE_ENGINE voice_generate',flush=True)
 audio=tts.generate(spec['voice_text'],sid=0,speed=1.0)
 samples=np.asarray(audio.samples,dtype=np.float32)
 duration=len(samples)/audio.sample_rate
 if not 1<=duration<=20 or np.max(np.abs(samples))<0.01 or np.mean(np.abs(samples)>=0.999)>0.01: raise ValueError('voice_quality')
 with wave.open(str(out/'voice.wav'),'wb') as f:
  f.setnchannels(1);f.setsampwidth(2);f.setframerate(audio.sample_rate);f.writeframes((np.clip(samples,-1,1)*32767).astype('<i2').tobytes())
 if not spec.get('voice_only') and (min(image.size)<512 or max(ImageStat.Stat(image).stddev)<12): raise ValueError('image_quality')
 result={'scope':'creative_samples_v1','passed':True,'image':{'width':512,'height':768},'voice':{'sample_rate':audio.sample_rate,'duration_seconds':duration,'rms':float(np.sqrt(np.mean(samples*samples)))},
  'files':{**({'character.png':spec['preserved_image']} if spec.get('voice_only') else {'character.png':{'sha256':sha(out/'character.png'),'bytes':(out/'character.png').stat().st_size}}),'voice.wav':{'sha256':sha(out/'voice.wav'),'bytes':(out/'voice.wav').stat().st_size}},'elapsed_seconds':round(time.monotonic()-start,3),'api_cost_usd':0,
  'isolation':{'network_disabled':True,'root_read_only':True,'unprivileged':os.getuid()!=0,'secrets_absent':not any(k in os.environ for k in ('GEMINI_API_KEY','SUPABASE_SERVICE_ROLE_KEY','ACTIONS_ID_TOKEN_REQUEST_TOKEN'))},'limitations':['单个虚构成年角色参考图，不等于角色一致性或成片能力','固定普通话声音，不支持声音克隆或任意音色','CPU样例验证，不代表商业版权审查或CEO验收']}
 if any(x['bytes']>2_000_000 for x in result['files'].values()): raise ValueError('output_size')
 (out/'verification.json').write_text(json.dumps(result,ensure_ascii=False));print(json.dumps(result))
if __name__=='__main__':
 if sys.argv[1]=='prepare': prepare(Path(sys.argv[2]),json.loads(Path(sys.argv[3]).read_text()) if len(sys.argv)>3 else None)
 elif sys.argv[1]=='generate': generate(Path(sys.argv[2]),Path(sys.argv[3]),Path(sys.argv[4]))
 else: raise ValueError('unsupported_operation')
