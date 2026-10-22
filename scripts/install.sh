#!/bin/sh
# curl bootstrap: installs tools only, never services or credentials.
set +x
set -eu
command -v python3 >/dev/null 2>&1 || {
    echo 'Python 3.10+ with venv is required; no system packages were changed.' >&2
    exit 2
}
python3 - "$@" <<'PYTHON'
import argparse
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request

REPOSITORY = 'ai-workspace-infra/ai-aggregator'
MAX_ARCHIVE = 20 * 1024 * 1024


class GitHubRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urllib.parse.urlsplit(newurl)
        if parsed.scheme != 'https' or parsed.hostname not in {'api.github.com', 'codeload.github.com'}:
            raise ValueError('Unexpected archive redirect')
        request = super().redirect_request(req, fp, code, msg, headers, newurl)
        if request is not None and parsed.hostname != 'api.github.com':
            request.remove_header('Authorization')
        return request


def safe_extract(data, destination):
    # A deployment archive must contain only directories and regular files.
    # Refuse symlink/hardlink traversal rather than trusting tar metadata.
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        members = archive.getmembers()
        roots = {m.name.split('/')[0] for m in members}
        if len(roots) != 1:
            raise ValueError('Unexpected archive layout')
        total = 0
        for member in members:
            parts = member.name.split('/')[1:]
            if any(p in {'.', '..'} for p in parts) or member.name.startswith('/'):
                raise ValueError('Unsafe archive path')
            if not (member.isdir() or member.isfile()):
                raise ValueError('Archive links and special files are forbidden')
            if not parts or not any(parts):
                continue
            target = destination.joinpath(*parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True, mode=0o700)
            else:
                total += member.size
                if total > MAX_ARCHIVE:
                    raise ValueError('Archive exceeds extraction limit')
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with archive.extractfile(member) as source, target.open('xb') as out:
                    shutil.copyfileobj(source, out)
                target.chmod(0o600)


def authenticate():
    token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    if not token:
        # Capture stdout in memory; never print or save the token.
        token = subprocess.check_output(['gh', 'auth', 'token'], stderr=subprocess.DEVNULL, text=True).strip()
    if not token or any(c in token for c in '\r\n'):
        raise ValueError('Missing GitHub credentials')
    return token


def install(ref, prefix):
    if not re.fullmatch(r'[0-9a-f]{40}', ref):
        raise ValueError('--ref must be a full immutable lowercase commit SHA')
    token = authenticate()
    prefix = prefix.expanduser().absolute()
    prefix.mkdir(parents=True, exist_ok=True, mode=0o700)
    release = prefix / 'releases' / ref
    if release.exists() or release.is_symlink():
        raise ValueError('Release already exists; nothing was overwritten')
    release.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    staging = Path(tempfile.mkdtemp(prefix='.install-', dir=prefix))
    try:
        req = urllib.request.Request(
            f'https://api.github.com/repos/{REPOSITORY}/tarball/{ref}',
            headers={'Authorization': 'Bearer ' + token, 'User-Agent': 'ai-aggregator-installer',
                     'Accept': 'application/vnd.github+json'})
        opener = urllib.request.build_opener(GitHubRedirect())
        with opener.open(req, timeout=60) as response:
            data = response.read(MAX_ARCHIVE + 1)
        if len(data) > MAX_ARCHIVE:
            raise ValueError('Archive exceeds download limit')
        safe_extract(data, staging)
        for required in ['requirements.txt', 'dependencies.lock.json', 'controller-collections.yml',
                         'scripts/deploy.py', 'scripts/verify.py', 'scripts/bootstrap.py', 'scripts/install_services.py']:
            if not (staging / required).is_file():
                raise ValueError('Missing installation files')
        # Create the venv at its final path: moving a venv breaks its shebangs.
        staging.rename(release)
        environment = dict(os.environ)
        for name in ['GH_TOKEN', 'GITHUB_TOKEN', 'VAULT_TOKEN', 'AI_GATEWAY_CLIENT_KEY']:
            environment.pop(name, None)
        # Log only sanitized status: pip configuration may contain credentials.
        for command in [
            [sys.executable, '-m', 'venv', str(release / '.venv')],
            [str(release / '.venv/bin/python'), '-m', 'pip', 'install', '--disable-pip-version-check', '-r', str(release / 'requirements.txt')],
        ]:
            subprocess.run(command, check=True, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        (release / 'installation.json').write_text(json.dumps({'repository': REPOSITORY, 'revision': ref}) + '\n')
        bindir = prefix / 'bin'
        bindir.mkdir(exist_ok=True, mode=0o700)
        for name, script in [('ai-aggregator-deploy', 'deploy.py'), ('ai-aggregator-verify', 'verify.py'),
                             ('ai-aggregator-bootstrap', 'bootstrap.py'), ('ai-aggregator-install', 'install_services.py')]:
            # Shell-quote paths; the wrapper contains no credentials.
            import shlex
            wrapper = f'#!/bin/sh\nexec {shlex.quote(str(release / ".venv/bin/python"))} {shlex.quote(str(release / "scripts" / script))} "$@"\n'
            candidate = bindir / (name + '.candidate')
            candidate.write_text(wrapper)
            candidate.chmod(0o700)
            candidate.replace(bindir / name)
        print('Installed deployment and verification tools at: ' + str(prefix))
        print('Revision: ' + ref)
        print('Add to PATH: ' + str(bindir))
        print('No services, DNS, cloud resources, Vault records, or shell profiles were changed.')
    finally:
        # Only remove the unique directory created by this invocation.
        # A failed final release is kept for inspection, never recursively erased.
        if staging.exists():
            shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description='Install AI Aggregator tools, not server services')
    parser.add_argument('--ref', required=True, help='Full immutable repository commit SHA')
    parser.add_argument('--prefix', type=Path, default=Path.home() / '.local/share/ai-aggregator')
    args = parser.parse_args()
    if sys.version_info < (3, 10):
        print('Python 3.10+ is required', file=sys.stderr)
        return 2
    os.umask(0o077)
    try:
        install(args.ref, args.prefix)
        return 0
    except Exception:
        # Exceptions and HTTP URLs can contain credentials. Do not print them.
        print('Installation failed: check SHA, GitHub read access, Python venv/pip and connectivity. No secret values printed.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
PYTHON
