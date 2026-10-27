"""真实照片验收与证据产物。--full 另跑九张原尺寸导出，不覆盖历史版本。"""
import argparse
from copy import deepcopy
from datetime import datetime
from hashlib import sha256
import json
from pathlib import Path
import secrets
import subprocess
import sys
from time import perf_counter
from urllib.error import HTTPError
from urllib.request import Request,build_opener,ProxyHandler
import numpy as np
from PIL import Image,ImageDraw

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'engine'))
from service import Engine,DEFAULTS
from grade import grade_array,quantize,rgb2lab,grade
from image_io import load_image,load_pixels
from match import statistics
from lut import base_lut,write_cube,read_cube


def protocol_check():
    import os
    env=os.environ.copy();env['PHOTO_EDIT_SESSION_TOKEN']=secrets.token_hex(32)
    child=subprocess.Popen([sys.executable,'-B',str(ROOT/'engine/service.py'),'--root',str(ROOT)],
                           stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
    try:
        direct=build_opener(ProxyHandler({}))
        startup=json.loads(child.stdout.readline());base='http://127.0.0.1:'+str(startup['port'])
        try:
            direct.open(base+'/health',timeout=10)
            raise AssertionError('未授权请求不应成功')
        except HTTPError as exc:assert exc.code==403
        request=Request(base+'/health',headers={'Authorization':'Bearer '+env['PHOTO_EDIT_SESSION_TOKEN']})
        with direct.open(request,timeout=10) as response:assert not json.load(response)['missing']
    finally:
        child.stdin.close()
        child.wait(timeout=8)
        child.stdout.close();child.stderr.close()
    return dict(unauthorized_rejected=True,models_present=True,stdin_eof_stops_service=child.returncode==0)


def photo_area(image):
    width,total=image.size
    for height in range(max(1,total-int(max(width,total)*.06)-5),total+1):
        if height+int(max(width,height)*.055)==total:return image.crop((0,0,width,height))
    return image


def main(full):
    folder=ROOT/'output'/('acceptance-'+datetime.now().astimezone().strftime('%Y%m%d-%H%M%S'))
    folder.mkdir(parents=True)
    report={'status':'running','protocol':protocol_check(),'cases':{},'expanded':[]}
    def record():
        (folder/'results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    engine=Engine(ROOT)
    originals=ROOT/'cases/2026-10-27_西吉震湖/原图'
    golden=ROOT/'cases/2026-10-27_西吉震湖/定稿_发圈版v4'
    numbers=['8457','8455','8483','8462','8464','8474','8468','8467','8479']
    paths=[next(originals.glob('IMG_'+n+'.*')) for n in numbers]
    assets=[engine.import_one(p.resolve()) for p in paths]
    print('九张照片已导入',flush=True)
    reference=engine.import_one((ROOT/'cases/2026-10-27_公开测试样本/原图/Tropical-beach.jpg').resolve())
    target=assets[1]
    result=engine.match(target.id,[reference.id],deepcopy(DEFAULTS),'water')
    a,_=engine.analysis(target.id);r,_=engine.analysis(reference.id)
    before=rgb2lab(grade_array(a.image,analysis=a,**DEFAULTS))
    matched=grade_array(a.image,analysis=a,**result['params']);after=rgb2lab(matched)
    want=statistics(r.lab,r.water)['mean']
    distance_before=float(np.linalg.norm(statistics(before,a.water)['mean']-want))
    distance_after=float(np.linalg.norm(statistics(after,a.water)['mean']-want))
    safe_land=(a.water<.01)&(a.sky<.1)&(a.land>.9)
    drift=float(np.linalg.norm((after-before)[safe_land,1:],axis=-1).mean())
    quantize(matched).save(folder/'reference-match.png')
    (folder/'match-parameters.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    assert distance_after<distance_before*.7 and drift<.5
    report['cases']['0']=dict(water_delta_e_before=distance_before,water_delta_e_after=distance_after,
                              nonwater_chroma_drift=drift,passed=True)
    timings=[]
    for i in range(12):
        p=deepcopy(result['params']);p['water'][0]=50+i*.15
        start=perf_counter();response=engine.preview(target.id,p)
        with Image.open(response['preview']) as im:im.load()
        timings.append((perf_counter()-start)*1000)
    count_before=engine.analyze(target.id)['inference_count']
    engine.preview(target.id,dict(DEFAULTS,water=[55,-18,-8]))
    count_after=engine.analyze(target.id)['inference_count']
    assert max(timings)<1000 and count_before==count_after
    report['cases']['5']=dict(rounds=len(timings),p50_ms=float(np.median(timings)),p95_ms=float(np.percentile(timings,95)),
                              max_ms=max(timings),no_repeated_inference=count_before==count_after,passed=True,
                              scope='HTTP-independent engine + output encoding + image decode; UI verified separately')
    record();print('参考匹配与预览性能通过',flush=True)
    sheet=Image.new('RGB',(1200,9*215),(35,35,35));draw=ImageDraw.Draw(sheet)
    comparisons=[]
    for index,asset in enumerate(assets):
        analysis,_=engine.analysis(asset.id)
        output=grade(analysis.image,analysis=analysis,**DEFAULTS)
        output.save(folder/(asset.path.stem+'-default.png'))
        with Image.open(golden/(asset.path.stem+'.jpg')) as source:reference_photo=photo_area(source).copy()
        # 只在对照证据中对齐共同区域；导出永远不使用这个历史裁切。
        comparison=output
        if asset.path.stem=='IMG_8457':
            w,h=output.size;comparison=output.crop((int(w*.02),int(h*.06),int(w*.905),h))
        ref=reference_photo.resize(comparison.size,Image.Resampling.LANCZOS)
        mae=float(abs(np.asarray(ref,dtype=float)-np.asarray(comparison,dtype=float)).mean())
        comparisons.append(dict(name=asset.path.name,rgb_mae_to_v4=mae))
        for column,image in enumerate([ref,comparison]):
            im=image.copy();im.thumbnail((580,185));sheet.paste(im,(column*600,index*215+22))
        draw.text((5,index*215+3),asset.path.stem+'   v4 | app default',fill=(225,225,225))
        print('基线',asset.path.name,round(mae,2),flush=True)
    sheet.save(folder/'v4-comparison.jpg',quality=94)
    report['cases']['1']=dict(comparisons=comparisons,visual_review='pending',
                              note='v4 各张去雾强度不同，8457 曾裁切；这里只对照共同照片区域。')
    record()
    repair=engine.remove(assets[0].id,[.88,.30,1,1],['railing','fence'])
    Image.open(repair['source']).save(folder/'railing-repaired.png')
    Image.open(repair['mask']).save(folder/'railing-mask.png')
    report['cases']['2']=dict(repair=repair,visual_review='pending')
    portrait=engine.import_one((ROOT/'cases/2026-10-24_西夏陵与览山公园/原图/956c4f2511c0709a9c28ea309c7a3ae5.JPG').resolve())
    tower=engine.remove(portrait.id,[.64,.22,.76,.49],keep=['sky'])
    Image.open(tower['source']).save(folder/'tower-repaired.png')
    person,_=engine.analysis(portrait.id)
    base=rgb2lab(grade_array(person.image,analysis=person,**DEFAULTS))
    stats=statistics(base,person.person)
    cyan=deepcopy(DEFAULTS)
    cyan['regions']={'person':dict(mean=[float(stats['mean'][0]),-28,-20],source_mean=stats['mean'].tolist(),
                                 chroma_scale=[1,1],luma_x=[0,100],luma_y=[0,100],reference_luma_mean=float(stats['mean'][0]),strength=1,reference_count=1)}
    cyan['skin_protect']=False
    unprotected=rgb2lab(grade_array(person.image,analysis=person,**cyan))
    cyan['skin_protect']=True
    protected_rgb=grade_array(person.image,analysis=person,**cyan);protected=rgb2lab(protected_rgb)
    quantize(protected_rgb).save(folder/'skin-protected.png')
    skin=person.skin>.8
    distance=lambda lab:float(np.linalg.norm((lab-person.lab)[skin,1:],axis=-1).mean())
    unprotected_drift,protected_drift=distance(unprotected),distance(protected)
    assert skin.sum()>32 and protected_drift<unprotected_drift*.3
    report['cases']['3']=dict(skin_pixels=int(skin.sum()),chroma_drift_without=unprotected_drift,chroma_drift_with=protected_drift,
                              protection_passed=True,tower_visual_review='pending')
    print('去除与肤色测试完成，等待视觉核验',flush=True);record()
    library=ROOT/'cases/2026-10-27_公开测试样本'
    for item in json.loads((library/'sources.json').read_text()):
        path=ROOT/item['path']
        asset=engine.import_one(path.resolve())
        context,_=engine.analysis(asset.id)
        response=engine.preview(asset.id,deepcopy(DEFAULTS))
        with Image.open(response['preview']) as preview:
            assert preview.size==context.image.size
        report['expanded'].append(dict(name=path.name,scene=item['scene'],regions=context.summary(),preview_ms=response['render_ms']))
        print('扩展样本',path.name,flush=True)
    for suffix in ['.DNG','.CR2']:
        path=next((library/'原图').glob('*'+suffix));image,pixels=load_pixels(path,long=640)
        assert pixels is not None and np.unique(pixels[...,0]).size>256
        print('RAW 浮点解码通过',path.name,flush=True)
    table=base_lut(DEFAULTS);write_cube(table,folder/'global-base.cube')
    assert read_cube(folder/'global-base.cube').shape==(33,33,33,3)
    report['cases']['4']=dict(cube_format_passed=True,resolve='See separate actual Resolve load evidence')
    # 对已有照片逐个校验，包括旧定稿；新增公开样本不改变旧清单。
    manifest=json.loads((ROOT/'tmp/baseline-20261027/original-manifest.json').read_text())
    changed=[]
    for item in manifest:
        path=ROOT/item['path']
        if path.name=='.DS_Store':continue
        if sha256(path.read_bytes()).hexdigest()!=item['sha256']:changed.append(item['path'])
    assert not changed
    report['originals_unchanged']=True
    if full:
        items=[dict(id=a.id,params=deepcopy(DEFAULTS)) for a in assets]
        # 同时验证全尺寸修补，仍由同一份参数和原图重建。
        items[0]['id']=repair['id']
        start=perf_counter();export=engine.export(items,folder,dict(lut=True))
        report['full_export']=dict(**export,seconds=perf_counter()-start)
        for original,output in zip(assets,export['files']):
            source=load_image(original.path)
            with Image.open(output) as exported:assert exported.size==source.size
        print('九张全尺寸导出完成',flush=True)
    report['status']='automated_checks_passed_visual_review_pending';record()
    print('验收证据',folder,flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--full',action='store_true')
    main(parser.parse_args().full)
