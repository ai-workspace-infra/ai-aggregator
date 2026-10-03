#!/usr/bin/env python3
"""Install/stage canonical service configuration; activation is separate."""
import sys
from deploy import main

if __name__ == '__main__':
    if any(argument == '--operation' or argument.startswith('--operation=') for argument in sys.argv[1:]):
        print('Service installer only stages; use ai-aggregator-deploy for plan/activate.', file=sys.stderr)
        raise SystemExit(2)
    sys.argv.extend(['--operation', 'stage'])
    raise SystemExit(main())
