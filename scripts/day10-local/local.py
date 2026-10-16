#!/usr/bin/env python3
"""Day10 local PostgreSQL preparation; no AWS operations."""
import argparse, base64, hashlib, json, pathlib, re, secrets, subprocess, sys, urllib.request

OWNER = {'app.kubernetes.io/managed-by': 'day10-infra'}
ENVIRONMENTS = {'staging': ('ota-a', 'ota-data-staging', 'worker-a1', 'staging'),
                'production': ('ota-b', 'ota-data-production', 'worker-b2', 'production')}

def save(path, value, private=False):
    p = pathlib.Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    content = value if isinstance(value, str) else json.dumps(value, indent=2) + '\n'
    if p.exists():
        if p.read_text(encoding='utf-8') != content:
            raise ValueError('refusing to overwrite a different file: ' + str(p))
    else:
        with p.open('x', encoding='utf-8') as handle:
            handle.write(content)
    if private:
        p.chmod(0o600)

def image(lock):
    data = json.loads(pathlib.Path(lock).read_text(encoding='utf-8'))
    if data.get('major') != 17 or data.get('source_tag') != 'docker.io/library/postgres:17-bookworm':
        raise ValueError('this PGDATA layout requires the PostgreSQL 17-bookworm lock')
    if not re.fullmatch(r'docker\.io/library/postgres@sha256:[0-9a-f]{64}', data.get('image', '')):
        raise ValueError('pinned official image required')
    return data['image']

def metadata(name, namespace=None):
    m = {'name': name, 'labels': dict(OWNER)}
    if namespace:
        m['namespace'] = namespace
    return m

def manifests(env, ref):
    _, ns, node, _ = ENVIRONMENTS[env]
    labels = {'app': 'postgres', 'ota-environment': env, **OWNER}
    ready = {'exec': {'command': ['pg_isready', '-h', '127.0.0.1', '-U', 'postgres', '-d', 'postgres']},
             'periodSeconds': 5, 'timeoutSeconds': 3}
    objects = [
        {'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': metadata(ns)},
        {'apiVersion': 'v1', 'kind': 'ServiceAccount', 'metadata': metadata('postgres', ns), 'automountServiceAccountToken': False},
        {'apiVersion': 'v1', 'kind': 'Service', 'metadata': metadata('postgres-headless', ns), 'spec': {'clusterIP': 'None', 'selector': labels, 'ports': [{'name': 'postgres', 'port': 5432}]}},
        {'apiVersion': 'v1', 'kind': 'Service', 'metadata': metadata('postgres', ns), 'spec': {'type': 'ClusterIP', 'selector': labels, 'ports': [{'name': 'postgres', 'port': 5432}]}},
        {'apiVersion': 'apps/v1', 'kind': 'StatefulSet', 'metadata': metadata('postgres', ns), 'spec': {'serviceName': 'postgres-headless', 'replicas': 1, 'selector': {'matchLabels': labels}, 'persistentVolumeClaimRetentionPolicy': {'whenDeleted': 'Retain', 'whenScaled': 'Retain'}, 'template': {'metadata': {'labels': labels}, 'spec': {'serviceAccountName': 'postgres', 'automountServiceAccountToken': False, 'terminationGracePeriodSeconds': 60, 'securityContext': {'runAsNonRoot': True, 'runAsUser': 999, 'runAsGroup': 999, 'fsGroup': 999, 'seccompProfile': {'type': 'RuntimeDefault'}}, 'affinity': {'nodeAffinity': {'requiredDuringSchedulingIgnoredDuringExecution': {'nodeSelectorTerms': [{'matchExpressions': [{'key': 'kubernetes.io/hostname', 'operator': 'In', 'values': [node]}]}]}}}, 'containers': [{'name': 'postgres', 'image': ref, 'imagePullPolicy': 'IfNotPresent', 'args': ['postgres', '-c', 'shared_buffers=64MB', '-c', 'max_connections=30'], 'env': [{'name': 'PGDATA', 'value': '/var/lib/postgresql/data/pgdata'}, {'name': 'POSTGRES_PASSWORD', 'valueFrom': {'secretKeyRef': {'name': 'postgres-admin', 'key': 'password'}}}], 'ports': [{'name': 'postgres', 'containerPort': 5432}], 'resources': {'requests': {'cpu': '250m', 'memory': '256Mi' if env == 'staging' else '512Mi'}, 'limits': {'cpu': '1', 'memory': '768Mi' if env == 'staging' else '1Gi'}}, 'securityContext': {'allowPrivilegeEscalation': False, 'capabilities': {'drop': ['ALL']}}, 'startupProbe': {**ready, 'failureThreshold': 36}, 'readinessProbe': {**ready, 'failureThreshold': 3}, 'livenessProbe': {**ready, 'periodSeconds': 10, 'failureThreshold': 6}, 'volumeMounts': [{'name': 'data', 'mountPath': '/var/lib/postgresql/data'}]}]}}, 'volumeClaimTemplates': [{'metadata': {'name': 'data', 'labels': dict(OWNER)}, 'spec': {'accessModes': ['ReadWriteOnce'], 'storageClassName': 'local-path', 'resources': {'requests': {'storage': '10Gi' if env == 'staging' else '20Gi'}}}}]}}
    ]
    return {'apiVersion': 'v1', 'kind': 'List', 'items': objects}

