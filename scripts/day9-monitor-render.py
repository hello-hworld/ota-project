#!/usr/bin/env python3
"""Render the chosen DAY8 (a) values plus one Host job, preserving the original jobs/RBAC."""
import json, subprocess, yaml
from day9_common import ROOT, EV, run

chart=ROOT/'helm/monitoring/chart/prometheus-29.37.0.tgz'
base=ROOT/'helm/monitoring/prometheus-a.yaml'
overlay=ROOT/'helm/monitoring/prometheus-host.yaml'
live=json.loads(run(['helm','--kube-context','ota-a','-n','monitoring','get','values','prometheus','-o','json']))
assert live==yaml.safe_load(base.read_text(encoding='utf-8')), 'Live user values differ from Git file: reconcile before upgrading'
assert not live.get('extraScrapeConfigs'), 'Extra jobs already exist; merge and review instead of replacing them'
subprocess.run(['helm','lint',str(chart),'-f',str(base),'-f',str(overlay),'--kube-version','1.36.5'],check=True)
raw=run(['helm','template','prometheus',str(chart),'-n','monitoring','-f',str(base),'-f',str(overlay),'--kube-version','1.36.5'])
docs=[d for d in yaml.safe_load_all(raw) if d]
assert not any(d['kind']=='Secret' for d in docs)
cm=next(d for d in docs if d['kind']=='ConfigMap' and d['metadata']['name']=='prometheus-server')
cfg=yaml.safe_load(cm['data']['prometheus.yml']); jobs={j['job_name']:j for j in cfg['scrape_configs']}
assert set(jobs)=={'prometheus','kubernetes-nodes','kubernetes-nodes-cadvisor','kubernetes-service-endpoints','ota-host'}
for job in ['kubernetes-nodes','kubernetes-nodes-cadvisor']: assert jobs[job]['tls_config']['insecure_skip_verify'] is True
for d in docs:
    if d['kind']=='ClusterRole':
        for rule in d.get('rules',[]):
            assert not ({'nodes/proxy','secrets'} & set(rule.get('resources',[])))
with (EV/'before-prometheus-a-user-values.yaml').open('x',encoding='utf-8') as f: yaml.safe_dump(live,f,sort_keys=False)
with (EV/'prometheus-a-with-host-rendered.yaml').open('x',encoding='utf-8') as f: f.write(raw)
print('DAY8 option (a) and original four jobs preserved; one Host job added; no new nodes/proxy or Secret access')
print('RESULT=PASS')
