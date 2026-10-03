import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / 'scripts/deploy.py'
spec = importlib.util.spec_from_file_location('deploy', path)
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


class SelectionTests(unittest.TestCase):
    def manifest(self, mode, enabled=False):
        return {'kind': 'PersonalAIAggregator', 'spec': {'enabled': enabled,
                'gateway': {'entry_mode': 'direct-new-api' if mode == 'direct-new-api' else 'gateway',
                            'adapter': mode, 'client_token_source': 'new-api'}}}

    def test_all_plan_modes(self):
        for mode in ['direct-new-api', 'apisix', 'kong']:
            deploy.validate_selection(self.manifest(mode), mode, 'plan', False)

    def test_mismatched_adapter(self):
        with self.assertRaises(ValueError):
            deploy.validate_selection(self.manifest('apisix'), 'kong', 'plan', False)

    def test_change_requires_approval_and_enabled(self):
        for enabled, approved in [(False, True), (True, False)]:
            with self.assertRaises(ValueError):
                deploy.validate_selection(self.manifest('apisix', enabled), 'apisix', 'stage', approved)

    def test_kong_changes_blocked(self):
        for op in ['stage', 'activate']:
            with self.assertRaises(ValueError):
                deploy.validate_selection(self.manifest('kong', True), 'kong', op, True)

    def test_new_api_identity_required(self):
        m = self.manifest('apisix');m['spec']['gateway']['client_token_source'] = 'bootstrap'
        with self.assertRaises(ValueError):
            deploy.validate_selection(m, 'apisix', 'plan', False)


if __name__ == '__main__':
    unittest.main()