def credentials(directory):
    p = pathlib.Path(directory)
    p.mkdir(parents=True, exist_ok=True)
    p.chmod(0o700)
    for name in ['postgres-admin.password', 'ota-app.password']:
        target = p / name
        if not target.exists():
            save(target, secrets.token_urlsafe(32), private=True)
        if not re.fullmatch(r'[A-Za-z0-9_-]{40,}', target.read_text()):
            raise ValueError('unexpected password file format')
        target.chmod(0o600)
    password = (p / 'ota-app.password').read_text()
    sql = f"\\set ON_ERROR_STOP on\nSELECT 'CREATE ROLE ota_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD ' || quote_literal('{password}') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='ota_app') \\gexec\nSELECT 'CREATE DATABASE ota OWNER ota_app' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='ota') \\gexec\n"
    save(p / 'bootstrap.sql', sql, private=True)
    print('Private credentials/bootstrap SQL prepared; existing values preserved')

def put_secret(ctx, ns, name, values):
    cmd = ['kubectl', '--context', ctx, '-n', ns]
    result = subprocess.run(cmd + ['get', 'secret', name, '--ignore-not-found', '-o', 'json'], capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError('Secret lookup failed; inspect context/namespace/RBAC separately')
    encoded = {k: base64.b64encode(v.encode()).decode() for k, v in values.items()}
    if result.stdout.strip():
        old = json.loads(result.stdout)
        if old.get('metadata', {}).get('labels', {}).get('app.kubernetes.io/managed-by') != 'day10-infra' or old.get('data') != encoded:
            raise ValueError('existing Secret differs; refusing overwrite')
        print('Secret exists and matches (values omitted)')
        return
    body = {'apiVersion': 'v1', 'kind': 'Secret', 'type': 'Opaque', 'metadata': metadata(name, ns), 'data': encoded}
    result = subprocess.run(cmd + ['create', '-f', '-'], input=json.dumps(body), capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError('Secret creation failed; values omitted')
    print('Secret created (values omitted): ' + ns + '/' + name)

def job(name, image_ref, container):
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,62}', name):
        raise ValueError('invalid Job name')
    container = {'name': 'probe', 'image': image_ref, 'resources': {'requests': {'cpu': '50m', 'memory': '64Mi'}, 'limits': {'cpu': '250m', 'memory': '128Mi'}}, 'securityContext': {'allowPrivilegeEscalation': False, 'capabilities': {'drop': ['ALL']}}, **container}
    return {'apiVersion': 'batch/v1', 'kind': 'Job', 'metadata': metadata(name, 'staging'), 'spec': {'backoffLimit': 0, 'activeDeadlineSeconds': 120, 'ttlSecondsAfterFinished': 3600, 'template': {'metadata': {'labels': dict(OWNER)}, 'spec': {'automountServiceAccountToken': False, 'restartPolicy': 'Never', 'securityContext': {'runAsNonRoot': True, 'runAsUser': 999, 'runAsGroup': 999, 'seccompProfile': {'type': 'RuntimeDefault'}}, 'containers': [container]}}}}

def pg_job(run, mode, ref):
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,31}', run):
        raise ValueError('invalid run ID')
    if mode == 'write':
        sql = f"CREATE SCHEMA IF NOT EXISTS infra_smoke; CREATE TABLE IF NOT EXISTS infra_smoke.checks (run_id text PRIMARY KEY); INSERT INTO infra_smoke.checks VALUES ('{run}') ON CONFLICT DO NOTHING;"
    else:
        sql = ''
    sql += f"SELECT 1 / count(*)::int AS sentinel_present FROM infra_smoke.checks WHERE run_id='{run}';"
    return job('d10-' + run + '-' + mode, ref, {'envFrom': [{'secretRef': {'name': 'ota-db'}}], 'command': ['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-c', sql]})

def resolve():
    token_url = 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/postgres:pull'
    with urllib.request.urlopen(token_url, timeout=30) as response:
        token = json.load(response)['token']
    request = urllib.request.Request('https://registry-1.docker.io/v2/library/postgres/manifests/17-bookworm', headers={'Authorization': 'Bearer ' + token, 'Accept': ', '.join(['application/vnd.oci.image.index.v1+json', 'application/vnd.docker.distribution.manifest.list.v2+json', 'application/vnd.oci.image.manifest.v1+json', 'application/vnd.docker.distribution.manifest.v2+json'])})
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read()
        reported = response.headers.get('Docker-Content-Digest')
        digest = 'sha256:' + hashlib.sha256(body).hexdigest()
        if reported != digest:
            raise ValueError('manifest digest/header mismatch')
        return {'source_tag': 'docker.io/library/postgres:17-bookworm', 'major': 17, 'image': 'docker.io/library/postgres@' + digest, 'digest': digest, 'manifest': json.loads(body)}

