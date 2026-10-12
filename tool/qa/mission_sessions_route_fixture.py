"""Record synthetic SessionDB results from the real Dashboard route, not a mock.

Run with the reference checkout's Python environment:
  PYTHONDONTWRITEBYTECODE=1 python tool/qa/mission_sessions_route_fixture.py BACKEND

Only temporary synthetic databases are written. Output is a compact projection of
actual route fields consumed by the loader; no private profile data is accessed.
The checked-in fixture records the pre-fix 500-prefix contract, not desired behavior.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

backend = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(backend))
output = Path('test/fixtures/mission_sessions_capped_route.json')
with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as temporary:
    home = Path(temporary)
    os.environ['HERMES_HOME'] = str(home)
    from hermes_state import SessionDB
    from hermes_cli.web_routers import profiles

    scenarios = {}
    for name, counts, pinned in [
        ('single501', [501], False),
        ('single601', [601], False),
        ('mixed_capped_pinned', [601, 101], True),
        ('mixed_pin_recovers_boundary', [501, 101], True),
        ('mixed_complete_pinned', [301, 301], True),
    ]:
        targets = []
        for owner_index, count in enumerate(counts):
            owner = ['default', 'other'][owner_index]
            profile_home = home / name / owner
            profile_home.mkdir(parents=True)
            db = SessionDB(profile_home / 'state.db')
            for index in range(count):
                # Same physical IDs across owners deliberately test owner dedupe.
                with patch('time.time', return_value=100000 + index * 2 + owner_index):
                    db.create_session(f'session-{index}', 'cli')
            if pinned:
                db.set_session_pinned('session-0', True)
            db.close()
            targets.append((owner, profile_home))
        pages = []
        with patch.object(profiles, '_profile_targets', return_value=targets):
            for offset in range(0, sum(counts), 200):
                page = profiles.get_profiles_sessions(
                    limit=200, offset=offset, min_messages=0,
                    archived='exclude', order='recent', profile='all', full=True)
                assert not page['errors'], page['errors']
                pages.append({
                    **{key: page[key] for key in
                       ('limit', 'offset', 'total', 'profile_totals', 'errors')},
                    'sessions': [{key: row[key] for key in
                                  ('id', 'profile', 'pinned') if key in row}
                                 for row in page['sessions']],
                })
        scenarios[name] = {'counts': dict(zip([t[0] for t in targets], counts)), 'pages': pages}
        print(name, 'rows=', [len(p['sessions']) for p in pages], 'unique=',
              len({(r['profile'], r['id']) for p in pages for r in p['sessions']}))
    result = {
        'backend_head': subprocess.check_output(['git', '-C', str(backend), 'rev-parse', 'HEAD'], text=True).strip(),
        'route': 'hermes_cli.web_routers.profiles.get_profiles_sessions',
        'scenarios': scenarios,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, separators=(',', ':')) + '\n')
    print(output)
