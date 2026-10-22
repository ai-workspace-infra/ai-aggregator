import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

source = Path(__file__).resolve().parents[1] / 'scripts/bootstrap.py'
spec = importlib.util.spec_from_file_location('bootstrap', source)
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


class BootstrapTests(unittest.TestCase):
    dependency = {'repository': 'https://github.com/ai-workspace-infra/playbooks.git',
                  'revision': 'a' * 40}

    def test_dirty_checkout_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory);(workspace / 'playbooks').mkdir()
            with patch.object(bootstrap, 'quiet', side_effect=['a' * 40, ' M user-file']), self.assertRaises(ValueError):
                bootstrap.checkout('playbooks', self.dependency, workspace)
            self.assertTrue((workspace / 'playbooks').is_dir())

    def test_clean_locked_checkout_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory);(workspace / 'playbooks').mkdir()
            with patch.object(bootstrap, 'quiet', side_effect=['a' * 40, '']):
                self.assertEqual(bootstrap.checkout('playbooks', self.dependency, workspace), workspace / 'playbooks')

    def test_clone_uses_helper_without_token_in_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(bootstrap, 'quiet', side_effect=[b'', b'', 'a' * 40]) as quiet:
                bootstrap.checkout('playbooks', self.dependency, Path(directory))
                command = quiet.call_args_list[0].args[0]
                self.assertIn('credential.helper=!gh auth git-credential', command)
                self.assertIn(self.dependency['repository'], command)


if __name__ == '__main__':
    unittest.main()
