#!/usr/bin/env python3
"""Run only after DAY8 work; verify current state without changing clusters."""
import subprocess,sys,yaml
from day9_common import kj,ROOT
for ctx,names in [('ota-a',{'cp-a','worker-a1'}),('ota-b',{'cp-b','worker-b1','worker-b2'})]:
 nodes=kj(ctx,'get','nodes')['items']; assert {n['metadata']['name'] for n in nodes}==names
 for n in nodes:
  c={x['type']:x['status'] for x in n['status']['conditions']}
  assert c.get('Ready')=='True' and not any(c.get(x)=='True' for x in ['MemoryPressure','DiskPressure','PIDPressure']),n['metadata']['name']
 for d in ['prometheus-server','prometheus-kube-state-metrics']:
  obj=kj(ctx,'-n','monitoring','get','deployment',d); assert obj['status'].get('readyReplicas')==1,(ctx,d)
 cm=kj(ctx,'-n','monitoring','get','configmap','prometheus-server')
 cfg=yaml.safe_load(cm['data']['prometheus.yml']); jobs={j['job_name']:j for j in cfg['scrape_configs']}
 for j in ['kubernetes-nodes','kubernetes-nodes-cadvisor']:
  assert jobs[j]['tls_config'].get('insecure_skip_verify') is True, 'DAY8 option (a) differs: inspect before continuing'
 assert 'kubernetes-api-servers' not in jobs
 sa=kj(ctx,'-n','monitoring','get','deployment','prometheus-server')['spec']['template']['spec']['serviceAccountName']
 r=subprocess.run(['kubectl','--context',ctx,'auth','can-i','get','nodes','--subresource=proxy','--as=system:serviceaccount:monitoring:'+sa],capture_output=True,text=True)
 assert r.stdout.strip()=='no' and r.returncode==1,'Unexpected nodes/proxy permission or failed RBAC lookup'
 print(ctx,'Node health / DAY8 option (a) / no nodes/proxy: PASS')
 for ns in (['ci','staging'] if ctx=='ota-a' else []): assert not kj(ctx,'-n',ns,'get','pods')['items'],ns+' must be empty'
 subprocess.run([sys.executable,str(ROOT/'scripts/prom-check.py'),ctx[-1],'01-prom-'+ctx[-1]],check=True)
subprocess.run([sys.executable,str(ROOT/'scripts/demo-check.py'),'production','C','01-production'],check=True)
assert kj('ota-a','-n','monitoring','get','deployment','grafana')['status'].get('readyReplicas')==1
print('RESULT=PASS')
