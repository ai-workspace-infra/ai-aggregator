#!/usr/bin/env python3
"""Prepare locked controller checkouts; never mutate nodes or Vault."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def quiet(command, **kwargs):
    return subprocess.check_output(command, stderr=subprocess.DEVNULL, **kwargs)


def checkout(name, dependency, workspace):
    destination = workspace / name
    revision = dependency['revision']
    url = dependency['repository']
    if not url.startswith('https://github.com/') or len(revision) != 40:
        raise ValueError('Invalid dependency lock')
    if destination.exists():
        head = quiet(['git', '-C', str(destination), 'rev-parse', 'HEAD'], text=True).strip()
        dirty = quiet(['git', '-C', str(destination), 'status', '--porcelain'], text=True)
        if head != revision or dirty:
            raise ValueError('Existing checkout is not clean at locked revision: ' + name)
        return destination
    # No token in URL/config/arguments: gh supplies credentials through Git's
    # helper protocol. Disable inherited credential helpers for this operation.
    temporary = Path(tempfile.mkdtemp(prefix='.' + name + '-', dir=workspace))
    try:
        quiet(['git', '-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential',
               'clone', '--no-checkout', url, str(temporary)])
        quiet(['git', '-C', str(temporary), 'checkout', '--detach', revision])
        head = quiet(['git', '-C', str(temporary), 'rev-parse', 'HEAD'], text=True).strip()
        if head != revision:
            raise ValueError('Dependency checkout does not match lock')
        temporary.rename(destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    return destination


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--workspace', type=Path, required=True, help='Dedicated controller dependency directory')
    p.add_argument('--install-ansible', action='store_true', help='Install Ansible in the current venv, not system Python')
    a = p.parse_args()
    try:
        for executable in ['git', 'gh']:
            if not shutil.which(executable):
                raise ValueError('Missing controller executable: ' + executable)
        if a.install_ansible:
            if sys.prefix == sys.base_prefix or not (3, 11) <= sys.version_info[:2] <= (3, 13):
                raise ValueError('--install-ansible requires a Python 3.11-3.13 venv; newer Python should use a separately supported Ansible installation')
            environment = dict(os.environ)
            for key in ['GH_TOKEN', 'GITHUB_TOKEN', 'VAULT_TOKEN', 'AI_GATEWAY_CLIENT_KEY']:
                environment.pop(key, None)
            subprocess.run([sys.executable, '-m', 'pip', 'install', '--disable-pip-version-check',
                            'ansible-core>=2.19,<2.20'], env=environment, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        workspace = a.workspace.expanduser().resolve()
        workspace.mkdir(parents=True, exist_ok=True, mode=0o700)
        lock = json.loads((ROOT / 'dependencies.lock.json').read_text())
        for name, dependency in lock.items():
            checkout(name, dependency, workspace)
            print('Prepared locked checkout: ' + name)
        # Roles use community.general and ansible.posix; collect dependencies
        # in a dedicated controller directory rather than changing global state.
        galaxy = Path(sys.executable).parent / 'ansible-galaxy'
        if not galaxy.is_file():
            discovered = shutil.which('ansible-galaxy')
            if not discovered:
                raise ValueError('Ansible is missing; rerun with --install-ansible in a Python 3.11+ venv')
            galaxy = Path(discovered)
        quiet([str(galaxy), 'collection', 'install', '-r', str(ROOT / 'controller-collections.yml'),
               '-p', str(workspace / 'collections')])
        print('Controller bootstrap complete. No target nodes or credentials were changed.')
        print('Collection path: ' + str(workspace / 'collections'))
        print('Next: install services with an explicit manifest/inventory and --approve-change.')
        return 0
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 2
    except Exception:
        print('Bootstrap failed; check GitHub access, dependencies and connectivity. No secrets printed.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
