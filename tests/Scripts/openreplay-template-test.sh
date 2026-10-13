#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Compose validates and expands the template without contacting a Docker daemon.
# Coolify removes exclude_from_hc before passing the file to Compose.
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

root = Path(sys.argv[1])
template = root / 'templates/compose/openreplay.yaml'
assert template.is_file(), 'OpenReplay template is missing'
source = template.read_text()
assert source.startswith('# ignore: true\n'), 'Manual ECR setup must not be advertised as one-click'
assert ET.parse(root / 'public/svgs/openreplay.svg').getroot().tag.endswith('svg')

env = {**os.environ, 'SERVICE_URL_OPENREPLAY': 'https://replay.example.test'}
for key in ['POSTGRES', 'S3', '64_JWT', '64_JWTREFRESH', '64_JWTSPOT',
            '64_JWTSPOTREFRESH', '64_TOKEN', '64_ASSISTJWT', '64_ASSISTKEY',
            '64_SCIMACCESS', '64_SCIMREFRESH']:
    env['SERVICE_PASSWORD_' + key] = key.replace('_', '') + 'TestSecret123'
env['SERVICE_USER_S3'] = 'replayTestKey'

with tempfile.TemporaryDirectory() as directory:
    compose = Path(directory) / 'compose.yaml'
    compose.write_text('\n'.join(line for line in source.splitlines()
                                 if not line.strip().startswith('exclude_from_hc:')) + '\n')
    command = ['docker', 'compose', '--env-file', '/dev/null', '-f', str(compose),
               'config', '--format', 'json']
    result = subprocess.run(command, env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert not result.stderr, result.stderr
    config = json.loads(result.stdout)

services = config['services']
gateway = services['openreplay']
assert 'caddy' not in services
assert gateway['environment']['SERVICE_URL_OPENREPLAY'] == env['SERVICE_URL_OPENREPLAY']
assert gateway['expose'] == ['80']

for name, service in services.items():
    assert 'ports' not in service, f'{name} must not publish host ports'
    assert 'container_name' not in service, f'{name} must allow multiple deployments'
    assert 'env_file' not in service, f'{name} requires an external environment file'
    assert 'profiles' not in service, f'{name} would be skipped during normal deployment'
    assert ':latest' not in service['image'], f'{name} uses a floating latest tag'
    for volume in service.get('volumes', []):
        assert volume['type'] == 'volume', f'{name} requires an external host file'
    for dependency in service.get('depends_on', {}):
        assert dependency in services, f'{name} depends on a missing service'

# The actual Compose dependency graph must start setup before databases, then
# finish migrations before any application service can access the schemas.
def depends_on(name, dependency, visited=None):
    visited = set() if visited is None else visited
    assert name not in visited, f'Cycle in startup dependencies at {name}'
    children = services[name].get('depends_on', {})
    return dependency in children or any(depends_on(child, dependency, visited | {name})
                                         for child in children)

for database in ['postgresql', 'minio']:
    assert services[database]['depends_on']['setup']['condition'] == 'service_completed_successfully'
for name, service in services.items():
    if service['image'].startswith('public.ecr.aws/p1t3u8a3/'):
        for migration in ['db-migration', 'clickhouse-migration', 'minio-migration']:
            assert service['depends_on'][migration]['condition'] == 'service_completed_successfully'
        assert depends_on(name, 'setup')
        assert service['image'].endswith(':v1.28.0')
assert depends_on('openreplay', 'db-migration')
assert depends_on('openreplay', 'clickhouse-migration')
assert '-v ON_ERROR_STOP=1' in ' '.join(services['db-migration']['entrypoint'])

# Run the template's real shell entrypoints with failing external commands.
# A download error or a failed migration must block dependent services.
with tempfile.TemporaryDirectory() as directory:
    sandbox = Path(directory)
    commands = sandbox / 'bin'
    commands.mkdir()
    (sandbox / 'setup').mkdir()
    (sandbox / 'setup/init_ch_schema.sql').touch()
    for executable, code in [('wget', 41), ('mc', 42), ('psql', 43), ('clickhouse-client', 44)]:
        stub = commands / executable
        stub.write_text(f'#!/bin/sh\nexit {code}\n')
        stub.chmod(0o755)
    process_env = {**env, 'PATH': str(commands) + ':' + env.get('PATH', '')}
    for name, code in [('setup', 41), ('minio-migration', 42),
                       ('db-migration', 43), ('clickhouse-migration', 44)]:
        entrypoint = list(services[name]['entrypoint'])
        entrypoint[-1] = (entrypoint[-1].replace('$$', '$')
                          .replace('/setup', str(sandbox / 'setup'))
                          .replace('/mnt', str(sandbox / 'mnt')))
        result = subprocess.run(entrypoint, env=process_env, text=True, capture_output=True)
        assert result.returncode == code, f'{name} swallowed a setup/migration failure: {result.stderr}'

    # Successful HTTP responses containing the wrong files must also block startup.
    (commands / 'wget').write_text('#!/bin/sh\nprintf corrupt > "$3"\n')
    marker = sandbox / 'permissions-changed'
    chown = commands / 'chown'
    chown.write_text(f'#!/bin/sh\ntouch "{marker}"\n')
    chown.chmod(0o755)
    entrypoint = list(services['setup']['entrypoint'])
    entrypoint[-1] = entrypoint[-1].replace('/setup', str(sandbox / 'setup'))
    result = subprocess.run(entrypoint, env=process_env, text=True, capture_output=True)
    assert result.returncode != 0 and 'FAILED' in result.stdout, 'Corrupt setup files were accepted'
    assert not marker.exists(), 'Setup modified data permissions before verifying downloads'

api = services['api-openreplay']['environment']
chalice = services['chalice-openreplay']['environment']
assert api['JWT_SECRET'] == chalice['JWT_SECRET'] == env['SERVICE_PASSWORD_64_JWT']
assert api['pg_password'] == services['postgresql']['environment']['POSTGRESQL_PASSWORD']
assert api['AWS_ACCESS_KEY_ID'] == services['minio']['environment']['RUSTFS_ACCESS_KEY']
assert api['AWS_SECRET_ACCESS_KEY'] == services['minio']['environment']['RUSTFS_SECRET_KEY']
assert api['TOKEN_SECRET'] == services['http-openreplay']['environment']['TOKEN_SECRET']
assert api['AWS_ENDPOINT'] == chalice['SITE_URL'] == env['SERVICE_URL_OPENREPLAY']
assert services['frontend-openreplay']['environment']['TRACKER_HOST'] == env['SERVICE_URL_OPENREPLAY'] + '/script'

# Missing critical credentials must fail before any containers are started.
missing = {**env, 'SERVICE_PASSWORD_POSTGRES': ''}
with tempfile.TemporaryDirectory() as directory:
    compose = Path(directory) / 'compose.yaml'
    compose.write_text('\n'.join(line for line in source.splitlines()
                                 if not line.strip().startswith('exclude_from_hc:')) + '\n')
    result = subprocess.run(['docker', 'compose', '--env-file', '/dev/null', '-f', str(compose),
                             'config', '--quiet'], env=missing, text=True, capture_output=True)
    assert result.returncode != 0, 'Empty database credentials must fail validation'

print('PASS: Compose validation, isolated storage/routing, startup/migration failures, shared secrets, missing credentials, SVG')
PY
