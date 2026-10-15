#!/usr/bin/env python3
"""Compare a matched pair only when real CI timestamps overlap the high phase."""
import argparse, datetime, json, pathlib, re
from day9_common import save

def stamp(s): return datetime.datetime.fromisoformat(s.replace('Z','+00:00')).timestamp()
def overlap(a,b,c,d): return max(0,min(b,d)-max(a,c))
if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('baseline'); p.add_argument('ci'); p.add_argument('--ci-info',required=True); a=p.parse_args()
    b=json.loads(pathlib.Path(a.baseline).read_text(encoding='utf-8')); c=json.loads(pathlib.Path(a.ci).read_text(encoding='utf-8'))
    assert all(b[k]==c[k] for k in ['url','image','expected_version','plan','workers']),'Input conditions differ'
    for case in [b,c]:
        assert not case['aborted'] and case['input_valid'], 'Client could not sustain arrival rate'
        assert all(x['sent']==x['expected'] and x['client_missed']==0 for x in case['phases']),'Client missed requested arrival rate'
    info=dict(re.findall(r'^([a-z-]+)=(.*)$',pathlib.Path(a.ci_info).read_text(encoding='utf-8'),re.M))
    assert info.get('test-exit')=='0' and info.get('scan-exit','').startswith('0 '),'CI test/scan did not pass'
    assert re.fullmatch(r'sha256:[0-9a-f]{64}',info.get('built-digest','')) and info['built-digest']==info.get('pushed-digest')
    start,end=stamp(info['test-start']),stamp(info['push-end'])
    assert overlap(b['start_epoch'],b['finished_epoch'],start,end)==0,'CI also overlapped baseline'
    high=max(c['phases'],key=lambda x:x['rate']); seconds=overlap(high['start_epoch'],high['end_epoch'],start,end)
    assert end>start and seconds>=10,'CI active window must overlap high-rate phase by at least 10s; preserve and repeat the pair'
    result={'ci_commit':info['commit'],'ci_image':info['pushed-digest'],'ci_active_high_overlap_seconds':seconds,
            'baseline_phases':b['phases'],'ci_phases':c['phases'],
            'interpretation':'One HTTP demo comparison only. Latency uses successful requests; failures reported separately. Repeat before setting production targets.'}
    save('load-pair-comparison.json',result); print(json.dumps(result,indent=2)); print('RESULT=VALID_PAIRED_MEASUREMENT')
