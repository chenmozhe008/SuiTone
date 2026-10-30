"""与 App 一致的复看保护：只允许细化首轮已经改变的字段。"""
from copy import deepcopy

_MISSING=object()

def review_allowed(original,first,revised):
    if first.get('manual_masks',{}) != revised.get('manual_masks',{}):return False
    baseline=deepcopy(original)
    regions=baseline.setdefault('regions',{})
    for name,region in first.get('regions',{}).items():
        if name not in regions and region.get('reference_count',0)==0:
            neutral=deepcopy(region);neutral['mean']=deepcopy(region['source_mean']);regions[name]=neutral
    def allowed(old,current,new):
        if current==new:return True
        if isinstance(current,dict) and isinstance(new,dict):
            prior=old if isinstance(old,dict) else {}
            return all(allowed(prior.get(k,_MISSING),current.get(k,_MISSING),new.get(k,_MISSING))
                       for k in prior.keys() | current.keys() | new.keys())
        if isinstance(current,list) and isinstance(new,list):
            if len(current)!=len(new):return False
            prior=old if isinstance(old,list) else []
            return all(allowed(prior[i] if i<len(prior) else _MISSING,current[i],new[i]) for i in range(len(current)))
        return old!=current
    return allowed(baseline,first,revised)
