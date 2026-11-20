"""Explicit synthetic CI fixture; never uses company files or model output."""
import json,math,struct,sys,wave,zlib
from pathlib import Path
p=Path(sys.argv[1]);p.mkdir(parents=True,exist_ok=True)
def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
rows=b''.join(b'\0'+bytes([y%256,100,180])*512 for y in range(768))
(p/'character.png').write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',512,768,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b''))
with wave.open(str(p/'voice.wav'),'wb') as w:
 w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000);w.writeframes(b''.join(struct.pack('<h',round(3000*math.sin(i*2*math.pi*440/16000))) for i in range(64000)))
(p/'voice.txt').write_text('synthetic tone, not speech')
(p/'plan.json').write_text(json.dumps({'shots':[{'id':'a','image':'character','start':0,'duration':7,'motion':'still','voice':None,'dialogue':''},{'id':'b','image':'character','start':7,'duration':8,'motion':'slow_push','voice':'dialogue','dialogue':'synthetic tone, not speech'}]}))