def lookup(kind, name, namespace=None):
    command = ['kubectl', '--context', 'ota-a']
    if namespace:
        command += ['-n', namespace]
    result = subprocess.run(command + ['get', kind, name, '--ignore-not-found', '-o', 'json'], capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError('lookup failed; inspect context/namespace/RBAC: ' + kind + '/' + name)
    return json.loads(result.stdout) if result.stdout.strip() else None

def guard(private, lock):
    ns = lookup('namespace', 'ota-data-staging')
    if ns is None:
        print('NEW_NAMESPACE_ALLOWED')
        return
    if ns.get('metadata', {}).get('labels', {}).get('app.kubernetes.io/managed-by') != 'day10-infra':
        raise ValueError('unknown namespace owner; do not inspect or adopt its resources')
    objects = [ns]
    for kind, name in [('secret', 'postgres-admin'), ('statefulset', 'postgres'), ('pvc', 'data-postgres-0')]:
        obj = lookup(kind, name, 'ota-data-staging')
        if obj:
            objects.append(obj)
    for obj in objects:
        if obj.get('metadata', {}).get('labels', {}).get('app.kubernetes.io/managed-by') != 'day10-infra':
            raise ValueError('unknown owner; do not adopt existing namespace/resources')
    if len(objects) > 1:
        for name in ['postgres-admin.password', 'ota-app.password']:
            if not pathlib.Path(private, name).is_file():
                raise ValueError('existing DB resources found; select the original run/private files')
        for obj in objects:
            if obj.get('kind') == 'StatefulSet':
                if not pathlib.Path(lock).is_file():
                    raise ValueError('existing DB requires its original image lock before resume')
                container = next(c for c in obj['spec']['template']['spec']['containers'] if c['name'] == 'postgres')
                if container['image'] != image(lock):
                    raise ValueError('existing DB image differs; refusing unverified image change')
    print('EXISTING_NAMESPACE_CHECKED')

def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='action', required=True)
    
    g = sub.add_parser('guard')
    g.add_argument('--private', required=True)
    g.add_argument('--lock', required=True)
    
    r = sub.add_parser('resolve-image')
    r.add_argument('--out', required=True)
    
    m = sub.add_parser('render-pg')
    m.add_argument('--env', choices=ENVIRONMENTS, required=True)
    m.add_argument('--lock', required=True)
    m.add_argument('--out', required=True)
    
    c = sub.add_parser('credentials')
    c.add_argument('--private', required=True)
    
    s = sub.add_parser('secret')
    s.add_argument('--kind', choices=['admin', 'app'], required=True)
    s.add_argument('--private', required=True)
    
    j = sub.add_parser('pg-job')
    j.add_argument('--run', required=True)
    j.add_argument('--mode', choices=['write', 'check', 'restore'], required=True)
    j.add_argument('--database')
    j.add_argument('--lock', required=True)
    j.add_argument('--out', required=True)
    
    args = parser.parse_args()

    if args.action == 'guard':
        guard(args.private, args.lock)
    elif args.action == 'resolve-image':
        if pathlib.Path(args.out).exists():
            print('IMAGE_LOCK_REUSED ' + image(args.out))
        else:
            save(args.out, resolve())
            print('IMAGE_LOCK_CREATED ' + image(args.out))
    elif args.action == 'render-pg':
        save(args.out, manifests(args.env, image(args.lock)))
        print('MANIFEST_PREPARED ' + args.env)
    elif args.action == 'credentials':
        credentials(args.private)
    elif args.action == 'secret':
        private = pathlib.Path(args.private)
        if args.kind == 'admin':
            put_secret('ota-a', 'ota-data-staging', 'postgres-admin', {'password': (private / 'postgres-admin.password').read_text()})
        else:
            put_secret('ota-a', 'staging', 'ota-db', {'PGHOST': 'postgres.ota-data-staging.svc.cluster.local', 'PGPORT': '5432', 'PGDATABASE': 'ota', 'PGUSER': 'ota_app', 'PGPASSWORD': (private / 'ota-app.password').read_text()})
    elif args.action == 'pg-job':
        if args.mode == 'restore':
            if not args.database or not re.fullmatch(r'restore_d10_[0-9]{14}', args.database):
                raise ValueError('restore mode requires the separate restore_d10_TIMESTAMP database')
        elif args.database:
            raise ValueError('database override is only accepted for the restore check')
        data = pg_job(args.run, args.mode, image(args.lock))
        container = data['spec']['template']['spec']['containers'][0]
        container['command'][-1] = 'SELECT current_database() AS database, current_user AS role; ' + container['command'][-1]
        container['env'] = [{'name': 'PGCONNECT_TIMEOUT', 'value': '10'}]
        if args.mode == 'restore':
            container['env'].append({'name': 'PGDATABASE', 'value': args.database})
        save(args.out, data)
        print('PROBE_PREPARED ' + args.mode)

if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('STOP: ' + str(exc), file=sys.stderr)
        sys.exit(1)
