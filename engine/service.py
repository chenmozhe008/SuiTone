"""仅监听 loopback 的常驻服务。照片不离开本机；HTTP 需要本次启动的随机凭证。"""
import argparse
from collections import OrderedDict
from copy import deepcopy
from dataclasses import dataclass, field
from datetime import datetime
from hashlib import sha256
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import secrets
import sys
from threading import RLock, Thread
from time import perf_counter
from uuid import uuid4
import numpy as np
from PIL import Image
from analysis import Analysis
from grade import grade, grade_array, quantize
from image_io import EXTENSIONS, load_image, load_pixels, save_new
import segmentation

DEFAULTS = dict(water=[54., -17., -7.], water_var=.6, dehaze_amt=1., sky_hue=-100.,
                autumn=.25, black_white=.5, contrast=1., exposure=0., saturation=1.,
                skin_protect=True, smooth=0., bright=0., match_strength=1., enabled={}, regions={},auto_dehaze=True)
LIMITS = dict(water_var=(0, 2), dehaze_amt=(0, 1), sky_hue=(-180, 180), autumn=(0, 1),
              black_white=(0, 1), contrast=(0, 2), exposure=(-3, 3), saturation=(0, 2),
              smooth=(0, 1), bright=(0, 1), match_strength=(0, 1))


def repair_input(box,classes=None,keep=None):
    if not isinstance(box,list) or len(box)!=4 or not all(isinstance(x,(float,int)) and math.isfinite(x) and 0<=x<=1 for x in box):
        raise ValueError('框选坐标无效')
    if box[0]>=box[2] or box[1]>=box[3]: raise ValueError('请先框出要去除的位置')
    for names in [classes,keep]:
        if names is not None and (not isinstance(names,list) or not names or not all(isinstance(n,str) and n and len(n)<80 for n in names)):
            raise ValueError('请先选择要识别的类别')


def parameters(raw):
    p = deepcopy(DEFAULTS)
    if not isinstance(raw, dict) or set(raw)-set(DEFAULTS):
        raise ValueError('调色参数格式不正确')
    p.update(raw)
    if raw and 'auto_dehaze' not in raw:p['auto_dehaze']=False
    def number(value, low, high):
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value) or not low <= value <= high:
            raise ValueError('参数超出可用范围')
    for key, limits in LIMITS.items(): number(p[key], *limits)
    if not isinstance(p['skin_protect'], bool): raise ValueError('肤色开关格式不正确')
    if not isinstance(p['auto_dehaze'], bool): raise ValueError('场景建议开关格式不正确')
    if not isinstance(p['water'], list) or len(p['water']) != 3: raise ValueError('水色需要三个 Lab 数值')
    for value, limits in zip(p['water'], [(0, 100), (-128, 128), (-128, 128)]): number(value, *limits)
    if not isinstance(p['enabled'], dict) or set(p['enabled'])-{'light','color','levels','dehaze','contrast','water','sky','land','match','portrait'}:
        raise ValueError('未知调色节点')
    if any(not isinstance(v, bool) for v in p['enabled'].values()): raise ValueError('节点开关格式不正确')
    if not isinstance(p['regions'], dict) or set(p['regions'])-{'water','sky','land','person'}:
        raise ValueError('未知匹配区域')
    for region in p['regions'].values():
        if not isinstance(region, dict): raise ValueError('区域参数格式不正确')
        for key, length in [('mean',3),('source_mean',3),('chroma_scale',2)]:
            values = region.get(key)
            if not isinstance(values,list) or len(values)!=length: raise ValueError('区域数值不完整')
            for value in values: number(value,-200,200)
        for value in region['chroma_scale']: number(value,.1,3)
        x, y = region.get('luma_x'), region.get('luma_y')
        if not isinstance(x,list) or not isinstance(y,list) or len(x)!=len(y) or not 2<=len(x)<=16:
            raise ValueError('影调曲线格式不正确')
        for v in x+y: number(v,-100,200)
        if any(b<=a for a,b in zip(x,x[1:])) or any(b<a for a,b in zip(y,y[1:])):
            raise ValueError('影调曲线必须单调递增')
        number(region.get('reference_luma_mean'),0,100)
        number(region.get('strength',1),0,1)
    return p


@dataclass
class Asset:
    id: str
    path: Path
    image_path: Path
    original_path: Path
    thumbnail: Path
    fingerprint: tuple
    operations: list = field(default_factory=list)
    pixels_path: Path | None = None


