"""补齐已获授权但因验收脚本未处理降噪而未执行的夜景复看。"""
from copy import deepcopy
import json
from pathlib import Path
import shutil
import sys
from time import monotonic
from visual_acceptance import Engine, ROOT, invoke, neutral
from review_constraints import review_allowed

def main():
    if len(sys.argv)!=2:raise SystemExit('需要指定已保存的验收报告路径')
    path=Path(sys.argv[1]).resolve(strict=True)
    report=json.loads(path.read_text());row=next(x for x in report['cases'] if x['id']=='night')
    if row.get('review') is not None or row.get('execution_error')!='返回了不适用的操作或多个目标，未执行':
        raise SystemExit('该案例不是可安全补齐的未复看状态')
    changes=row['initial']['changes'];operations=changes[0].get('operations',[])
    if len(changes)!=1 or operations!=[{'kind':'denoise','value':1}]:raise SystemExit('操作与预期不符')
    engine=Engine(ROOT)
    engine.assistant._invoke=lambda provider,prompt,cancel,images=None:engine.assistant._invoke_once(provider,prompt,cancel,monotonic()+240,images)
    asset=engine.import_one(ROOT/'output/expanded-public-samples-20261029'/row['source'])
    original=neutral();final=deepcopy(changes[0]['params']);quality={'denoise':True,'scale':1}
    rendered=engine.preview(asset.id,final,quality)['preview']
    shutil.copyfile(rendered,path.parent/'night-after.png')
    row['review']={'state':'request_in_flight'};path.write_text(json.dumps(report,ensure_ascii=False,indent=2))
    target={'id':asset.id,'params':final,'quality':quality}
    review=invoke(engine,{'provider':'codex','message':'请复看调整后的预览。原要求：'+row['prompt']+'。若效果合适则不修改；只允许微调已有调整参数。',
                          'targets':[target],'image_consent':True,'review_only':True})
    row['review']=review;path.write_text(json.dumps(report,ensure_ascii=False,indent=2))
    if review.get('state')=='done' and review.get('changes'):
        revised=review['changes'][0]['params']
        if review_allowed(original,final,revised):final=revised
        else:row['review_skipped']='复看涉及首轮未调整的参数'
    rendered=engine.preview(asset.id,final,quality)['preview'];shutil.copyfile(rendered,path.parent/'night-after.png')
    row['quality']=quality;row['final_params']=final;row.pop('execution_error',None)
    path.write_text(json.dumps(report,ensure_ascii=False,indent=2));print('night review',review.get('state'))

if __name__=='__main__':main()
