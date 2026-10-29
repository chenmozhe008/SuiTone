"""仅监听 loopback 的常驻服务。照片不离开本机；HTTP 需要本次启动的随机凭证。"""
import argparse
from collections import OrderedDict
from copy import copy, deepcopy
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
from grade import grade, grade_array, quantize, rgb2lab
from image_io import EXTENSIONS, load_image, load_pixels, save_new
import segmentation

DEFAULTS = dict(water=[54., -17., -7.], water_var=.6, dehaze_amt=1., sky_hue=-100.,
                autumn=.25, black_white=.5, contrast=1., exposure=0., saturation=1.,
                skin_protect=True, smooth=0., bright=0., match_strength=1., enabled={}, regions={},auto_dehaze=True,
                temperature=0.,tint=0.,highlights=0.,shadows=0.,effect_strength=1.,
                shadow_hue=-160.,shadow_chroma=0.,highlight_hue=65.,highlight_chroma=0.,fade=0.,
                whites=0.,blacks=0.,light=0.,vibrance=0.,texture=0.,local={})
LIMITS = dict(water_var=(0, 2), dehaze_amt=(0, 1), sky_hue=(-180, 180), autumn=(0, 1),
              black_white=(0, 1), contrast=(0, 2), exposure=(-3, 3), saturation=(0, 2),
              smooth=(0, 1), bright=(0, 1), match_strength=(0, 1),temperature=(-1,1),tint=(-1,1),
              highlights=(-1,1),shadows=(-1,1),effect_strength=(0,1),
              shadow_hue=(-180,180),shadow_chroma=(0,30),highlight_hue=(-180,180),highlight_chroma=(0,30),fade=(0,1),
              whites=(-1,1),blacks=(-1,1),light=(-1,1),vibrance=(-1,1),texture=(0,1))


def _coordinate(value):
    return isinstance(value,(float,int)) and not isinstance(value,bool) and math.isfinite(value) and 0<=value<=1


def shape_input(strokes=None,radius=None,polygon=None,point=None):
    """画笔、套索、点选的坐标都是 0–1 比例；限制数量，防止异常请求拖垮修补。"""
    if strokes is not None:
        if not isinstance(strokes,list) or not 0<len(strokes)<=60:raise ValueError('画笔轨迹无效')
        if sum(len(line) for line in strokes if isinstance(line,list))>6000:raise ValueError('画笔轨迹过长，请分几次涂抹')
        for line in strokes:
            if not isinstance(line,list) or not line or not all(isinstance(pt,list) and len(pt)==2 and all(map(_coordinate,pt)) for pt in line):
                raise ValueError('画笔轨迹无效')
        if not isinstance(radius,(int,float)) or isinstance(radius,bool) or not 0<radius<=.2:raise ValueError('笔刷大小无效')
    if polygon is not None and (not isinstance(polygon,list) or not 3<=len(polygon)<=4000 or
                                not all(isinstance(pt,list) and len(pt)==2 and all(map(_coordinate,pt)) for pt in polygon)):
        raise ValueError('套索选区无效')
    if point is not None and (not isinstance(point,list) or len(point)!=2 or not all(map(_coordinate,point))):
        raise ValueError('点选位置无效')


def repair_input(box,classes=None,keep=None):
    if not isinstance(box,list) or len(box)!=4 or not all(_coordinate(x) for x in box):
        raise ValueError('框选坐标无效')
    if box[0]>=box[2] or box[1]>=box[3]: raise ValueError('请先框出要去除的位置')
    for names in [classes,keep]:
        if names is not None and (not isinstance(names,list) or not names or not all(isinstance(n,str) and n and len(n)<80 for n in names)):
            raise ValueError('请先选择要识别的类别')


