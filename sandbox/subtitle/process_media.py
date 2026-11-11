"""Fixed MP4 + plain UTF-8 SRT adapter; no candidate skill scripts are executed."""
import hashlib,json,pathlib,re,subprocess
MAX_VIDEO=20*1024*1024

def validate_srt(raw,duration=60):
 if not 0<len(raw)<=65536: raise ValueError('SRT size limit')
 text=raw.decode('utf-8-sig').replace('\r\n','\n').strip()
 blocks=re.split(r'\n\s*\n',text)
 if not 1<=len(blocks)<=200: raise ValueError('SRT cue limit')
 normalized=[]; previous=-1
 def seconds(t):
  h,m,s,ms=map(int,re.split(r'[:,]',t))
  if m>59 or s>59: raise ValueError('Invalid timestamp')
  return h*3600+m*60+s+ms/1000
 for i,block in enumerate(blocks):
  lines=block.splitlines()
  if len(lines)<3 or not lines[0].isdigit(): raise ValueError('Invalid SRT cue')
  match=re.fullmatch(r'(\d{2}:\d{2}:\d{2},\d{3}) --> (\d{2}:\d{2}:\d{2},\d{3})',lines[1])
  if not match: raise ValueError('Invalid SRT timestamp')
  start,end=map(seconds,match.groups())
  if start<previous or end<=start or end>min(60,duration)+0.1: raise ValueError('SRT outside video duration')
  previous=start
  content='\n'.join(lines[2:])
  if len(lines[2:])>2 or not content.strip() or len(content)>160 or any(c in content for c in '{}\\<>') or any(ord(c)<32 and c!='\n' for c in content): raise ValueError('Plain subtitle text only')
  normalized.append(str(i+1)+'\n'+lines[1]+'\n'+content)
 return '\n\n'.join(normalized)+'\n',len(blocks)

def command(args,timeout=120):
 return subprocess.run(args,check=True,capture_output=True,text=True,timeout=timeout).stdout

def process():
 source=pathlib.Path('/input/input.mp4');out=pathlib.Path('/out')
 if not 0<source.stat().st_size<=MAX_VIDEO: raise ValueError('Video size limit')
 info=json.loads(command(['ffprobe','-v','error','-protocol_whitelist','file,pipe','-show_format','-show_streams','-of','json',str(source)],15))
 streams=info.get('streams',[]);video=next((s for s in streams if s.get('codec_type')=='video'),None)
 duration=float(info['format']['duration'])
 if not video or len(streams)>8 or not 0.1<=duration<=60 or 'mp4' not in info['format']['format_name'] or not 1<=video['width']<=1920 or not 1<=video['height']<=1080: raise ValueError('MP4 must be at most 60 seconds and 1920x1080')
 rate=video.get('r_frame_rate','0/1').split('/')
 if len(rate)!=2 or float(rate[1])<=0 or not 0<float(rate[0])/float(rate[1])<=60: raise ValueError('Frame rate limit')
 text,cues=validate_srt(pathlib.Path('/input/input.srt').read_bytes(),duration)
 pathlib.Path('/tmp/subtitles.srt').write_text(text,encoding='utf-8')
 output=out/'subtitled.mp4'
 command(['ffmpeg','-v','error','-nostdin','-y','-filter_threads','1','-protocol_whitelist','file,pipe','-i',str(source),'-map','0:v:0','-map','0:a:0?','-vf',"scale=w='min(1280,iw)':h=-2,subtitles=/tmp/subtitles.srt:force_style='FontName=Noto Sans CJK SC,FontSize=24,Outline=1,MarginV=12'",'-t','60','-r','30','-c:v','libx264','-preset','veryfast','-threads','1','-pix_fmt','yuv420p','-c:a','aac','-b:a','96k','-fs',str(MAX_VIDEO),'-movflags','+faststart',str(output)],120)
 if not 0<output.stat().st_size<MAX_VIDEO: raise ValueError('Output size limit')
 probe=json.loads(command(['ffprobe','-v','error','-show_entries','format=duration','-of','json',str(output)],15))
 output_duration=float(probe['format']['duration'])
 if abs(output_duration-duration)>0.5: raise ValueError('Output duration mismatch')
 report={'passed':True,'scope':'subtitle_delivery_v1','duration':output_duration,'subtitle_cues':cues,'output_bytes':output.stat().st_size,'input_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'srt_sha256':hashlib.sha256(pathlib.Path('/input/input.srt').read_bytes()).hexdigest(),'output_sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'third_party_scripts_executed':False}
 (out/'verification.json').write_text(json.dumps(report),encoding='utf-8')
 print('SUBTITLE_DELIVERY_VERIFIED')

if __name__=='__main__':
 try: process()
 except Exception:
  # Never log filenames, subtitle contents, signed URLs, or ffmpeg stderr.
  print('SUBTITLE_DELIVERY_REJECTED');raise SystemExit(1)
