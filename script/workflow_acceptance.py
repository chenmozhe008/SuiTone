"""通用初调、风格、预览性能和真实 CLI 联动验证；不上传图像。"""
import argparse
from copy import deepcopy
from datetime import datetime
import json
from pathlib import Path
import sys
from time import perf_counter,sleep
import numpy as np
from PIL import Image,ImageDraw

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'engine'))
from service import Engine
from smart import STYLES

def main(ai):
    folder=ROOT/'output'/('workflow-'+datetime.now().astimezone().strftime('%Y%m%d-%H%M%S'))
    folder.mkdir(parents=True)
    engine=Engine(ROOT);report=dict(status='running',samples=[],styles=[],ai=[])
    def save(): (folder/'results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    library=ROOT/'cases/2026-10-27_公开测试样本'
    samples=json.loads((library/'sources.json').read_text())
    first=None
    contact=Image.new('RGB',(1200,((len(samples)+3)//4)*220),(38,38,38));draw=ImageDraw.Draw(contact)
    for index,sample in enumerate(samples):
        path=ROOT/sample['path'];start=perf_counter()
        asset=engine.import_one(path.resolve());look=engine.smart(asset.id)
        if first is None:first=(asset,look)
        with Image.open(look['preview']) as im:
            assert max(im.size)<=1200
            preview=im.copy();preview.thumbnail((280,180))
            x,y=(index%4)*300+10,(index//4)*220+24
            contact.paste(preview,(x,y));draw.text((x,y-17),path.name[:35],fill=(220,220,220))
        assert not any(look['params']['enabled'][name] for name in ['water','sky','land'])
        report['samples'].append(dict(name=path.name,scene=sample['scene'],params=look['params'],elapsed_ms=(perf_counter()-start)*1000))
        print('智能初调',path.name,flush=True);save()
    contact.save(folder/'smart-contact.jpg',quality=94)
    asset,look=first
    sheet=Image.new('RGB',(1500,((len(STYLES)+2)//3)*340),(38,38,38));draw=ImageDraw.Draw(sheet)
    for index,style in enumerate(STYLES):
        output=engine.smart(asset.id,style['id'])
        with Image.open(output['preview']) as image:
            image=image.copy();image.thumbnail((480,300))
            x,y=index%3*500+10,index//3*340+28;sheet.paste(image,(x,y));draw.text((x,y-20),style['id'],fill=(225,225,225))
        report['styles'].append(dict(id=style['id'],params=output['params']))
    sheet.save(folder/'style-contact.jpg',quality=94)
    p=look['params'];engine.preview(asset.id,p)
    before=engine.analyze(asset.id)['inference_count'];timings=[]
    for i in range(12):
        params=deepcopy(p);params['exposure']+=.013*i
        start=perf_counter();result=engine.preview(asset.id,params)
        with Image.open(result['preview']) as image:image.load()
        timings.append((perf_counter()-start)*1000)
    after=engine.analyze(asset.id)['inference_count']
    report['preview']=dict(timings_ms=timings,max_ms=max(timings),p50_ms=float(np.median(timings)),p95_ms=float(np.percentile(timings,95)),no_repeated_inference=before==after)
    report['status']='preview_check_failed' if max(timings)>=1000 or before!=after else 'running'
    save()
    assert max(timings)<1000 and before==after,report['preview']
    if ai:
        # 所有 CLI 输入仅是公开样本的数字分析摘要，不传照片或文件路径。
        targets=[dict(id=asset.id,params=p)]
        for provider in engine.assistant.providers():
            if not provider['available']:continue
            started=engine.assistant.start(dict(provider=provider['id'],message='请把当前照片整体曝光提高 0.15 EV，其他保持不变。请直接调整。',targets=deepcopy(targets),history=[]))
            seen=''
            while True:
                job=engine.assistant.status(started['id'])
                if job['state']!=seen:print('CLI',provider['id'],job['state'],flush=True);seen=job['state']
                if job['state'] in ['done','error','cancelled']:break
                sleep(.5)
            if job['state']=='done':
                assert len(job['changes'])==1
                assert abs(job['changes'][0]['params']['exposure']-(p['exposure']+.15))<.005
            report['ai'].append(dict(provider=provider['id'],**job));save()
    report['status']='engine_checks_passed'
    save();print('验收产物',folder,flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--ai',action='store_true')
    main(parser.parse_args().ai)
