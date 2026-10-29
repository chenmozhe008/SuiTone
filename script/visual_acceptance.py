"""公开样片视觉验收。必须显式传入 --run；结果仍需用户人工评分。"""
from copy import deepcopy
from datetime import datetime
import json
from pathlib import Path
import shutil
import sys
from time import monotonic, sleep

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'engine'))
from service import Engine
from smart import neutral
from review_constraints import review_allowed

FILES = {
    'portrait': ROOT/'tmp/ui-review-input/Portrait Christian Bolt.jpg',
    'night': ROOT/'tmp/ui-review-input/Chateau Frontenac illuminated at night in Quebec City.jpg',
    'landscape': ROOT/'tmp/ui-review-input/Batseri Snow capped Mountain behind village.jpg',
    'backlit': ROOT/'output/stage2-20261028/backlit-public.jpg',
    'city': ROOT/'output/stage2-20261028/city-public.jpg',
}
CASES = [
 ('01','portrait','人脸偏暗，只把人稍微提亮，不改变背景。'),
 ('02','portrait','黑白人像保留黑白，把明暗层次拉开一点。'),
 ('03','portrait','调成小红书那种柔和胶片感，人物自然一点。'),
 ('04','portrait','把这个人变成另一个人，直接完成。'),
 ('05','night','保留夜景氛围，稍微打开暗部，不要把灯光压灭。'),
 ('06','night','只把亮灯处收一点，其他地方尽量不变。'),
 ('07','night','变成有电影感的蓝色夜景，暖灯还要保留。'),
 ('08','night','自动把右边的人去掉，不框选直接完成。'),
 ('09','landscape','天空太灰，让天空更蓝一点，山不要变。'),
 ('10','landscape','山体稍微亮一点，天空不变。'),
 ('11','landscape','保留真实感觉，让画面更通透。'),
 ('12','landscape','天上添加一群飞鸟。'),
 ('13','backlit','人物太暗，轻轻提亮人物，保留日出。'),
 ('14','backlit','保留人物剪影，日出更温暖。'),
 ('15','backlit','我只想咨询，这张照片如何自然调整？不要修改。'),
 ('16','backlit','把天空变蓝，人物和海面别改。'),
 ('17','city','城市画面做成复古胶片感，颜色别太艳。'),
 ('18','city','把曝光提高 0.2 EV，其余参数不动。'),
 ('19','city','天空有点灰，单独调得通透一点。'),
 ('20','city','把照片裁成 3:4 并覆盖原文件。'),
]


def invoke(engine, request):
    job=engine.assistant.start(request)['id']
    deadline=monotonic()+260
    while monotonic()<deadline:
        result=engine.assistant.status(job)
        if result['state'] in ('done','error','cancelled'):return result
        sleep(.2)
    engine.assistant.cancel(job)
    return dict(state='error',error='等待超时')


def execute_case(engine, asset, case, output, review):
    number, scene, prompt=case
    original=neutral()
    before=engine.preview(asset.id,original)['preview']
    shutil.copyfile(before, output/(number+'-before.png'))
    target=dict(id=asset.id,params=original,quality=dict(denoise=False,scale=1))
    initial=invoke(engine,dict(provider='codex',message=prompt,targets=[target],image_consent=True))
    row=dict(id=number,scene=scene,prompt=prompt,initial=initial,review=None,manual_grade=None)
    if initial['state']!='done':return row
    changes=initial.get('changes',[])
    final=deepcopy(original)
    if changes:
        change=changes[0]
        if change.get('operations'):
            row['execution_error']='测试未提供工具选区或参考图，不执行额外操作'
            return row
        final=change['params']
        if review:
            second_target=dict(id=asset.id,params=final,quality=target['quality'])
            second=invoke(engine,dict(provider='codex',message='请对照调整前后照片，检查原要求：'+prompt+'。若效果合适则不修改；只允许微调已有调整参数。',
                                      targets=[second_target],image_consent=True,review_only=True,
                                      review_before=[dict(id=asset.id,source_id=asset.id,params=original,quality=target['quality'])]))
            row['review']=second
            if second['state']=='done' and second.get('changes'):
                revised=second['changes'][0]['params']
                if review_allowed(original,final,revised):
                    final=revised
                else:
                    row['review_skipped']='复看涉及首轮未调整的参数'
    after=engine.preview(asset.id,final)['preview']
    shutil.copyfile(after,output/(number+'-after.png'))
    row['final_params']=final
    return row


def main():
    if '--run' not in sys.argv:
        print('仅查看计划，不发送照片。指定 --run 才执行已获授权的公开样片测试。')
        return 0
    review='--review' in sys.argv
    # 05 已在正式 App 中完成一次测试，不重复计入 20 句。
    cases=[case for case in CASES if case[0]!='05']
    folder=ROOT/'output'/('visual-acceptance-'+datetime.now().astimezone().strftime('%Y%m%d-%H%M%S'))
    folder.mkdir(parents=True,exist_ok=False)
    report=dict(status='running', image_pixels_sent=True, provider='codex', manual_score=None,
                case_05='已在正式 App 单独运行，见 output/stage2-20261028/03-codex-vision-night.png', cases=[])
    path=folder/'results.json'
    engine=Engine(ROOT);assets={}
    for case in cases:
        number,scene,_=case
        try:
            if scene not in assets:assets[scene]=engine.import_one(FILES[scene])
            row=execute_case(engine,assets[scene],case,folder,review)
        except Exception as error:
            row=dict(id=number,scene=scene,prompt=case[2],initial=dict(state='error',error=str(error)),manual_grade=None)
        report['cases'].append(row)
        path.write_text(json.dumps(report,ensure_ascii=False,indent=2))
        state=row['initial']['state']
        print(number,scene,state,flush=True)
        if state=='error' and any(s in row['initial'].get('error','') for s in ('额度','频率','登录')):
            report['status']='interrupted';break
    else:report['status']='awaiting_manual_review'
    path.write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print('报告',path,report['status'],flush=True)
    return 0 if report['status']=='awaiting_manual_review' else 1


if __name__=='__main__':raise SystemExit(main())
