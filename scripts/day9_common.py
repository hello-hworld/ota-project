"""Small read-only helpers. No credentials are logged."""
import json,os,pathlib,subprocess,urllib.parse
ROOT=pathlib.Path(os.environ.get('REPO',os.path.expanduser('~/ota-project')))
EV=pathlib.Path(os.environ['EV'])
def run(args,input=None):
 r=subprocess.run(args,input=input,text=True,capture_output=True,timeout=90)
 if r.returncode: raise RuntimeError(' '.join(args)+': '+r.stderr.strip())
 return r.stdout
def kj(ctx,*args): return json.loads(run(['kubectl','--context',ctx,*args,'-o','json']))
def prom(ctx,path,**params):
 q=('?'+urllib.parse.urlencode(params)) if params else ''
 url='/api/v1/namespaces/monitoring/services/http:prometheus-server:80/proxy'+path+q
 data=json.loads(run(['kubectl','--context',ctx,'get','--raw',url]))
 if data.get('status')!='success': raise RuntimeError(str(data))
 return data['data']
def query(ctx,expr): return prom(ctx,'/api/v1/query',query=expr)['result']
def save(name,data):
 p=EV/name; p.parent.mkdir(parents=True,exist_ok=True)
 with p.open('x',encoding='utf-8') as f: json.dump(data,f,ensure_ascii=False,indent=2)
 return p
