#!/usr/bin/env python3
"""Namespace policies managed by the platform administrator, separate from Argo app objects."""
import argparse, decimal, hashlib, json, math, subprocess, sys, time
import yaml
from day9_common import ROOT, EV, kj, run, save

CTX='ota-b'; NS='production'; OWNER='ota-day9'
FILE=ROOT/'k8s/policies/day9-production.yaml'
NAMES={'ResourceQuota':'ota-demo-budget','LimitRange':'ota-demo-defaults'}

def cpu(s):
    s=str(s); return decimal.Decimal(s[:-1])/1000 if s.endswith('m') else decimal.Decimal(s)

def mem(s):
    s=str(s)
    for unit,mult in [('Gi',2**30),('Mi',2**20),('Ki',2**10),('G',10**9),('M',10**6),('K',1000)]:
        if s.endswith(unit): return decimal.Decimal(s[:-len(unit)])*mult
    return decimal.Decimal(s)

def live_source():
    d=kj(CTX,'-n',NS,'get','deployment','ota-demo')
    assert d['spec']['replicas']==2 and d['status'].get('readyReplicas')==2
    assert d['status'].get('updatedReplicas')==2
    p=d['spec']['template']['spec']; cs=p['containers']
    assert len(cs)==1 and cs[0]['name']=='demo' and not p.get('initContainers') and not p.get('overhead') and not p.get('resources'), 'Recalculate for multi-container/Pod-level resources'
    r=cs[0]['resources']; assert all(k in r[t] for t in ['requests','limits'] for k in ['cpu','memory'])
    surge=d['spec']['strategy']['rollingUpdate']['maxSurge']
    surge=math.ceil(d['spec']['replicas']*int(surge[:-1])/100) if isinstance(surge,str) and surge.endswith('%') else int(surge)
    slots=d['spec']['replicas']+surge+1
    assert slots>=4
    pods=kj(CTX,'-n',NS,'get','pods')['items']
    for pod in pods:
        assert pod['metadata']['labels'].get('app.kubernetes.io/name')=='ota-demo', 'Other workloads in production: budget separately'
    signature={'uid':d['metadata']['uid'],'replicas':2,'resources':r,'image':cs[0]['image'],'surge':surge}
    fingerprint=hashlib.sha256(json.dumps(signature,sort_keys=True).encode()).hexdigest()
    return d,r,slots,signature,fingerprint

def metadata(name,fingerprint):
    return {'name':name,'namespace':NS,'labels':{'app.kubernetes.io/managed-by':OWNER},
            'annotations':{'ota.dev/source-fingerprint':fingerprint}}

def prepare():
    d,r,slots,signature,fingerprint=live_source()
    for kind in ['resourcequota','limitrange']:
        assert not kj(CTX,'-n',NS,'get',kind)['items'], 'Existing namespace policy: inspect rather than adding another policy'
    hard={'pods':str(slots),
          'requests.cpu':str(math.ceil(cpu(r['requests']['cpu'])*1000*slots))+'m',
          'requests.memory':str(math.ceil(mem(r['requests']['memory'])*slots)),
          'limits.cpu':str(math.ceil(cpu(r['limits']['cpu'])*1000*slots))+'m',
          'limits.memory':str(math.ceil(mem(r['limits']['memory'])*slots))}
    limit={'apiVersion':'v1','kind':'LimitRange','metadata':metadata(NAMES['LimitRange'],fingerprint),
           'spec':{'limits':[{'type':'Container','defaultRequest':r['requests'],'default':r['limits']}]}}
    quota={'apiVersion':'v1','kind':'ResourceQuota','metadata':metadata(NAMES['ResourceQuota'],fingerprint),'spec':{'hard':hard}}
    FILE.parent.mkdir(parents=True,exist_ok=True)
    with FILE.open('x',encoding='utf-8') as f: yaml.safe_dump_all([limit,quota],f,sort_keys=False)
    save('policy-source.json',{'source':signature,'slots':slots,'formula':'replicas + maxSurge + 1 spare','quota':hard})
    print(FILE); print(json.dumps(hard,indent=2)); print('RESULT=PREPARED (not applied)')

