#!/usr/bin/env python3
"""Read one manually triggered Jenkins build and verify its archived CI evidence."""
import base64, getpass, json, os, pathlib, re, sys, urllib.request

number = input('Jenkins day6-ci build number: ').strip()
if not number.isdigit():
    sys.exit('STOP: numeric build number required')
user = input('Jenkins username: ').strip()
token = getpass.getpass('Jenkins API token (not password; not saved): ')
auth = 'Basic ' + base64.b64encode((user + ':' + token).encode()).decode()
base = 'http://127.0.0.1:18080/job/day6-ci/' + number
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def get(path):
    req = urllib.request.Request(base + path, headers={'Authorization': auth})
    with opener.open(req, timeout=30) as response:
        return response.read()

build = json.loads(get('/api/json'))
if build.get('building') or build.get('result') != 'SUCCESS':
    sys.exit('STOP: build is running or not SUCCESS: ' + str(build.get('result')))
info = get('/artifact/out/build-info.txt').decode()
fields = dict(re.findall(r'^([a-z-]+)=(.*)$', info, re.M))
if fields.get('test-exit') != '0' or not fields.get('scan-exit', '').startswith('0 '):
    sys.exit('STOP: test/scan did not pass')
digest = fields.get('built-digest', '')
if not re.fullmatch(r'sha256:[a-f0-9]{64}', digest) or fields.get('pushed-digest') != digest:
    sys.exit('STOP: built/pushed digest mismatch or missing digest')
if not re.fullmatch(r'[a-f0-9]{40}', fields.get('commit', '')):
    sys.exit('STOP: source commit missing')
if not re.search(r'^job=day6-ci build=' + re.escape(number) + r'$', info, re.M):
    sys.exit('STOP: build-info job/build identity mismatch')
out = pathlib.Path(os.environ['EV']) / ('ci-' + number)
if out.exists():
    sys.exit('STOP: evidence directory already exists; preserve it and review before retrying')
out.mkdir()
(out / 'build-info.txt').write_text(info)
summary = {k: build.get(k) for k in ['number', 'result', 'timestamp', 'duration', 'url']}
(out / 'jenkins-result.json').write_text(json.dumps(summary, indent=2))
for name in ['test.log', 'trivy-report.txt', 'trivy-version.txt', 'image-ref.txt',
             'cgroup-jnlp.txt', 'cgroup-python.txt', 'cgroup-buildkit.txt',
             'cgroup-trivy.txt', 'cgroup-skopeo.txt']:
    (out / name).write_bytes(get('/artifact/out/' + name))
print('build=' + number, 'commit=' + fields['commit'], 'digest=' + digest)
print('RESULT=PASS')
