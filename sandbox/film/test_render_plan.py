import unittest
from render_film import build_command
class PlanTests(unittest.TestCase):
 def plan(self): return {'shots':[{'id':'a','image':'character','start':0,'duration':7,'motion':'still','voice':None},{'id':'b','image':'character','start':7,'duration':8,'motion':'slow_push','voice':'dialogue','dialogue':'fixture'}]}
 def test_fixed_paths_and_timing(self):
  command,total=build_command(self.plan(),4.5)
  self.assertEqual(total,15);self.assertIn('/out/sample.mp4',command);self.assertIn('adelay=7000:all=1',command[command.index('-filter_complex')+1])
 def test_truncation(self):
  with self.assertRaisesRegex(ValueError,'truncation'):build_command(self.plan(),9)
 def test_no_model_paths(self):
  p=self.plan();p['shots'][0]['image']='../../secret'
  with self.assertRaisesRegex(ValueError,'unsupported'):build_command(p,4)
 def test_no_timeline_gaps(self):
  p=self.plan();p['shots'][1]['start']=8
  with self.assertRaisesRegex(ValueError,'timeline'):build_command(p,4)
if __name__=='__main__':unittest.main()
