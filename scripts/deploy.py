#!/usr/bin/env python3
"""Thin, fail-closed entrypoint; canonical roles remain in playbooks."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import yaml

ROOT = Path(__file__).resolve().parents[1]


def validate_selection(manifest, mode, operation, approved):
    if manifest.get('kind') != 'PersonalAIAggregator':
        raise ValueError('Require a complete PersonalAIAggregator manifest')
    spec = manifest.get('spec', {})
    gateway = spec.get('gateway', {})
    expected = 'direct-new-api' if mode == 'direct-new-api' else 'gateway'
    if gateway.get('entry_mode') != expected:
        raise ValueError('Manifest entry_mode does not match the requested mode')
    if mode != 'direct-new-api' and gateway.get('adapter') != mode:
        raise ValueError('Manifest adapter does not match the requested mode')
    if gateway.get('client_token_source') != 'new-api':
        raise ValueError('New API must be the user token source of truth')
    if mode == 'kong' and operation != 'plan':
        raise ValueError('Kong automatic stage/activate is blocked until the legacy role is migrated')
    if operation != 'plan' and (not approved or spec.get('enabled') is not True):
        raise ValueError('Changes require --approve-change and enabled: true in GitOps')


def main():
    p = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    p.add_argument('--mode', choices=['direct-new-api', 'apisix', 'kong'], required=True)
    p.add_argument('--operation', choices=['plan', 'stage', 'activate'], default='plan')
    p.add_argument('--manifest', type=Path, required=True)
    p.add_argument('--inventory', type=Path, required=True)
    p.add_argument('--playbooks', type=Path, required=True)
    p.add_argument('--approve-change', action='store_true')
    p.add_argument('--syntax-check', action='store_true')
    p.add_argument('--apisix-bundle-dir', type=Path, help='Non-sensitive rendered config.yaml/apisix.yaml directory')
    p.add_argument('--vault-tls-runtime', action='store_true', help='Use the existing Vault TLS runtime contract')
    a = p.parse_args()
    try:
        # Never print parser errors: they may contain a source line with secrets.
        manifest = yaml.safe_load(a.manifest.read_text())
        validate_selection(manifest, a.mode, a.operation, a.approve_change)
        if not a.inventory.is_file():
            raise ValueError('Inventory file is missing')
        lock = json.loads((ROOT / 'dependencies.lock.json').read_text())
        revision = subprocess.check_output(['git', '-C', str(a.playbooks), 'rev-parse', 'HEAD'], text=True).strip()
        dirty = subprocess.check_output(['git', '-C', str(a.playbooks), 'status', '--porcelain'], text=True)
        if revision != lock['playbooks']['revision'] or dirty:
            raise ValueError('Use a clean playbooks checkout at the locked revision')
        extra = {'ai_aggregator_manifest_file': str(a.manifest.resolve()),
                 'ai_aggregator_operation': a.operation}
        if a.apisix_bundle_dir:
            for name in ['config.yaml', 'apisix.yaml']:
                if not (a.apisix_bundle_dir / name).is_file():
                    raise ValueError('Rendered APISIX bundle is incomplete')
            extra['ai_aggregator_apisix_bundle_dir'] = str(a.apisix_bundle_dir.resolve())
        if a.mode == 'apisix' and a.operation == 'stage' and not a.apisix_bundle_dir:
            raise ValueError('APISIX stage requires --apisix-bundle-dir')
        if a.vault_tls_runtime:
            extra['ai_aggregator_vault_tls_runtime_enabled'] = True
        local_ansible = Path(sys.executable).parent / 'ansible-playbook'
        executable = str(local_ansible) if local_ansible.is_file() else 'ansible-playbook'
        command = [executable, '-i', str(a.inventory.resolve()),
                   'deploy_ai_aggregator.yaml', '-e', json.dumps(extra)]
        if a.syntax_check:
            command.append('--syntax-check')
        environment = dict(os.environ)
        collections = a.playbooks.resolve().parent / 'collections'
        if collections.is_dir():
            environment['ANSIBLE_COLLECTIONS_PATH'] = str(collections)
        return subprocess.call(command, cwd=a.playbooks, env=environment)
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 2
    except (OSError, yaml.YAMLError, subprocess.CalledProcessError, TypeError, AttributeError):
        print('Input or dependency check failed; no credentials were printed', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