def quality_settings(raw=None):
    raw = {} if raw is None else raw
    if not isinstance(raw,dict) or set(raw)-{'denoise','scale'}:raise ValueError('画质设置格式不正确')
    denoise,scale=raw.get('denoise',False),raw.get('scale',1)
    if not isinstance(denoise,bool) or type(scale) is not int or scale not in [1,2,4]:
        raise ValueError('画质设置仅支持降噪与 2 倍、4 倍放大')
    return dict(denoise=denoise,scale=scale)


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
    from grade import LOCAL_FIELDS
    if not isinstance(p['local'], dict) or set(p['local'])-{'water','sky','land','person'}:
        raise ValueError('未知局部区域')
    for name, values in p['local'].items():
        if not isinstance(values, dict) or set(values)-set(LOCAL_FIELDS):raise ValueError('局部参数格式不正确')
        for key, value in values.items():number(value, *LOCAL_FIELDS[key])
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


def _alive(pid):
    try:os.kill(pid,0)
    except ProcessLookupError:return False
    except PermissionError:return True
    return True


def clean_temporary(tmp, cache_limit=500*1024*1024):
    """启动时清理：已退出的会话文件夹整个删掉（还在运行的其他窗口不动）；识别缓存超过上限时从最旧的删。"""
    import shutil
    for folder in tmp.glob('app-session-*'):
        try:pid=int((folder/'owner.pid').read_text())
        except (OSError,ValueError):
            try:pid=int(folder.name.removeprefix('app-session-').split('-',1)[0])
            except ValueError:continue
        if pid > 0 and not _alive(pid):shutil.rmtree(folder,ignore_errors=True)
    files=[]
    for f in (tmp/'app-cache').rglob('*'):
        try:
            if f.is_file():
                stat=f.stat();files.append((stat.st_mtime,stat.st_size,f))
        except OSError:continue
    files.sort(key=lambda item:item[0])
    total=sum(size for _,size,_ in files)
    for _,size,f in files:
        if total<=cache_limit:break
        try:f.unlink(missing_ok=True);total-=size
        except OSError:continue


