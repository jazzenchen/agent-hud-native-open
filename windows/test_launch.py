import unittest
from hud import prepare_desktop_environment

class LaunchTests(unittest.TestCase):
    def test_real_windows_launch_cannot_inherit_headless_test_backend(self):
        for value in ('offscreen','minimal','windows'):
            env=dict(QT_QPA_PLATFORM=value,OTHER='retained');prepare_desktop_environment(env,[],platform='nt')
            self.assertEqual(env['QT_QPA_PLATFORM'],'windows');self.assertEqual(env['OTHER'],'retained')
    def test_preview_and_probe_keep_their_explicit_test_environment(self):
        for args in (['--preview-dir','preview'],['--probe']):
            env=dict(QT_QPA_PLATFORM='offscreen');prepare_desktop_environment(env,args,platform='nt');self.assertEqual(env['QT_QPA_PLATFORM'],'offscreen')
        env={};prepare_desktop_environment(env,[],platform='posix');self.assertFalse(env)

if __name__=='__main__':unittest.main()
