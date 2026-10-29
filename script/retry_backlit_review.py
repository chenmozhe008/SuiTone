"""重试此前失败的单次人像复看；默认只检查计划，不发送图片。"""
from copy import deepcopy
from datetime import datetime
import json
from pathlib import Path
import shutil
import sys
from time import monotonic
from visual_acceptance import Engine, ROOT, invoke, neutral
from review_constraints import review_allowed

SOURCE=ROOT/'output/expanded-visual-20261029-180209/results.json'
PHOTO=ROOT/'output/backlit-candidates-20261029/Portrait at the window.jpg'

def main():
    report=json.loads(SOURCE.read_text());original=report['cases'][0]
    if original['id']!='backlit-person' or original['initial']['state']!='done' or original['review']['state']!='error':
        raise SystemExit('原结果不是预期的首轮成功、复看失败状态')
    if not sys.argv[1:]:
        print('计划：复看已保存的窗边人像首轮结果；最多一次请求，不重跑首轮。');return
    if sys.argv[1:]!=['--run-authorized']:raise SystemExit('用法：无参数查看计划；授权后使用 --run-authorized')
    output=ROOT/'output'/('backlit-review-retry-'+datetime.now().astimezone().strftime('%Y%m%d-%H%M%S'))
    output.mkdir(parents=True,exist_ok=False);path=output/'results.json';row=deepcopy(original)
    row['review_attempts']=[deepcopy(row['review'])];row['review']={'state':'not_started'}
    result={'status':'running','provider':'codex','previous_report':str(SOURCE),'cases':[row]}
    def save():path.write_text(json.dumps(result,ensure_ascii=False,indent=2))
    for side in ('before','after'):shutil.copyfile(SOURCE.parent/('backlit-person-'+side+'.png'),output/('backlit-person-'+side+'.png'))
    engine=Engine(ROOT);engine.assistant._invoke=lambda provider,prompt,cancel,images=None:engine.assistant._invoke_once(provider,prompt,cancel,monotonic()+240,images)
    asset=engine.import_one(PHOTO);base=neutral();final=deepcopy(row['final_params']);quality=row.get('quality',{'denoise':False,'scale':1})
    target={'id':asset.id,'params':final,'quality':quality};row['review']={'state':'request_in_flight'};save()
    review=invoke(engine,{'provider':'codex','message':'请复看调整后的预览。原要求：'+row['prompt']+'。若效果合适则不修改；只允许微调已有调整参数。',
                          'targets':[target],'image_consent':True,'review_only':True,
                          'review_before':[{'id':asset.id,'source_id':asset.id,'params':base,'quality':{'denoise':False,'scale':1}}]})
    row['review']=review;save()
    if review.get('state')=='done' and review.get('changes'):
        revision=review['changes'][0]
        if revision.get('operations'):row['review_skipped']='复看包含不允许的额外操作'
        elif review_allowed(base,final,revision['params']):final=revision['params']
        else:row['review_skipped']='复看涉及首轮未调整的参数'
    if review.get('state')=='done':
        rendered=engine.preview(asset.id,final,quality)['preview'];shutil.copyfile(rendered,output/'backlit-person-after.png')
        row['final_params']=final;result['status']='awaiting_manual_review'
    else:result['status']='incomplete'
    save();print('复看',review.get('state'),'报告',path,flush=True)

if __name__=='__main__':main()
