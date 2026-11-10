"""Bounded first-party subtitle adapter test. Never executes downloaded skill scripts."""
import hashlib,json,pathlib,subprocess,socket
out=pathlib.Path('/out')
def run(args):
 return subprocess.run(args,check=True,capture_output=True,text=True,timeout=60).stdout
# Prove the execution restrictions rather than merely reporting Docker flags.
try:
 pathlib.Path('/etc/skill-write-test').write_text('must fail')
 raise RuntimeError('Root filesystem is writable')
except PermissionError: pass
except OSError: pass
network_blocked=False
try:
 socket.create_connection(('1.1.1.1',443),timeout=2).close()
except OSError: network_blocked=True
if not network_blocked: raise RuntimeError('Network unexpectedly available')
text='1\n00:00:00,000 --> 00:00:01,400\nAI Company OS\n\n2\n00:00:01,500 --> 00:00:03,000\nVerified subtitle sample\n'
(out/'sample.srt').write_text(text)
run(['ffmpeg','-y','-filter_threads','1','-f','lavfi','-i','color=c=blue:s=320x180:r=10','-t','3','-c:v','libx264','-threads','1','-pix_fmt','yuv420p',str(out/'input.mp4')])
run(['ffmpeg','-y','-filter_threads','1','-i',str(out/'input.mp4'),'-vf','subtitles=/out/sample.srt','-c:v','libx264','-threads','1','-pix_fmt','yuv420p',str(out/'subtitled.mp4')])
probe=json.loads(run(['ffprobe','-v','error','-show_entries','format=duration:stream=codec_name,width,height','-of','json',str(out/'subtitled.mp4')]))
if not 2.8<=float(probe['format']['duration'])<=3.2: raise RuntimeError('Incorrect output duration')
def frame_hash(path):
 data=subprocess.run(['ffmpeg','-v','error','-i',str(path),'-frames:v','1','-f','rawvideo','-pix_fmt','rgb24','-'],check=True,capture_output=True,timeout=30).stdout
 return hashlib.sha256(data).hexdigest()
if frame_hash(out/'input.mp4')==frame_hash(out/'subtitled.mp4'): raise RuntimeError('Subtitles did not change the frame')
report={'passed':True,'scope':'subtitle_fixture_v1','network_blocked':network_blocked,'root_read_only':True,'duration':float(probe['format']['duration']),'subtitle_cues':2,'output_sha256':hashlib.sha256((out/'subtitled.mp4').read_bytes()).hexdigest(),'note':'仅验证已给定SRT与合成视频的字幕处理；不包含语音识别、任意第三方脚本或完整视频制作。'}
(out/'verification.json').write_text(json.dumps(report,ensure_ascii=False))
print(json.dumps(report,ensure_ascii=False))