def load():
    docs=list(yaml.safe_load_all(FILE.read_text(encoding='utf-8')))
    assert len(docs)==2 and {d['kind'] for d in docs}==set(NAMES)
    _,_,_,_,fingerprint=live_source()
    for d in docs:
        m=d['metadata']; assert m['namespace']==NS and m['name']==NAMES[d['kind']]
        assert m['labels']['app.kubernetes.io/managed-by']==OWNER
        assert m['annotations']['ota.dev/source-fingerprint']==fingerprint,'Deployment changed: preserve this draft and recalculate'
    return docs

def apply():
    docs=load()
    for d in docs:
        existing=kj(CTX,'-n',NS,'get',d['kind'])['items']
        for e in existing:
            assert e['metadata']['name']==d['metadata']['name'] and e['metadata'].get('labels',{}).get('app.kubernetes.io/managed-by')==OWNER,'Conflicting namespace policy'
    run(['kubectl','--context',CTX,'apply','--dry-run=server','-f',str(FILE)])
    print(run(['kubectl','--context',CTX,'apply','-f',str(FILE)]))
    print('RESULT=APPLIED (run check next)')

def check():
    docs=load(); expected={d['kind']:d for d in docs}
    for kind,name in NAMES.items():
        live=kj(CTX,'-n',NS,'get',kind,name)
        assert live['metadata'].get('labels',{}).get('app.kubernetes.io/managed-by')==OWNER
        if kind=='ResourceQuota':
            wanted=expected[kind]['spec']['hard']
            converters={k:(cpu if k.endswith('cpu') else mem if k.endswith('memory') else decimal.Decimal) for k in wanted}
            for k in wanted: assert converters[k](live['spec']['hard'][k])==converters[k](wanted[k])
            used=live.get('status',{}).get('used',{})
            assert set(wanted)<=set(used), 'Wait for quota status reconciliation, then retry check'
            for k in wanted: assert converters[k](used[k])<=converters[k](wanted[k]), 'Current usage exceeds quota: '+k
        else: assert live['spec']==expected[kind]['spec']
    d,r,_,_,_=live_source()
    pod={'apiVersion':'v1','kind':'Pod','metadata':{'name':'day9-admission-probe','namespace':NS},
         'spec':{'restartPolicy':'Never','automountServiceAccountToken':False,
                 'securityContext':d['spec']['template']['spec'].get('securityContext',{}),
                 'containers':[{'name':'probe','image':d['spec']['template']['spec']['containers'][0]['image'],
                                'securityContext':d['spec']['template']['spec']['containers'][0].get('securityContext',{})}]}}
    cmd=['kubectl','--context',CTX,'create','--dry-run=server','-f','-','-o','json']
    admitted=json.loads(run(cmd,input=json.dumps(pod)))
    got=admitted['spec']['containers'][0]['resources']
    for side in ['requests','limits']:
        assert cpu(got[side]['cpu'])==cpu(r[side]['cpu']) and mem(got[side]['memory'])==mem(r[side]['memory'])
    quota=expected['ResourceQuota']['spec']['hard']; too_much=cpu(quota['requests.cpu'])+1
    pod['spec']['containers'][0]['resources']={'requests':{'cpu':str(too_much),'memory':r['requests']['memory']},
        'limits':{'cpu':str(max(too_much,cpu(quota['limits.cpu'])+1)),'memory':r['limits']['memory']}}
    rejected=subprocess.run(cmd,input=json.dumps(pod),text=True,capture_output=True,timeout=60)
    assert rejected.returncode!=0 and 'exceeded quota' in rejected.stderr.lower(),rejected.stderr
    save('policy-check-'+str(int(time.time()))+'.json',{'defaultedResources':got,'quotaRejected':rejected.stderr.strip(),'probe':'server dry-run only; no Pod created'})
    print('LimitRange defaults applied; excessive request rejected by quota; no probe Pod created')
    print('RESULT=PASS')

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('mode',choices=['prepare','apply','check']); args=parser.parse_args()
    {'prepare':prepare,'apply':apply,'check':check}[args.mode]()
