#!/usr/bin/env python3
"""Collect observations; never automatically lower requests or limits."""
import time,subprocess
from day9_common import kj,query,run,save
data={'time':time.time(),'clusters':{}}
for ctx in ['ota-a','ota-b']:
 nodes=kj(ctx,'get','nodes')['items']; pods=kj(ctx,'get','pods','-A')['items']
 d={'nodes':[{'name':n['metadata']['name'],'allocatable':n['status']['allocatable'],'conditions':n['status']['conditions']} for n in nodes],
 'pods':[{'namespace':p['metadata']['namespace'],'name':p['metadata']['name'],'node':p['spec'].get('nodeName'),
 'phase':p['status']['phase'],'containers':[{'name':c['name'],'resources':c.get('resources',{})} for c in p['spec']['containers']],
 'initContainers':[{'name':c['name'],'restartPolicy':c.get('restartPolicy'),'resources':c.get('resources',{})} for c in p['spec'].get('initContainers',[])],
 'overhead':p['spec'].get('overhead'),'podResources':p['spec'].get('resources')} for p in pods if p['status']['phase'] not in ['Succeeded','Failed']],
 'schedulerAllocation':run(['kubectl','--context',ctx,'describe','nodes']),'observations':{}}
 for q in ['max_over_time(container_memory_working_set_bytes{container!="",container!="POD",pod!=""}[15m])',
           'max_over_time(node_memory_MemAvailable_bytes{job="kubernetes-service-endpoints"}[15m])',
           'min_over_time(node_memory_MemAvailable_bytes{job="kubernetes-service-endpoints"}[15m])',
           'kube_pod_container_resource_requests','kube_pod_container_resource_limits',
           'kube_resourcequota{namespace="production"}','kube_limitrange{namespace="production"}']:
  d['observations'][q]=query(ctx,q)
 data['clusters'][ctx]=d
p=save('resource-budget-'+str(int(time.time()))+'.json',data)
print('Saved',p)
print('Node allocation uses kubectl describe output; init/sidecar/Pod overhead must be considered. No automatic resource changes.')
print('RESULT=PASS')
