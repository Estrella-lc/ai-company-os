"""First-party harness calibration only. Never used as generated company skill code."""
import re
def analyze_srt(text,duration_seconds=None):
 text=text.lstrip('\ufeff').replace('\r\n','\n').replace('\r','\n').strip()
 if not text:return {'valid':False,'cue_count':0,'issues':[{'code':'EMPTY_INPUT','cue':0}]}
 blocks=re.split(r'\n\s*\n',text);issues=[];previous=None
 for index,block in enumerate(blocks,1):
  lines=block.split('\n');codes=[]
  match=re.fullmatch(r'(\d{2}):([0-5]\d):([0-5]\d),(\d{3}) --> (\d{2}):([0-5]\d):([0-5]\d),(\d{3})',lines[1]) if len(lines)>1 else None
  if not lines[0].isdigit() or not match:codes.append('FORMAT_ERROR')
  elif match:
   v=list(map(int,match.groups()));start=v[0]*3600+v[1]*60+v[2]+v[3]/1000;end=v[4]*3600+v[5]*60+v[6]+v[7]/1000
   if end<=start:codes.append('INVALID_TIME')
   else:
    if previous is not None and start<previous:codes.append('OVERLAP')
    if duration_seconds is not None and duration_seconds>0 and end>duration_seconds:codes.append('OUT_OF_RANGE')
    previous=end
  body=[line for line in lines[2:] if line.strip()]
  if not body:codes.append('EMPTY_TEXT')
  if len(body)>2 or any(len(line)>42 for line in body):codes.append('TEXT_TOO_LONG')
  issues.extend({'code':code,'cue':index} for code in codes)
 return {'valid':not issues,'cue_count':len(blocks),'issues':issues}
