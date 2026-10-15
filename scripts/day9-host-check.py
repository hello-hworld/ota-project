#!/usr/bin/env python3
import time,json,socket,math
from day9_common import prom,query,ROOT,save
targets=[t for t in prom('ota-a','/api/v1/targets',state='active')['activeTargets'] if t['labels'].get('job')=='ota-host']
assert len(targets)==1 and targets[0]['health']=='up',targets
assert targets[0]['labels'].get('instance')=='ota-host' and targets[0]['labels'].get('scope')=='physical-host'
assert targets[0]['scrapeUrl'].startswith('http://192.168.56.1:19100/')
latest=query('ota-a','timestamp(node_uname_info{job="ota-host"})')
assert len(latest)==1 and -5<=time.time()-float(latest[0]['value'][1])<90
identity=query('ota-a','node_uname_info{job="ota-host"}')
assert len(identity)==1 and identity[0]['metric'].get('nodename')==socket.gethostname(), 'Target hostname differs from this physical Host'
data=[]
dash=json.loads((ROOT/'helm/monitoring/dashboards/ota-host-overview.json').read_text())
for p in dash['panels']:
 q=p['targets'][0]['expr']; result=query('ota-a',q); assert result,(p['title'],'no samples')
 assert all(math.isfinite(float(x['value'][1])) for x in result),(p['title'],'non-finite samples')
 data.append({'title':p['title'],'query':q,'result':result})
save('host-check-'+str(int(time.time()))+'.json',{'target':targets,'panels':data})
print('Host target UP, correct physical endpoint, all panel samples present')
print('RESULT=PASS')
