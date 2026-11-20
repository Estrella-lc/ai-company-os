"""Fixed FFmpeg adapter. No shell commands or paths supplied by model output."""
import hashlib,json,math,subprocess
from pathlib import Path

def probe(path):
 return json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(path)],timeout=15))

def build_command(plan,voice_seconds):
 shots=plan.get('shots',[])
 if not 2<=len(shots)<=6: raise ValueError('shot_count')
 cursor=0;voiced=[];filters=[];seen=set()
 for i,s in enumerate(shots):
  start=s.get('start');duration=s.get('duration')
  if isinstance(start,bool) or isinstance(duration,bool) or not isinstance(start,(int,float)) or not isinstance(duration,(int,float)) or not math.isfinite(start+duration) or abs(start-cursor)>.001 or not 1<=duration<=12: raise ValueError('timeline')
  if s.get('id') in seen or not isinstance(s.get('id'),str): raise ValueError('shot_id')
  seen.add(s['id'])
  if s.get('image')!='character' or s.get('motion') not in ('still','slow_push','slow_pull'): raise ValueError('unsupported_asset_or_motion')
  if s.get('voice') is not None:
   if s['voice']!='dialogue' or voice_seconds>duration: raise ValueError('voice_truncation')
   voiced.append(start)
  elif s.get('dialogue'): raise ValueError('missing_voice')
  zoom={'still':'1','slow_push':'min(1.08,1+on*0.0003)','slow_pull':'max(1,1.08-on*0.0003)'}[s['motion']]
  filters.append(f"[v{i}]scale=512:768,setsar=1,zoompan=z='{zoom}':x='iw/2-iw/zoom/2':y='ih/2-ih/zoom/2':d=1:s=512x768:fps=30,trim=duration={duration},setpts=PTS-STARTPTS[s{i}]")
  cursor+=duration
 if not 15<=cursor<=30 or len(voiced)!=1: raise ValueError('duration_or_voice_count')
 if voiced[0]+voice_seconds>cursor: raise ValueError('voice_truncation')
 graph='[0:v]split='+str(len(shots))+''.join(f'[v{i}]' for i in range(len(shots)))+';'+ ';'.join(filters)+';'+''.join(f'[s{i}]' for i in range(len(shots)))+f'concat=n={len(shots)}:v=1:a=0[v];[1:a]adelay={round(voiced[0]*1000)}:all=1,apad,atrim=duration={cursor}[a]'
 return ['ffmpeg','-hide_banner','-loglevel','error','-y','-loop','1','-framerate','30','-i','/input/character.png','-i','/input/voice.wav','-filter_complex',graph,'-map','[v]','-map','[a]','-t',str(cursor),'-c:v','libx264','-preset','fast','-crf','18','-pix_fmt','yuv420p','-r','30','-c:a','aac','-b:a','192k','-movflags','+faststart','/out/sample.mp4'],cursor

def render():
 root=Path('/input');out=Path('/out');plan=json.loads((root/'plan.json').read_text())
 voice=probe(root/'voice.wav');seconds=float(voice['format']['duration'])
 if not 1<=seconds<=20: raise ValueError('voice_duration')
 # A fixed script sidecar must match the approved recorded line exactly.
 script=(root/'voice.txt').read_text().strip()
 if not script or any(s.get('voice') is not None and s.get('dialogue')!=script for s in plan.get('shots',[])): raise ValueError('dialogue_fidelity')
 command,total=build_command(plan,seconds);subprocess.run(command,check=True,timeout=150)
 path=out/'sample.mp4';data=probe(path);video=[s for s in data['streams'] if s['codec_type']=='video'];audio=[s for s in data['streams'] if s['codec_type']=='audio']
 if len(video)!=1 or len(audio)!=1 or (video[0]['width'],video[0]['height'])!=(512,768) or abs(float(data['format']['duration'])-total)>.15 or path.stat().st_size>20*1024*1024: raise ValueError('output_quality')
 subprocess.run(['ffmpeg','-v','error','-i',str(path),'-f','null','-'],check=True,timeout=30)
 report={'scope':'still_image_edit_v1','technical_passed':True,'duration':total,'width':512,'height':768,'bytes':path.stat().st_size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'independent_film_review':'required','ceo_acceptance':False,'limitations':['静态图剪辑，无嘴型动画','不含新增字幕轨或背景音乐','技术检查不代表成片业务质检通过']}
 (out/'verification.json').write_text(json.dumps(report,ensure_ascii=False))
if __name__=='__main__': render()
