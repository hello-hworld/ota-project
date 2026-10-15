#!/usr/bin/env python3
"""Arrival-rate HTTP probe. Client misses and failures stay visible in raw evidence."""
import argparse, concurrent.futures, csv, datetime, json, math, pathlib, threading, time, urllib.request
from day9_common import EV
OPENER=urllib.request.build_opener(urllib.request.ProxyHandler({}))

def percentile(values,p):
    return sorted(values)[max(0,math.ceil(len(values)*p)-1)] if values else None

def main():
    a=argparse.ArgumentParser(); a.add_argument('--case',required=True)
    a.add_argument('--url',default='http://127.0.0.1:18081/healthz')
    a.add_argument('--image',required=True); a.add_argument('--version',required=True)
    a.add_argument('--plan',default='5:60,20:120,5:60'); a.add_argument('--workers',type=int,default=16)
    args=a.parse_args(); assert args.workers>0
    assert all(c.isalnum() or c in '_-' for c in args.case)
    phases=[(float(r),float(d)) for r,d in (x.split(':') for x in args.plan.split(','))]
    assert all(0<r<=200 and 0<d<=900 for r,d in phases)
    out=EV/('load-'+args.case); out.mkdir()
    rows=[]; future=[]; semaphore=threading.BoundedSemaphore(args.workers*2)
    epoch=time.time(); mono=time.monotonic(); phase_meta=[]; aborted=False
    def request(row):
        started=time.time(); row['started_epoch']=started; row['queue_ms']=(started-row['scheduled_epoch'])*1000
        try:
            req=urllib.request.Request(args.url,headers={'Connection':'close'})
            with OPENER.open(req,timeout=2) as response:
                row['status']=response.status; body=json.load(response)
            row['version']=body.get('version','')
            row['ok']=row['status']==200 and body.get('status')=='ok' and row['version']==args.version
            if not row['ok']: row['error']='HTTP/body/version mismatch'
        except Exception as exc:
            row['status']=getattr(exc,'code',0)
            row['ok']=False; row['error']=type(exc).__name__+': '+str(exc)[:140]
        finally:
            row['finished_epoch']=time.time(); row['latency_ms']=(row['finished_epoch']-started)*1000
            semaphore.release()
        return row
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        try:
            offset=0
            for index,(rate,duration) in enumerate(phases):
                p={'index':index,'rate':rate,'duration':duration,'start_epoch':epoch+offset,'end_epoch':epoch+offset+duration}
                phase_meta.append(p)
                print('PHASE',index,'target_rps',rate,'seconds',duration,datetime.datetime.fromtimestamp(p['start_epoch'],datetime.timezone.utc).isoformat(),flush=True)
                for i in range(math.floor(rate*duration)):
                    deadline=mono+offset+i/rate
                    delay=deadline-time.monotonic()
                    if delay>0: time.sleep(delay)
                    row={'phase':index,'seq':i,'scheduled_epoch':epoch+offset+i/rate,'status':0,'version':'','ok':False,'error':'','started_epoch':'','finished_epoch':'','latency_ms':'','queue_ms':''}
                    if time.monotonic()-deadline>max(0.05,1/rate):
                        row['error']='client_scheduler_miss'; rows.append(row); continue
                    if not semaphore.acquire(blocking=False):
                        row['error']='client_queue_full'; rows.append(row); continue
                    future.append(pool.submit(request,row))
                offset+=duration
                remain=mono+offset-time.monotonic()
                if remain>0: time.sleep(remain)
        except KeyboardInterrupt:
            aborted=True; print('Interrupted: stop scheduling; preserve completed evidence',flush=True)
        for f in concurrent.futures.as_completed(future): rows.append(f.result())
    rows.sort(key=lambda r:(r['phase'],r['seq']))
    with (out/'requests.csv').open('w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=['phase','seq','scheduled_epoch','started_epoch','finished_epoch','queue_ms','status','version','ok','error','latency_ms']); w.writeheader(); w.writerows(rows)
    summaries=[]
    for p in phase_meta:
        rs=[r for r in rows if r['phase']==p['index']]; sent=[r for r in rs if r['started_epoch']!='']; good=[r['latency_ms'] for r in sent if r['ok']]
        summaries.append(dict(p,expected=math.floor(p['rate']*p['duration']),sent=len(sent),success=len(good),
            http_or_body_errors=sum(not r['ok'] for r in sent),client_missed=len(rs)-len(sent),
            actual_rps=sum(p['start_epoch']<=r['started_epoch']<p['end_epoch'] for r in sent)/p['duration'],
            p50_success_ms=percentile(good,.50),p95_success_ms=percentile(good,.95),max_success_ms=max(good) if good else None,
            max_client_queue_ms=max((r['queue_ms'] for r in sent),default=None)))
    valid=not aborted and len(phase_meta)==len(phases) and all(p['sent']==p['expected'] and p['client_missed']==0
        and p['max_client_queue_ms'] is not None and p['max_client_queue_ms']<=max(50,1000/p['rate'])
        and abs(p['actual_rps']-p['rate'])<=max(1/p['duration'],0.01*p['rate']) for p in summaries)
    success=all(p['http_or_body_errors']==0 for p in summaries)
    meta={'case':args.case,'url':args.url,'image':args.image,'expected_version':args.version,'plan':args.plan,
          'start_epoch':epoch,'finished_epoch':time.time(),'workers':args.workers,'aborted':aborted,'phases':summaries}
    meta.update(input_valid=valid,http_body_success=success)
    (out/'result.json').write_text(json.dumps(meta,indent=2),encoding='utf-8')
    print(json.dumps(meta,indent=2))
    print('INPUT_VALID='+str(valid),'HTTP_BODY_SUCCESS='+str(success))
    return 0 if valid and success else 1

if __name__=='__main__': raise SystemExit(main())
