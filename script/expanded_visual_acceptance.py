"""四张经授权的公开样片；每张首轮及复看各最多一次。"""
from copy import deepcopy
from datetime import datetime
import json
from pathlib import Path
import shutil
import sys

from visual_acceptance import Engine, ROOT, invoke, neutral
from retest_visual_cases import apply_quality
from review_constraints import review_allowed

SAMPLES=ROOT/'output/expanded-public-samples-20261029'
CASES=[
    ('portrait','Portrait-of-a-woman.jpg','做成明显的暖胶片人像，保持肤色自然。'),
    ('food','A vegetarian plate of food.jpg','食物调得明亮有食欲，颜色自然但变化能看出来。'),
    ('night','Street photographer on Nanjing Road at night.jpg','做成明显的霓虹电影夜景，保留人物和亮灯细节。'),
    ('interior','Interior of old Cafe.JPG','调出明显的复古胶片氛围，保留室内的暖光和物件细节。'),
]

def main():
    if sys.argv[1:]!=['--run-authorized']:
        raise SystemExit('需显式指定 --run-authorized，且必须已有四张样片的发送授权')
    output=ROOT/'output'/('expanded-visual-'+datetime.now().astimezone().strftime('%Y%m%d-%H%M%S'))
    output.mkdir(parents=True,exist_ok=False)
    path=output/'results.json';report={'status':'running','provider':'codex','cases':[]}
    def save():path.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    engine=Engine(ROOT)
    # 验收有严格次数上限；不让 CLI 网络故障自动重发。
    engine.assistant._invoke=lambda provider,prompt,cancel,images=None: engine.assistant._invoke_once(provider,prompt,cancel,__import__('time').monotonic()+240,images)
    save()
    for key,filename,prompt in CASES:
        row={'id':key,'source':filename,'prompt':prompt,'initial':{'state':'not_started'},'review':None}
        report['cases'].append(row);save()
        try:
            asset=engine.import_one(SAMPLES/filename);original=neutral()
            before=engine.preview(asset.id,original)['preview'];shutil.copyfile(before,output/(key+'-before.png'))
            target={'id':asset.id,'params':original,'quality':{'denoise':False,'scale':1}}
            row['initial']={'state':'request_in_flight'};save()
            first=invoke(engine,{'provider':'codex','message':prompt,'targets':[target],'image_consent':True})
            row['initial']=first;save()
            if first.get('state')!='done':continue
            changes=first.get('changes',[]);final=deepcopy(original);quality=target['quality']
            if len(changes)==1:
                final=changes[0]['params'];quality=apply_quality(changes[0].get('operations',[]))
                review_target={'id':asset.id,'params':final,'quality':quality}
                row['review']={'state':'request_in_flight'};save()
                review=invoke(engine,{'provider':'codex','message':'请对照调整前后照片，检查目标区域的颜色方向、变化幅度和画质。原要求：'+prompt+'。不符合或无法判断时如实说明，不要夸大效果；确实合适时不修改，明显偏离时只可微调已有调整参数。',
                                      'targets':[review_target],'image_consent':True,'review_only':True,
                                      'review_before':[{'id':asset.id,'source_id':asset.id,'params':original,'quality':target['quality']}]})
                row['review']=review;save()
                if review.get('state')=='done' and review.get('changes'):
                    revision=review['changes'][0];revised=revision['params']
                    if revision.get('operations'):row['review_skipped']='复看包含不允许的额外操作'
                    elif review_allowed(original,final,revised):final=revised
                    else:row['review_skipped']='复看涉及首轮未调整的参数'
            elif changes:row['execution_error']='返回了不适用的操作或多个目标，未执行'
            after=engine.preview(asset.id,final,quality)['preview'];shutil.copyfile(after,output/(key+'-after.png'))
            row['final_params']=final;row['quality']=quality;save()
        except Exception as error:
            row['execution_error']=str(error);save()
        print(key,row['initial']['state'],(row.get('review') or {}).get('state','no_review'),flush=True)
    incomplete=any(row['initial'].get('state')!='done' or row.get('execution_error') or
                   (row.get('review') is not None and row['review'].get('state')!='done') for row in report['cases'])
    report['status']='incomplete' if incomplete else 'awaiting_manual_review'
    save();print('报告',path,report['status'],flush=True)

if __name__=='__main__':main()
