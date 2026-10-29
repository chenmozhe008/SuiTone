"""针对人工指出效果偏弱的六条案例重测；默认只打印计划，不发送图片。"""
from copy import deepcopy
from datetime import datetime
import json
from pathlib import Path
import shutil
import sys
from time import monotonic
from visual_acceptance import CASES, FILES, Engine, ROOT, invoke, neutral
from review_constraints import review_allowed

IDS={'05','07','10','11','13','14'}
RETESTS=[row for row in CASES if row[0] in IDS]

def apply_quality(operations):
    quality={'denoise':False,'scale':1}
    for op in operations:
        kind,value=op['kind'],op['value']
        if kind=='denoise' and value in (0,1):quality['denoise']=bool(value)
        elif kind=='upscale' and value in (1,2,4):quality['scale']=int(value)
        else:raise ValueError('重测没有执行此操作所需的选区或参考图')
    return quality

def main():
    if not sys.argv[1:]:
        for key,scene,prompt in RETESTS:print(key,scene,prompt)
        return
    if sys.argv[1:]!=['--run-authorized']:raise SystemExit('用法：无参数查看计划；授权后使用 --run-authorized')
    out=ROOT/'output'/('retested-visual-'+datetime.now().astimezone().strftime('%Y%m%d-%H%M%S'))
    out.mkdir(parents=True,exist_ok=False);path=out/'results.json'
    report={'status':'running','provider':'codex','preserves_previous_scores':True,'cases':[]}
    def save():path.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    engine=Engine(ROOT);assets={}
    # 禁止自动重发，确保首轮和复看各不超过一次。
    engine.assistant._invoke=lambda provider,prompt,cancel,images=None:engine.assistant._invoke_once(provider,prompt,cancel,monotonic()+240,images)
    save()
    for key,scene,prompt in RETESTS:
        row={'id':key,'scene':scene,'prompt':prompt,'initial':{'state':'not_started'},'review':None};report['cases'].append(row);save()
        try:
            if scene not in assets:assets[scene]=engine.import_one(FILES[scene])
            asset=assets[scene];original=neutral();quality={'denoise':False,'scale':1}
            before=engine.preview(asset.id,original,quality)['preview'];shutil.copyfile(before,out/(key+'-before.png'))
            target={'id':asset.id,'params':original,'quality':quality}
            row['initial']={'state':'request_in_flight'};save()
            first=invoke(engine,{'provider':'codex','message':prompt,'targets':[target],'image_consent':True})
            row['initial']=first;save()
            if first.get('state')!='done':continue
            changes=first.get('changes',[]);final=deepcopy(original)
            if len(changes)>1:raise ValueError('返回了多个目标，未应用')
            if changes:
                final=changes[0]['params'];quality=apply_quality(changes[0].get('operations',[]))
                target={'id':asset.id,'params':final,'quality':quality}
                row['review']={'state':'request_in_flight'};save()
                review=invoke(engine,{'provider':'codex','message':'请复看调整后的预览。原要求：'+prompt+'。若效果合适则不修改；只允许微调已有调整参数。',
                                      'targets':[target],'image_consent':True,'review_only':True,
                                      'review_before':[{'id':asset.id,'source_id':asset.id,'params':original,'quality':{'denoise':False,'scale':1}}]})
                row['review']=review;save()
                if review.get('state')=='done' and review.get('changes'):
                    revision=review['changes'][0]
                    if revision.get('operations'):row['review_skipped']='复看包含不允许的额外操作'
                    elif review_allowed(original,final,revision['params']):final=revision['params']
                    else:row['review_skipped']='复看涉及首轮未调整的参数'
            after=engine.preview(asset.id,final,quality)['preview'];shutil.copyfile(after,out/(key+'-after.png'))
            row['quality']=quality;row['final_params']=final;save()
        except Exception as exc:row['execution_error']=str(exc);save()
        print(key,row['initial']['state'],(row.get('review') or {}).get('state','no_review'),flush=True)
    report['status']='awaiting_manual_review';save();print('报告',path,flush=True)

if __name__=='__main__':main()