class Engine:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.folder = self.root/'tmp'/('app-session-'+uuid4().hex)
        self.folder.mkdir(parents=True)
        segmentation.cache_dir = self.root/'tmp/app-cache/segmentation'
        self.assets = {}
        self.analyses = OrderedDict()
        self.previews = OrderedDict()
        self.progress = dict(done=0,total=0,name='')
        self.lock = RLock()

    def import_paths(self, paths):
        candidates = []
        for raw in paths:
            path = Path(raw).expanduser().resolve(strict=True)
            candidates.extend(sorted(p for p in path.rglob('*') if p.is_file() and p.suffix.lower() in EXTENSIONS)
                              if path.is_dir() else [path])
        photos, errors, seen = [], [], set()
        for path in candidates:
            if path in seen or path.suffix.lower() not in EXTENSIONS: continue
            seen.add(path)
            try:
                asset = self.import_one(path)
                with Image.open(asset.image_path) as image:
                    size=image.size
                    small = image.resize((16,16)).convert('L')
                values = np.asarray(small)
                bits = values>values.mean()
                similar = None
                for previous in photos:
                    if np.count_nonzero(bits ^ previous['_hash']) < 18:
                        similar = previous['id']; break
                photos.append(dict(id=asset.id, path=str(path), name=path.name,
                                   thumbnail=str(asset.thumbnail), original=str(asset.original_path),
                                   width=size[0], height=size[1], similar_to=similar, _hash=bits))
            except Exception as exc:
                errors.append(f'{path.name}：{exc}')
        for photo in photos: photo.pop('_hash')
        return dict(photos=photos, errors=errors)

    def import_one(self, path):
        stat = path.stat()
        fingerprint = (stat.st_size, stat.st_mtime_ns)
        key = sha256(str(path).encode()+str(fingerprint).encode()).hexdigest()[:24]
        if key in self.assets: return self.assets[key]
        im,pixels = load_pixels(path,long=1200)
        preview = self.folder/(key+'-source.png')
        thumb = self.folder/(key+'-thumb.jpg')
        save_new(im, preview)
        small = im.copy(); small.thumbnail((200,160))
        save_new(small, thumb)
        pixels_path=None
        if pixels is not None:
            pixels_path=self.folder/(key+'-pixels.npy')
            with pixels_path.open('xb') as handle: np.save(handle,pixels)
        asset = Asset(key,path,preview,preview,thumb,fingerprint,pixels_path=pixels_path)
        self.assets[key] = asset
        return asset

    def asset(self, key):
        if key not in self.assets: raise ValueError('照片不在当前会话，请重新导入')
        asset = self.assets[key]
        st = asset.path.stat()
        if (st.st_size,st.st_mtime_ns)!=asset.fingerprint:
            raise ValueError('源文件已改变，请重新导入，避免使用过期分析')
        return asset

    def analysis(self, key):
        asset = self.asset(key)
        if key in self.analyses:
            self.analyses.move_to_end(key)
            return self.analyses[key], True
        pixels=np.load(asset.pixels_path) if asset.pixels_path else None
        with Image.open(asset.image_path) as im: result=Analysis(im.convert('RGB'),rgb=pixels)
        self.analyses[key] = result
        while len(self.analyses)>3: self.analyses.popitem(last=False)
        return result, False

    def analyze(self, key):
        start=perf_counter(); a, cached=self.analysis(key)
        overlays={}
        for name in ['water','sky','land','person','skin']:
            path=self.folder/(key+'-'+name+'.png')
            if not path.exists(): save_new(a.overlay(name),path)
            overlays[name]=str(path)
        return dict(regions=a.summary(),overlays=overlays,cache_hit=cached,
                    analysis_ms=(perf_counter()-start)*1000,inference_count=segmentation.inference_count)

    def preview(self, key, raw):
        start=perf_counter(); p=parameters(raw)
        a,cached=self.analysis(key)
        if p['auto_dehaze']:p['dehaze_amt']=a.recommended_dehaze()
        cache_key=(key,json.dumps(p,sort_keys=True))
        self.asset(key)
        if cache_key in self.previews:
            self.previews.move_to_end(cache_key)
            return dict(preview=self.previews[cache_key],render_ms=(perf_counter()-start)*1000,
                        cache_hit=True,inference_count=segmentation.inference_count,dehaze_amt=p['dehaze_amt'])
        image=grade(a.image,analysis=a,**p)
        path=self.folder/(uuid4().hex+'.png'); save_new(image,path)
        self.previews[cache_key]=str(path)
        while len(self.previews)>64: self.previews.popitem(last=False)
        return dict(preview=str(path),render_ms=(perf_counter()-start)*1000,
                    cache_hit=cached,inference_count=segmentation.inference_count,dehaze_amt=p['dehaze_amt'])

    def match(self, key, references, raw, only=None, reference_scopes=None):
        from match import match
        target,_=self.analysis(key)
        # 先保留对象引用；LRU 淘汰只释放缓存，不会改变正在使用的分析。
        refs=[self.analysis(k)[0] for k in references]
        scopes=reference_scopes or {}
        if any(v not in ['water','sky','land','person','all'] for v in scopes.values()):
            raise ValueError('参考图适用区域无效')
        return match(target,refs,parameters(raw),only,
                     [None if scopes.get(k,'all')=='all' else scopes[k] for k in references])

    def remove(self, key, box, classes=None, keep=None):
        repair_input(box,classes,keep)
        from inpaint import remove
        asset=self.asset(key)
        with Image.open(asset.image_path) as im: image,mask=remove(im,box=tuple(box),classes=classes,keep=keep)
        if not (np.asarray(mask)>127).any():
            raise ValueError('框内没有识别到指定类别。请查看选区、调整框选位置或切换去除模式。')
        new_key=uuid4().hex
        path=self.folder/(new_key+'-source.png'); save_new(image,path)
        mask_path=self.folder/(new_key+'-repair-mask.png'); mask.save(mask_path)
        pixels_path=None
        if asset.pixels_path:
            pixels=np.load(asset.pixels_path)
            pixels=np.where((np.asarray(mask)>0)[...,None],np.asarray(image,np.float32)/255,pixels)
            pixels_path=self.folder/(new_key+'-pixels.npy')
            with pixels_path.open('xb') as handle:np.save(handle,pixels)
        self.assets[new_key]=Asset(new_key,asset.path,path,asset.original_path,asset.thumbnail,asset.fingerprint,
                                  asset.operations+[dict(box=box,classes=classes,keep=keep)],pixels_path)
        return dict(id=new_key,source=str(path),mask=str(mask_path))

    def repair_mask(self,key,box,classes=None,keep=None):
        repair_input(box,classes,keep)
        from inpaint import build_mask
        asset=self.asset(key)
        with Image.open(asset.image_path) as source:
            mask=build_mask(source,classes=classes,box=box,keep=keep)
            m=np.asarray(mask,np.float32)/255*.55
            rgb=np.asarray(source.convert('RGB'),np.float32)/255
            overlay=Image.fromarray(np.uint8(np.clip(rgb*(1-m[...,None])+np.array([.85,.35,.35])*m[...,None],0,1)*255+.5))
        if not m.any(): raise ValueError('没有识别到选定类别，请调整框选或模式')
        path=self.folder/(uuid4().hex+'-repair-overlay.png');save_new(overlay,path)
        return dict(overlay=str(path),pixels=int((m>0).sum()))

    def export(self, items, destination, options):
        if not items: raise ValueError('没有可导出的照片')
        folder=Path(destination).expanduser().resolve(strict=True)
        if not folder.is_dir(): raise ValueError('请选择导出文件夹')
        batch=folder/('photo-edit-'+datetime.now().astimezone().strftime('%Y%m%d-%H%M%S')+'-'+uuid4().hex[:6])
        batch.mkdir()
        result=[]
        self.progress=dict(done=0,total=len(items),name='准备导出')
        for item in items:
            asset=self.asset(item['id']); p=parameters(item.get('params',{}))
            self.progress=dict(done=len(result),total=len(items),name=asset.path.name)
            image,pixels=load_pixels(asset.path)
            for op in asset.operations:
                from inpaint import remove
                image,repair_mask=remove(image,**op)
                if pixels is not None: pixels=np.where((np.asarray(repair_mask)>0)[...,None],np.asarray(image,np.float32)/255,pixels)
            # 共用全图统计和缓存选区，在原尺寸逐条带计算颜色，避免 8K 照片占满内存。
            preview,_=self.analysis(asset.id)
            if options.get('denoise'):
                from enhance import denoise
                image=denoise(image)
                pixels=None
            scale=options.get('scale',1)
            if scale not in [1,2,4]: raise ValueError('放大仅支持 2 倍或 4 倍')
            if scale!=1:
                from enhance import upscale
                pixels=upscale(image,scale=scale,return_array=True)
                image=Image.fromarray(np.uint8(np.clip(pixels,0,1)*255+.5))
            from render import render_full
            rendered=render_full(image,p,preview,pixels=pixels)
            if options.get('info_bar'):
                from info_bar import with_bar,meta
                rendered=with_bar(rendered,meta(str(asset.path)),options.get('place',''))
            path=batch/(asset.path.stem+'.jpg')
            if path.exists(): path=batch/(asset.path.stem+'-'+asset.id[:6]+'.jpg')
            save_new(rendered,path)
            if options.get('lut'):
                from lut import base_lut,write_cube
                lut_path=path.with_suffix('.cube')
                with lut_path.open('x'): pass
                write_cube(base_lut(p),lut_path)
            result.append(str(path))
            self.progress=dict(done=len(result),total=len(items),name=asset.path.name)
            del rendered,image,pixels
        recipe=batch/'调整记录.photoedit'
        with recipe.open('x') as f:
            json.dump(dict(version=1,photos=[dict(path=str(self.asset(i['id']).path),params=parameters(i.get('params',{})),
                           operations=self.asset(i['id']).operations) for i in items],options=options),f,ensure_ascii=False,indent=2)
        return dict(directory=str(batch),files=result,
                    lut_note='LUT 只包含全局曝光、对比与饱和；分区、自动黑白点、去雾、修补和人像不包含在内。')


