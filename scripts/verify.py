#!/usr/bin/env python3
"""HTTPS model catalog and opt-in Chat smoke tests; never print tokens/bodies."""
import argparse
import json
import os
from pathlib import Path
import stat
import urllib.error
import urllib.parse
import urllib.request


def load_key(path):
    if path:
        s = path.stat()
        if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid() or s.st_mode & 0o077:
            raise ValueError('Key file must be owned by this user with mode 0600 or 0400')
        key = path.read_text().strip()
    else:
        key = os.environ.get('AI_GATEWAY_CLIENT_KEY', '').strip()
    if not key or '\n' in key or '\r' in key:
        raise ValueError('Provide a New API user key via environment or --key-file')
    return key


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--url', required=True, help='HTTPS OpenAI-compatible base URL ending in /v1')
    p.add_argument('--key-file', type=Path)
    p.add_argument('--model', action='append', default=[], help='Opt-in real inference; may consume quota')
    a = p.parse_args()
    parsed = urllib.parse.urlsplit(a.url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path.rstrip('/') != '/v1':
        print('Require an HTTPS base URL ending in /v1, without credentials/query/fragment')
        return 2
    try:
        key = load_key(a.key_file)
    except (OSError, ValueError):
        print('Missing or unsafe user key source; no credential values printed')
        return 2
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            # Do not forward the user token to a redirected endpoint/host.
            return None

    op = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    failures = 0
    cases = [('models', None)] + [('chat/completions', m) for m in a.model]
    for endpoint, model in cases:
        body = None if model is None else json.dumps({'model': model, 'messages': [{'role': 'user', 'content': 'Say hello in one short sentence.'}], 'max_tokens': 32, 'stream': False}).encode()
        req = urllib.request.Request(a.url.rstrip('/') + '/' + endpoint, data=body,
                                     headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
        result = {'endpoint': endpoint, 'model': model}
        try:
            with op.open(req, timeout=60) as response:
                d = json.load(response)
                valid = isinstance(d, dict) and (isinstance(d.get('data'), list) if model is None else bool(d.get('choices')))
                result.update(http=response.status, valid=valid)
                if model is None and valid:
                    result['model_count'] = len(d['data'])
                failures += not valid
        except urllib.error.HTTPError as e:
            result.update(http=e.code, valid=False)
            failures += 1
        except Exception as e:
            result.update(http=0, valid=False, error_type=type(e).__name__)
            failures += 1
        print(json.dumps(result, ensure_ascii=False))
    return int(bool(failures))


if __name__ == '__main__':
    raise SystemExit(main())
