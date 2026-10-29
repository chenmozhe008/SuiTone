"""从已有视觉报告继续；保留原报告，不重跑已完成的话术。"""
from copy import deepcopy
from datetime import datetime
import json
from pathlib import Path
import shutil
import sys

from visual_acceptance import CASES, FILES, Engine, execute_case, invoke, neutral, ROOT
from review_constraints import review_allowed


def save(path, report):
    path.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')


def throttled(result):
    return result.get('state')=='error' and any(word in result.get('error','') for word in ('额度','频率','登录'))


def main():
    if len(sys.argv)!=3 or sys.argv[1]!='--resume':
        raise SystemExit('用法：python -B script/resume_visual_acceptance.py --resume <已有 results.json>')
    previous=Path(sys.argv[2]).resolve(strict=True)
    previous_report=json.loads(previous.read_text(encoding='utf-8'))
    output=ROOT/'output'/('visual-acceptance-'+datetime.now().astimezone().strftime('%Y%m%d-%H%M%S'))
    output.mkdir(parents=True,exist_ok=False)
    report=deepcopy(previous_report);report['status']='running'
    report['resumed_from']=str(previous)
    report['previous_attempts']=deepcopy(previous_report.get('previous_attempts',[]))
    report['previous_attempts'] += [deepcopy(row) for row in report['cases'] if row.get('initial',{}).get('state')!='done']
    report['cases']=[row for row in report['cases'] if row.get('initial',{}).get('state')=='done']
    for row in report['cases']:
        for suffix in ('before','after'):
            source=previous.parent/(row['id']+'-'+suffix+'.png')
            if source.exists():shutil.copyfile(source,output/source.name)
        if row.get('after_file'):
            source=previous.parent/row['after_file']
            if source.exists():shutil.copyfile(source,output/source.name)
    path=output/'results.json';save(path,report)
    engine=Engine(ROOT);assets={}
    def asset_for(scene):
        if scene not in assets:assets[scene]=engine.import_one(FILES[scene])
        return assets[scene]
    # 仅复看失败的已完成项目，不再重复首轮。
    for row in report['cases']:
        prior=row.get('review')
        if not prior or prior.get('state')=='done':continue
        changes=row['initial'].get('changes',[])
        if len(changes)!=1 or changes[0].get('operations'):
            row['review_retry_error']='原结果无法安全复看';save(path,report);continue
        original=neutral();first=changes[0]['params'];asset=asset_for(row['scene'])
        target=dict(id=asset.id,params=first,quality=dict(denoise=False,scale=1))
        review=invoke(engine,dict(provider='codex',message='请复看调整后的预览。原要求：'+row['prompt']+'。若效果合适则不修改；只允许微调已有调整参数。',
                                  targets=[target],image_consent=True,review_only=True))
        row.setdefault('review_attempts',[]).append(prior);row['review']=review
        if review['state']=='done':
            final=deepcopy(first)
            if review.get('changes'):
                revised=review['changes'][0]['params']
                if review_allowed(original,first,revised):final=revised
                else:row['review_skipped']='复看涉及首轮未调整的参数'
            rendered=engine.preview(asset.id,final)['preview']
            filename=row['id']+'-after-review.png'
            shutil.copyfile(rendered,output/filename)
            row['after_file']=filename;row['final_params']=final
        save(path,report)
        print(row['id'],'review',review['state'],flush=True)
        if throttled(review):
            report['status']='interrupted';save(path,report);print('报告',path,report['status'],flush=True);return 1
    done={row['id'] for row in report['cases']}
    for case in CASES:
        number,scene,_=case
        if number=='05' or number in done:continue
        try:row=execute_case(engine,asset_for(scene),case,output,True)
        except Exception as error:
            row=dict(id=number,scene=scene,prompt=case[2],initial=dict(state='error',error=str(error)),manual_grade=None)
        report['cases'].append(row);save(path,report)
        print(number,scene,row['initial']['state'],'review',(row.get('review') or {}).get('state','none'),flush=True)
        if throttled(row['initial']) or throttled(row.get('review') or {}):
            report['status']='interrupted';save(path,report);print('报告',path,report['status'],flush=True);return 1
    all_done=all(row['initial']['state']=='done' and not row.get('execution_error') and
                 (not row.get('review') or row['review']['state']=='done') for row in report['cases'])
    report['status']='awaiting_manual_review' if len(report['cases'])==19 and all_done else 'incomplete'
    save(path,report);print('报告',path,report['status'],flush=True)
    return 0 if report['status']=='awaiting_manual_review' else 1


if __name__=='__main__':raise SystemExit(main())
