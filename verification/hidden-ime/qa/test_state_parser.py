#!/usr/bin/env python3
"""Parser regression fixtures, explicitly not real-device acceptance evidence."""
import importlib.util,pathlib,unittest
repo=pathlib.Path(__file__).resolve().parents[3]
spec=importlib.util.spec_from_file_location('oracle',repo/'scripts/verify-hidden-ime-state.py');oracle=importlib.util.module_from_spec(spec);spec.loader.exec_module(oracle)
displays='''WINDOW MANAGER DISPLAY CONTENTS
  Display: mDisplayId=2 (organized)
    InsetsSource id=3 type=ime frame=[0,0][0,0] visible=false
'''
windows='''WINDOW MANAGER WINDOWS
  Window #0 Window{abc u0 dev.example.app/.MainActivity}:
    mDisplayId=2
    isVisible=true
'''
class StateParserTests(unittest.TestCase):
 def check(self,d=displays,w=windows):return oracle.inspect(d,w,{2:'dev.example.app'})
 def test_explicit_nonvacuous_hidden(self):self.assertTrue(self.check()['passed'])
 def test_missing_display_fails(self):
  with self.assertRaises(ValueError):self.check(d='')
 def test_missing_inset_fails(self):
  with self.assertRaises(ValueError):self.check(d='  Display: mDisplayId=2\n')
 def test_missing_window_state_fails(self):
  with self.assertRaises(ValueError):self.check(w='')
 def test_visible_inset_fails(self):
  with self.assertRaises(ValueError):self.check(d=displays.replace('visible=false','visible=true'))
 def test_duplicate_display_fails(self):
  with self.assertRaises(ValueError):self.check(d=displays+displays)
 def test_unrelated_display_does_not_hide_target(self):
  with self.assertRaises(ValueError):self.check(d=displays.replace('mDisplayId=2','mDisplayId=3'))
 def test_package_suffix_not_matching(self):
  with self.assertRaises(ValueError):self.check(w=windows.replace('dev.example.app/','foreign.dev.example.app/'))
 def test_visible_ime_window_rejects_false_inset(self):
  ime='''  Window #1 Window{def u0 InputMethod}:
    mDisplayId=2
    mHasSurface=true isReadyForDisplay()=true
    isOnScreen=true
    isVisible=true
'''
  with self.assertRaises(ValueError):self.check(w=windows+ime)
 def test_ime_window_missing_visibility_fails(self):
  ime='''  Window #1 Window{def u0 InputMethod}:
    mDisplayId=2
    mHasSurface=false isReadyForDisplay()=false
    isOnScreen=false
'''
  with self.assertRaises(ValueError):self.check(w=windows+ime)
 def test_other_display_ime_does_not_claim_target_visible(self):
  ime='''  Window #1 Window{def u0 InputMethod}:
    mDisplayId=0
    mHasSurface=true isReadyForDisplay()=true
    isOnScreen=true
    isVisible=true
'''
  self.assertTrue(self.check(w=windows+ime)['passed'])
 def test_hidden_policy_allows_ime_source_absence(self):
  d='  Display: mDisplayId=2\n    SettingsEntry{mShouldShowIme=2}\n'
  self.assertTrue(self.check(d=d)['displays'][0]['ime_source_absent_with_explicit_hide'])
 def test_wrong_known_policy_rejects_false_insets(self):
  for token in ['0','1','null','unknown','']:
   with self.assertRaises(ValueError):self.check(d=displays+'    SettingsEntry{mShouldShowIme='+token+'}\n')
 def test_physical_hide_policy_cannot_authorize_target(self):
  d='  Display: mDisplayId=0\n    mShouldShowIme=2\n  Display: mDisplayId=2\n    mShouldShowIme=null\n'
  with self.assertRaises(ValueError):self.check(d=d)
 def test_attached_ime_rejected_with_hide_policy(self):
  ime='  Window #1 Window{def u0 InputMethod}:\n    mDisplayId=2\n    mHasSurface=true isReadyForDisplay()=false\n    isOnScreen=false\n    isVisible=false\n'
  with self.assertRaises(ValueError):self.check(d=displays+' mShouldShowIme=2\n',w=windows+ime)
 def test_conflicting_policy_rejected(self):
  with self.assertRaises(ValueError):self.check(d=displays+' mShouldShowIme=2 mShouldShowIme=0\n')
 def test_true_inset_still_rejected_with_hide_policy(self):
  with self.assertRaises(ValueError):self.check(d=displays.replace('visible=false','visible=true')+' SettingsEntry{mShouldShowIme=2}\n')
 def test_real_api37_explicit_hide_without_source(self):
  root=pathlib.Path(__file__).parent/'api37-hide-diagnostic'
  result=oracle.inspect((root/'failed-displays.txt').read_text(),(root/'failed-windows.txt').read_text(),{3:'dev.droidbridge.testapp'})
  self.assertEqual(result['displays'][0]['ime_policy'],2)
  self.assertTrue(result['displays'][0]['ime_source_absent_with_explicit_hide'])
 def test_real_local_bug_control_detected(self):
  root=pathlib.Path(__file__).parent/'api35-local-positive'
  with self.assertRaisesRegex(ValueError,'Visible IME inset'):
   self.check(d=(root/'0-displays.txt').read_text(),w=(root/'0-windows.txt').read_text())
if __name__=='__main__':unittest.main(verbosity=2)