def serve(root, token, watch_stdin=True):
    engine=Engine(root)
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*args): pass
        def response(self,code,value):
            data=json.dumps(value,ensure_ascii=False,allow_nan=False).encode()
            self.send_response(code); self.send_header('Content-Type','application/json; charset=utf-8')
            self.send_header('Content-Length',str(len(data))); self.end_headers()
            try: self.wfile.write(data)
            except (BrokenPipeError,ConnectionResetError): pass
        def authorized(self):
            supplied=self.headers.get('Authorization','')
            return secrets.compare_digest(supplied,'Bearer '+token)
        def do_GET(self):
            if not self.authorized(): return self.response(403,{'error':'当前会话未授权'})
            if self.path=='/progress':return self.response(200,engine.progress)
            if self.path!='/health': return self.response(404,{'error':'未知操作'})
            cache=Path.home()/'.cache/photo-edit'
            return self.response(200,dict(ok=True,missing=[str(cache/p) for p in ['segformer/model.onnx','segformer/config.json','lama/lama_fp32.onnx'] if not (cache/p).is_file()]))
        def do_POST(self):
            if not self.authorized(): return self.response(403,{'error':'当前会话未授权'})
            try:
                length=int(self.headers.get('Content-Length','0'))
                if not 0<length<=1024*1024: raise ValueError('请求大小无效')
                data=json.loads(self.rfile.read(length))
                with engine.lock:
                    if self.path=='/import': result=engine.import_paths(data['paths'])
                    elif self.path=='/analyze': result=engine.analyze(data['id'])
                    elif self.path=='/preview': result=engine.preview(data['id'],data.get('params',{}))
                    elif self.path=='/match': result=engine.match(data['id'],data['references'],data.get('params',{}),data.get('only'),data.get('reference_scopes'))
                    elif self.path=='/remove': result=engine.remove(data['id'],data['box'],data.get('classes'),data.get('keep'))
                    elif self.path=='/repair-mask': result=engine.repair_mask(data['id'],data['box'],data.get('classes'),data.get('keep'))
                    elif self.path=='/export': result=engine.export(data['items'],data['destination'],data.get('options',{}))
                    elif self.path=='/restore':
                        asset=engine.import_one(Path(data['path']).resolve(strict=True))
                        key=asset.id
                        for operation in data.get('operations',[]): key=engine.remove(key,**operation)['id']
                        result=dict(id=key)
                    else: return self.response(404,{'error':'未知操作'})
                self.response(200,result)
            except (ValueError,KeyError,TypeError,FileNotFoundError) as exc:
                self.response(400,{'error':str(exc)})
            except Exception as exc:
                print(f'{self.path}: {type(exc).__name__}: {exc}',file=sys.stderr,flush=True)
                self.response(500,{'error':str(exc)})
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    server.daemon_threads=True
    print(json.dumps(dict(port=server.server_port,session_dir=str(engine.folder))),flush=True)
    if watch_stdin:
        def watch():
            sys.stdin.buffer.read()
            server.shutdown()
        Thread(target=watch,daemon=True).start()
    try: server.serve_forever()
    finally: server.server_close()


if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--root',required=True)
    args=parser.parse_args()
    credential=os.environ.get('PHOTO_EDIT_SESSION_TOKEN')
    if not credential or len(credential)<32: raise SystemExit('缺少本次会话凭证，请通过 App 启动')
    serve(args.root,credential)
