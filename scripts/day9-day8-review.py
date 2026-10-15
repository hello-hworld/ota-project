#!/usr/bin/env python3
"""Read-only DAY8 follow-up: three lints, current TSDB, permissions and Grafana usage."""
import json,time,subprocess
from day9_common import ROOT,run,kj,prom,query,save

def main():
    mon=ROOT/'helm/monitoring'
    for release,chart,values in [('prometheus','prometheus-29.37.0.tgz','prometheus-a.yaml'),
                                  ('prometheus','prometheus-29.37.0.tgz','prometheus-b.yaml'),
                                  ('grafana','grafana-13.6.0.tgz','grafana.yaml')]:
        print('LINT',values,flush=True)
        subprocess.run(['helm','lint',str(mon/'chart'/chart),'-f',str(mon/values),
                        '--kube-version','1.36.5'],check=True)
    data={'time':time.time(),'clusters':{}}
    for ctx in ['ota-a','ota-b']:
        d=kj(ctx,'-n','monitoring','get','deployment','prometheus-server')
        c=next(x for x in d['spec']['template']['spec']['containers'] if x['name']=='prometheus-server')
        assert '--storage.tsdb.path=/data' in c['args'], 'Inspect changed TSDB path before continuing'
        result={'flags':prom(ctx,'/api/v1/status/flags'),
                'tsdb':prom(ctx,'/api/v1/status/tsdb'),
                'blockList':run(['kubectl','--context',ctx,'-n','monitoring','exec',
                   'deployment/prometheus-server','-c','prometheus-server','--','promtool','tsdb','list','/data']),
                'dataDirectory':run(['kubectl','--context',ctx,'-n','monitoring','exec',
                   'deployment/prometheus-server','-c','prometheus-server','--','du','-sk','/data'])}
        assert result['flags'].get('storage.tsdb.retention.time') in ['2d','48h']
        assert str(result['flags'].get('storage.tsdb.retention.size')) in ['3GiB','3GB','3221225472']
        sa=d['spec']['template']['spec']['serviceAccountName']
        rules=run(['kubectl','--context',ctx,'auth','can-i','--list',
                   '--as=system:serviceaccount:monitoring:'+sa])
        result['effectivePermissions']=rules
        data['clusters'][ctx]=result
        print(ctx,'retention=48h/3GiB',result['dataDirectory'].strip(),flush=True)
        print(result['blockList'],flush=True)
    data['grafana15mMaxWorkingSet']=query('ota-a',
        'max_over_time(container_memory_working_set_bytes{namespace="monitoring",container="grafana"}[15m])')
    path=save('day8-followup-'+str(time.time_ns())+'.json',data)
    print('Saved',path)
    print('RESULT=PASS (lint/current storage recorded; 48h retention deletion NOT proven)')

if __name__=='__main__': main()