class Engine:
    def __init__(self, root):
        self.root = Path(root).resolve()
        clean_temporary(self.root/'tmp')
        self.folder = self.root/'tmp'/('app-session-'+str(os.getpid())+'-'+uuid4().hex)
        self.folder.mkdir(parents=True)
        (self.folder/'owner.pid').write_text(str(os.getpid()))
        segmentation.cache_dir = self.root/'tmp/app-cache/segmentation'
        self.assets = {}
        self.analyses = OrderedDict()
        self.previews = OrderedDict()
        self.suggestion_cache = OrderedDict()
        self.quality_analyses = OrderedDict()
        self.progress = dict(done=0,total=0,name='')
        self.lock = RLock()
        from assistant import AssistantBridge
        self.assistant=AssistantBridge(self)
        from ai_recommendation import RecommendationBridge
        self.ai_recommendations=RecommendationBridge(self)
        self.import_hashes={}

    def scan_paths(self,paths):
        candidates=[];errors=[]
        for raw in paths:
            try:
                path=Path(raw).expanduser().resolve(strict=True)
                candidates.extend(sorted(p for p in path.rglob('*') if p.is_file() and p.suffix.lower() in EXTENSIONS)
                                  if path.is_dir() else [path])
            except (OSError,ValueError) as exc:errors.append(f'无法读取：{Path(raw).name}')
        return dict(paths=list(dict.fromkeys(str(p) for p in candidates if p.suffix.lower() in EXTENSIONS)),errors=errors)

    def import_paths(self, paths):
        scanned=self.scan_paths(paths)
        candidates=[Path(p) for p in scanned['paths']]
        photos, errors, seen = [], scanned['errors'], set()
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
                for previous,previous_bits in self.import_hashes.items():
                    if previous!=asset.id and np.count_nonzero(bits ^ previous_bits) < 18:
                        similar = previous; break
                self.import_hashes[asset.id]=bits
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

    def region_at(self, key, x, y):
        """在照片上点一下：返回该点所属的可靠区域，没有把握时返回空。"""
        if not all(isinstance(v,(int,float)) and not isinstance(v,bool) and 0<=v<=1 for v in (x,y)):
            raise ValueError('点选位置无效')
        a,_=self.analysis(key); summary=a.summary()
        H,W=a.water.shape; row,col=min(int(y*H),H-1),min(int(x*W),W-1)
        scores={name:float(a.region(name)[row,col]) for name in ['water','sky','land','person'] if summary[name]['available']}
        best=max(scores,key=scores.get,default='')
        return dict(region=best if best and scores[best]>=.5 else '')

    def suggestions(self, key):
        from suggestions import local_suggestions
        self.asset(key)
        if key in self.suggestion_cache:
            self.suggestion_cache.move_to_end(key)
            return dict(cards=deepcopy(self.suggestion_cache[key]), source='local', cache_hit=True)
        context,_=self.analysis(key)
        cards=local_suggestions(context)
        self.suggestion_cache[key]=deepcopy(cards)
        while len(self.suggestion_cache)>64:self.suggestion_cache.popitem(last=False)
        return dict(cards=cards, source='local', cache_hit=False)

    def apply_suggestion(self, key, card_id, raw, quality=None):
        from smart import suggest,apply_operations
        from recommendations import candidates
        self.asset(key)
        context,_=self.analysis(key)
        card=next((c for c in candidates(context) if c['id']==card_id),None)
        if card is None:raise ValueError('这张照片没有可用的此项建议')
        if card['preset']=='keep':
            params,notes=apply_operations(parameters(raw),card['adjustments'],context)
        else:
            result=suggest(context,card['preset'])
            params,notes=result['params'],result['notes']
        preview=self.preview(key,params,quality)['preview']
        return dict(params=params,title=card['title'],notes=notes,preview=preview)

    def quality_analysis(self,key,quality):
        source,cached=self.analysis(key)
        if not quality['denoise'] and quality['scale']==1:return source,cached
        cache_key=(key,quality['denoise'],quality['scale'])
        if cache_key in self.quality_analyses:
            self.quality_analyses.move_to_end(cache_key)
            return self.quality_analyses[cache_key],True
        from enhance import prepare_quality
        import cv2
        _,rgb=prepare_quality(source.image,source.rgb,**quality)
        if rgb.shape[:2]!=source.rgb.shape[:2]:
            rgb=cv2.resize(rgb,source.image.size,interpolation=cv2.INTER_AREA)
        context=copy(source)
        context.image=quantize(rgb);context.rgb=rgb;context.lab=rgb2lab(rgb)
        context.dehazed=None
        self.quality_analyses[cache_key]=context
        while len(self.quality_analyses)>3:self.quality_analyses.popitem(last=False)
        return context,False

    def preview(self, key, raw, quality=None):
        start=perf_counter(); p=parameters(raw)
        quality=quality_settings(quality)
        a,cached=self.quality_analysis(key,quality)
        if p['auto_dehaze']:p['dehaze_amt']=a.recommended_dehaze()
        cache_key=(key,json.dumps(p,sort_keys=True),quality['denoise'],quality['scale'])
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

    def smart(self,key,style='smart',quality=None):
        from smart import suggest
        context,_=self.analysis(key)
        result=suggest(context,style)
        result['preview']=self.preview(key,result['params'],quality)['preview']
        return result

    def style_tiles(self,key):
        from smart import STYLES,suggest
        from grade import rgb2lab
        import cv2
        source,_=self.analysis(key)
        image=source.image.copy();image.thumbnail((320,240))
        context=Analysis.__new__(Analysis);context.image=image
        context.rgb=cv2.resize(source.rgb,image.size,interpolation=cv2.INTER_AREA)
        context.lab=rgb2lab(context.rgb);context.dehazed=None
        for name in ['water','sky','land','person','skin']:
            setattr(context,name,cv2.resize(getattr(source,name),image.size,interpolation=cv2.INTER_AREA))
        tiles={}
        for style in STYLES:
            path=self.folder/(key+'-style-'+style['id']+'.png')
            if not path.exists():save_new(grade(image,analysis=context,**suggest(context,style['id'])['params']),path)
            tiles[style['id']]=str(path)
        return dict(tiles=tiles)

    def remove(self, key, box, classes=None, keep=None, strokes=None, radius=None, polygon=None, point=None):
        repair_input(box,classes,keep);shape_input(strokes,radius,polygon,point)
        from inpaint import remove
        asset=self.asset(key)
        with Image.open(asset.image_path) as im:
            image,mask=remove(im,box=tuple(box),classes=classes,keep=keep,strokes=strokes,radius=radius,polygon=polygon,point=point)
        if not (np.asarray(mask)>127).any():
            raise ValueError('选区里没有找到要去掉的东西。请查看选区，或换一种选法。')
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
                                  asset.operations+[{k:v for k,v in dict(box=box,classes=classes,keep=keep,strokes=strokes,
                                                    radius=radius,polygon=polygon,point=point).items() if v is not None or k=='box'}],pixels_path)
        return dict(id=new_key,source=str(path),mask=str(mask_path))

    def repair_mask(self,key,box,classes=None,keep=None,strokes=None,radius=None,polygon=None,point=None):
        repair_input(box,classes,keep);shape_input(strokes,radius,polygon,point)
        from inpaint import build_mask
        asset=self.asset(key)
        with Image.open(asset.image_path) as source:
            mask=build_mask(source,classes=classes,box=box,keep=keep,strokes=strokes,radius=radius,polygon=polygon,point=point)
            m=np.asarray(mask,np.float32)/255*.55
            rgb=np.asarray(source.convert('RGB'),np.float32)/255
            overlay=Image.fromarray(np.uint8(np.clip(rgb*(1-m[...,None])+np.array([.85,.35,.35])*m[...,None],0,1)*255+.5))
        if not m.any(): raise ValueError('没有识别到选定类别，请调整框选或模式')
        path=self.folder/(uuid4().hex+'-repair-overlay.png');save_new(overlay,path)
        return dict(overlay=str(path),pixels=int((m>0).sum()))

    def export(self, items, destination, options):
        if not items: raise ValueError('没有可导出的照片')
        output_format=options.get('format') or 'jpeg'
        if output_format not in ['jpeg','png']:raise ValueError('导出格式仅支持 JPEG 和 PNG')
        qualities=[quality_settings(i.get('quality',dict(denoise=options.get('denoise',False),scale=options.get('scale',1)))) for i in items]
        folder=Path(destination).expanduser().resolve(strict=True)
        if not folder.is_dir(): raise ValueError('请选择导出文件夹')
        batch=folder/('photo-edit-'+datetime.now().astimezone().strftime('%Y%m%d-%H%M%S')+'-'+uuid4().hex[:6])
        batch.mkdir()
        result=[]
        self.progress=dict(done=0,total=len(items),name='准备导出')
        for item,quality in zip(items,qualities):
            asset=self.asset(item['id']); p=parameters(item.get('params',{}))
            self.progress=dict(done=len(result),total=len(items),name=asset.path.name)
            image,pixels=load_pixels(asset.path)
            for op in asset.operations:
                from inpaint import remove
                image,repair_mask=remove(image,**op)
                if pixels is not None: pixels=np.where((np.asarray(repair_mask)>0)[...,None],np.asarray(image,np.float32)/255,pixels)
            # 共用全图统计和缓存选区，在原尺寸逐条带计算颜色，避免 8K 照片占满内存。
            preview,_=self.quality_analysis(asset.id,quality)
            if quality['denoise'] or quality['scale']!=1:
                from enhance import prepare_quality
                image,pixels=prepare_quality(image,pixels,**quality)
            from render import render_full
            rendered=render_full(image,p,preview,pixels=pixels)
            if options.get('info_bar'):
                from info_bar import with_bar,meta
                rendered=with_bar(rendered,meta(str(asset.path)),options.get('place',''))
            suffix='.png' if output_format=='png' else '.jpg'
            path=batch/(asset.path.stem+suffix)
            if path.exists(): path=batch/(asset.path.stem+'-'+asset.id[:6]+suffix)
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
                           operations=self.asset(i['id']).operations,quality=q) for i,q in zip(items,qualities)],
                           options={k:v for k,v in options.items() if k not in ['denoise','scale']}),f,ensure_ascii=False,indent=2)
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
            if self.path=='/assistant-providers':return self.response(200,dict(providers=engine.assistant.providers()))
            if self.path=='/styles':
                from smart import STYLES
                return self.response(200,dict(styles=[{k:style[k] for k in ['id','title','detail','family']} for style in STYLES]))
            if self.path.startswith('/assistant-status?'):
                from urllib.parse import parse_qs,urlsplit
                job=parse_qs(urlsplit(self.path).query).get('id',[''])[0]
                return self.response(200,engine.assistant.status(job))
            if self.path.startswith('/recommendation-status?'):
                from urllib.parse import parse_qs,urlsplit
                job=parse_qs(urlsplit(self.path).query).get('id',[''])[0]
                return self.response(200,engine.ai_recommendations.status(job))
            if self.path!='/health': return self.response(404,{'error':'未知操作'})
            cache=Path.home()/'.cache/photo-edit'
            return self.response(200,dict(ok=True,missing=[str(cache/p) for p in ['segformer/model.onnx','segformer/config.json','lama/lama_fp32.onnx'] if not (cache/p).is_file()]))
        def do_POST(self):
            if not self.authorized(): return self.response(403,{'error':'当前会话未授权'})
            try:
                length=int(self.headers.get('Content-Length','0'))
                if not 0<length<=1024*1024: raise ValueError('请求大小无效')
                data=json.loads(self.rfile.read(length))
                if self.path=='/assistant-models':
                    from api_providers import list_models
                    return self.response(200,list_models(data))
                with engine.lock:
                    if self.path=='/scan':result=engine.scan_paths(data['paths'])
                    elif self.path=='/import': result=engine.import_paths(data['paths'])
                    elif self.path=='/analyze': result=engine.analyze(data['id'])
                    elif self.path=='/preview': result=engine.preview(data['id'],data.get('params',{}),data.get('quality'))
                    elif self.path=='/suggestions': result=engine.suggestions(data['id'])
                    elif self.path=='/region-at': result=engine.region_at(data['id'],data['x'],data['y'])
                    elif self.path=='/suggestion-apply': result=engine.apply_suggestion(data['id'],data['card_id'],data.get('params',{}),data.get('quality'))
                    elif self.path=='/recommendation-start':result=engine.ai_recommendations.start(data)
                    elif self.path=='/recommendation-cancel':result=engine.ai_recommendations.cancel(data['id'])
                    elif self.path=='/match': result=engine.match(data['id'],data['references'],data.get('params',{}),data.get('only'),data.get('reference_scopes'))
                    elif self.path=='/smart':result=engine.smart(data['id'],data.get('style','smart'),data.get('quality'))
                    elif self.path=='/style-tiles':result=engine.style_tiles(data['id'])
                    elif self.path=='/assistant':result=engine.assistant.start(data)
                    elif self.path=='/assistant-cancel':result=engine.assistant.cancel(data['id'])
                    elif self.path=='/remove': result=engine.remove(data['id'],data['box'],data.get('classes'),data.get('keep'),
                                                                    data.get('strokes'),data.get('radius'),data.get('polygon'),data.get('point'))
                    elif self.path=='/repair-mask': result=engine.repair_mask(data['id'],data['box'],data.get('classes'),data.get('keep'),
                                                                              data.get('strokes'),data.get('radius'),data.get('polygon'),data.get('point'))
                    elif self.path=='/export': result=engine.export(data['items'],data['destination'],data.get('options',{}))
                    elif self.path=='/restore':
                        p=parameters(data.get('params',{}))
                        asset=engine.import_one(Path(data['path']).resolve(strict=True))
                        key=asset.id
                        for operation in data.get('operations',[]): key=engine.remove(key,**operation)['id']
                        result=dict(id=key,params=p)
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
