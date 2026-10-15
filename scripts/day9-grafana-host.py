#!/usr/bin/env python3
"""Verify the new Host dashboard through Grafana; password stays in process memory."""
import base64,getpass,json,math,os,time,urllib.request
from day9_common import ROOT,save

def main():
    user=input('Grafana username [admin]: ').strip() or 'admin'
    password=getpass.getpass('Grafana password (not saved): ')
    auth='Basic '+base64.b64encode((user+':'+password).encode()).decode()
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    base=os.environ.get('GRAFANA_URL','http://127.0.0.1:13000').rstrip('/')
    def call(path,body=None):
        data=json.dumps(body).encode() if body is not None else None
        req=urllib.request.Request(base+path,data=data,headers={'Authorization':auth,'Content-Type':'application/json'})
        with opener.open(req,timeout=30) as response: return json.load(response)
    dashboard=call('/api/dashboards/uid/ota-host-overview')
    assert dashboard['meta'].get('provisioned') is True
    expected=json.loads((ROOT/'helm/monitoring/dashboards/ota-host-overview.json').read_text())
    assert dashboard['dashboard']['title']==expected['title']
    actual={p['id']:p for p in dashboard['dashboard']['panels']}
    summary=[]
    for panel in expected['panels']:
        actual_panel=actual[panel['id']]
        assert actual_panel.get('datasource',{}).get('uid')=='prometheus-a', 'Host panel datasource differs from Git'
        assert [(x.get('refId'),x.get('expr')) for x in actual_panel['targets']]==[(x.get('refId'),x.get('expr')) for x in panel['targets']], 'Provisioned query differs from Git'
        q={'refId':'A','datasource':{'type':'prometheus','uid':'prometheus-a'},
           'expr':panel['targets'][0]['expr'],'instant':True,'range':False,
           'format':'time_series','intervalMs':30000,'maxDataPoints':10}
        response=call('/api/ds/query',{'queries':[q],'from':str(int((time.time()-300)*1000)),
                                      'to':str(int(time.time()*1000))})
        result=response['results']['A']
        assert result.get('status',200)==200 and not result.get('error'),panel['title']
        values=[]
        for frame in result.get('frames',[]):
            for field,series in zip(frame['schema']['fields'],frame.get('data',{}).get('values',[])):
                if field.get('type')=='number': values.extend(v for v in series if v is not None)
        assert values and all(math.isfinite(float(v)) for v in values), (panel['title'],'no finite numeric samples')
        summary.append({'panel':panel['title'],'values':values})
    save('grafana-host-'+str(time.time_ns())+'.json',{'uid':expected['uid'],'panels':summary})
    print('RESULT=PASS (new Host dashboard provisioned; all panel queries through Grafana returned numbers)')

if __name__=='__main__': main()
