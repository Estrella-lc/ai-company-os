import unittest
from process_media import validate_srt
class SubtitleValidation(unittest.TestCase):
 def test_chinese_and_bom(self):
  text,count=validate_srt('\ufeff1\r\n00:00:00,000 --> 00:00:01,000\r\n你好，AI员工\r\n'.encode())
  self.assertEqual(count,1);self.assertIn('你好',text)
 def test_rejects_injection_and_invalid_media_timing(self):
  for text in ['{\\an8}test','<font>test</font>','test\\Nother','a\nb\nc','a\x00']:
   with self.assertRaises(ValueError):validate_srt(('1\n00:00:00,000 --> 00:00:01,000\n'+text).encode())
  for timing in ['00:00:01,000 --> 00:00:00,000','00:00:00,000 --> 00:01:01,000','00:66:00,000 --> 00:66:01,000']:
   with self.assertRaises(ValueError):validate_srt(('1\n'+timing+'\ntest').encode())
 def test_limits(self):
  for raw in [b'',b'a'*65537,b'\xff',b'1\nmissing time\ntest']:
   with self.assertRaises((ValueError,UnicodeDecodeError)):validate_srt(raw)
if __name__=='__main__':unittest.main()
