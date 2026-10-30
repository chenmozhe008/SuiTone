"""生成式图片编辑适配器；当前仅供集成与模拟测试，尚未接入应用界面。"""
import base64
import binascii
from io import BytesIO
from pathlib import Path
import json
import re
from urllib.request import Request
from PIL import Image
from api_providers import _open, _send, clean_key

GEMINI_BASE = 'https://generativelanguage.googleapis.com/v1beta'


def gemini_edit(key, model, image, prompt, *, references=(), opener=_open):
    """返回图片字节；调用方负责用户授权、持久化、费用和数量控制。
    references 为额外参考图，Gemini 支持一张消息里多张输入图。"""
    key=clean_key(key) if isinstance(key,str) else ''
    if not key:raise ValueError('请先配置 Gemini API 密钥')
    if not isinstance(model,str) or not re.fullmatch(r'[A-Za-z0-9._-]{1,128}',model):raise ValueError('图片模型名称无效')
    if not isinstance(prompt,str) or not prompt.strip() or len(prompt)>8000:raise ValueError('请描述需要的图片编辑')
    references=list(references)
    if 1+len(references)>image_limit('gemini',model):raise ValueError(f'{model} 一次最多带 {image_limit("gemini",model)} 张图（含原图），现在是 {1+len(references)} 张')
    parts=[{'text':prompt}]
    for label,data in [('输入图片',image)]+[('参考图',ref) for ref in references]:
        if not isinstance(data,bytes) or not 0<len(data)<=15*1024*1024:raise ValueError(label+'大小无效')
        try:
            with Image.open(BytesIO(data)) as source:
                mime={'JPEG':'image/jpeg','PNG':'image/png'}.get(source.format)
                source.verify()
            if not mime:raise ValueError()
        except Exception:raise ValueError(label+'仅支持有效的 JPEG 或 PNG') from None
        parts.append({'inline_data':{'mime_type':mime,'data':base64.b64encode(data).decode('ascii')}})
    body={'contents':[{'role':'user','parts':parts}],
          'generationConfig':{'responseModalities':['TEXT','IMAGE']}}
    request=Request(GEMINI_BASE+'/models/'+model+':generateContent',
        data=json.dumps(body,ensure_ascii=False).encode(),method='POST',
        headers={'Content-Type':'application/json','x-goog-api-key':key})
    payload=_send(request,{'title':'Gemini'},opener,timeout=120,limit=40*1024*1024,key=key)
    try:
        response=json.loads(payload); result=[]
        for candidate in response.get('candidates',[]):
            for part in candidate.get('content',{}).get('parts',[]):
                inline=part.get('inlineData') or part.get('inline_data')
                if not inline:continue
                mime=inline.get('mimeType') or inline.get('mime_type')
                if mime not in ('image/png','image/jpeg'):continue
                data=base64.b64decode(inline['data'],validate=True)
                if len(data)>25*1024*1024:raise ValueError()
                with Image.open(BytesIO(data)) as output:
                    if (output.format == 'PNG') != (mime == 'image/png'):raise ValueError()
                    output.verify()
                result.append(dict(mime=mime,data=data))
        if not result:raise ValueError()
        return result
    except (ValueError,KeyError,TypeError,binascii.Error,OSError):
        raise ValueError('Gemini 没有返回可用图片，原照片未改变') from None


# ---------- 出图服务目录与任务 ----------
# mock 只在测试启动参数下由 App 提供，用来不花钱地跑通流程；结果是镜像翻转并压一条色带，一眼能看出是模拟图。
# 模型名单按官方文档（2026-10-30 核对）：火山方舟模型列表、Google Gemini API 模型页；第一个是默认（最新）。
IMAGE_SERVICES = {
    # 模型 ID 按火山方舟「图片生成」模型列表核对（ark.volcengine.com/docs/82379/1330310，2026-10-30）：
    # 5.0 pro / flash 不支持组图（传 sequential_image_generation 会 400），5.0 lite、4.5、4.0 支持组图。
    'jimeng': dict(title='即梦（火山方舟）', default_model='doubao-seedream-5-0-pro-260628', paid=True,
                   models=['doubao-seedream-5-0-pro-260628', 'doubao-seedream-5-0-flash-260915',
                           'doubao-seedream-5-0-260128', 'doubao-seedream-4-5-251128',
                           'doubao-seedream-4-0-250828']),
    'gemini': dict(title='Gemini', default_model='gemini-nano-banana-2.1', paid=True,
                   models=['gemini-nano-banana-2.1']),
    'mock': dict(title='模拟出图（测试用）', default_model='mock', paid=False, models=['mock']),
}


# 一次请求能带几张图（含"要改的那张原图"），数字全部照服务商官方文档，不自行放宽：
#  · 火山方舟 图片生成 API（docs.volcengine.com/docs/82379/1541523）：Seedream 5.0 pro / 5.0 flash 最多 10 张参考图；
#    Seedream 5.0 lite / 4.5 / 4.0 最多 14 张参考图。
#  · Gemini 官方模型规格：gemini-2.5-flash-image 每个提示最多 3 张图（官方限制页："在输入中最多包含三张图片"）；
#    Gemini Nano Banana 2.1 / Gemini 3 Pro Image 每个提示最多 14 张图。
OFFICIAL_IMAGE_LIMITS = {
    'doubao-seedream-5-0-pro-260628': 10,
    'doubao-seedream-5-0-flash-260915': 10,
    'doubao-seedream-5-0-260128': 14,
    'doubao-seedream-4-5-251128': 14,
    'doubao-seedream-4-0-250828': 14,
    'gemini-2.5-flash-image': 3,
    'gemini-3-pro-image': 14,
    'gemini-3-pro-image-preview': 14,
    'gemini-nano-banana-2.1': 14,
    'mock': 1,
}


def image_limit(service, model=None):
    """这个模型一次请求最多能带几张图（原图 + 参考图）。"""
    if service == 'mock': return 1
    model = model or IMAGE_SERVICES.get(service, {}).get('default_model', '')
    if model in OFFICIAL_IMAGE_LIMITS: return OFFICIAL_IMAGE_LIMITS[model]
    # 名单外的型号按官方文档的同系列规则推：拿不准就按最保守的那个系列算。
    if 'seedream-5-0-pro' in model or 'seedream-5-0-flash' in model: return 10
    if 'seedream' in model: return 14
    if '2.5-flash' in model or '2-5-flash' in model: return 3
    if 'gemini' in model: return 14
    return 1


def reference_limit(service, model=None):
    """除原图之外还能加几张参考图。"""
    return max(0, image_limit(service, model) - 1)


def reference_limits(service):
    """给界面用：这个服务每个型号能加几张参考图。

    名单里既有设置页可选推荐的型号，也包含官方文档里同系列的其他型号——手动填型号时也能查得到上限。
    """
    prefix = {'jimeng': 'doubao-', 'gemini': 'gemini-'}.get(service, service)
    models = set(IMAGE_SERVICES.get(service, {}).get('models', []))
    models.update(m for m in OFFICIAL_IMAGE_LIMITS if m.startswith(prefix))
    return {model: reference_limit(service, model) for model in sorted(models)}


def mock_edit(image_bytes, prompt):
    from PIL import ImageOps
    with Image.open(BytesIO(image_bytes)) as source:
        image = ImageOps.mirror(source.convert('RGB'))
    band = Image.new('RGB', (image.width, max(8, image.height // 12)), (200, 60, 60))
    image.paste(band, (0, image.height - band.height))
    out = BytesIO(); image.save(out, 'PNG')
    return [dict(mime='image/png', data=out.getvalue())]


def call_service(service, key, model, image_bytes, prompt, *, references=(), opener=_open):
    if service not in IMAGE_SERVICES: raise ValueError('未知的出图服务')
    if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 4000: raise ValueError('缺少生成要求')
    if service == 'mock': return mock_edit(image_bytes, prompt)
    if service == 'gemini': return gemini_edit(key, model or IMAGE_SERVICES['gemini']['default_model'], image_bytes, prompt, references=references, opener=opener)
    from jimeng_edit import jimeng_edit
    return jimeng_edit(key, model or IMAGE_SERVICES['jimeng']['default_model'], image_bytes, prompt, references=references, opener=opener)


def composite_selection(original, generated, selection):
    """只改选区：在原图原尺寸上，把选区里的部分换成生成内容，边缘羽化过渡；选区外的像素保持原样。"""
    import numpy as np
    from PIL import ImageFilter
    from inpaint import shape_mask
    generated = generated.resize(original.size, Image.Resampling.LANCZOS)
    mask = shape_mask(original, selection.get('strokes'), selection.get('radius'), selection.get('polygon'),
                      selection.get('point'), selection.get('parts'), box=None if any(selection.get(k) is not None for k in
                      ('strokes', 'polygon', 'point', 'parts')) else selection.get('box'), allow_large=True)
    if mask.max() <= 0: raise ValueError('选区是空的，请重新画选区')
    soft = Image.fromarray(np.uint8(np.clip(mask, 0, 1) * 255)).filter(ImageFilter.GaussianBlur(max(2, original.width / 400)))
    return Image.composite(generated, original, soft)


class ImageEditBridge:
    """后台出图任务：渲染当前成品（长边 2048）→ 发给所选服务 → 结果存会话目录，交给 App 采用为新版本。"""

    def __init__(self, engine):
        from threading import RLock
        self.engine = engine; self.jobs = {}; self.events = {}; self.lock = RLock()

    def start(self, data):
        from threading import Event, Thread
        from uuid import uuid4
        from service import parameters, quality_settings
        service = data.get('service')
        if service not in IMAGE_SERVICES: raise ValueError('请先选择出图服务')
        if data.get('image_consent') is not True: raise ValueError('生成新图需要先确认发送照片')
        if service != 'mock' and not clean_key(data.get('api_key') or ''): raise ValueError('请先填写出图服务的密钥')
        self.engine.asset(data['id']); parameters(data.get('params', {})); quality_settings(data.get('quality'))
        prompt = data.get('prompt')
        if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 4000: raise ValueError('缺少生成要求')
        selection = data.get('selection')
        if selection is not None:
            from service import shape_input, parts_input, repair_input
            if not isinstance(selection, dict) or set(selection) - {'box', 'strokes', 'radius', 'polygon', 'point', 'parts'}:
                raise ValueError('选区格式无效')
            if selection.get('box') is not None: repair_input(selection['box'])
            shape_input(selection.get('strokes'), selection.get('radius'), selection.get('polygon'), selection.get('point'))
            parts_input(selection.get('parts'))
        reference_paths = data.get('reference_paths') or []
        limit = reference_limit(service, data.get('model'))
        if not isinstance(reference_paths, list) or \
           any(not isinstance(p, str) or not p or len(p) > 4096 for p in reference_paths):
            raise ValueError('参考图必须是本地文件路径')
        if len(reference_paths) > limit:
            raise ValueError(f'当前模型按官方文档最多带 {limit} 张参考图（原图另计），现在是 {len(reference_paths)} 张')
        with self.lock:
            if any(j['state'] == 'running' for j in self.jobs.values()): raise ValueError('上一张还在生成，请稍候或先取消')
            key = uuid4().hex; self.jobs[key] = dict(state='running'); self.events[key] = Event()
        Thread(target=self._run, args=(key, dict(data)), daemon=True).start()
        return dict(id=key)

    def status(self, key):
        with self.lock: return dict(self.jobs.get(key, dict(state='error', error='生成任务不存在')))

    def cancel(self, key):
        with self.lock:
            if key in self.events: self.events[key].set()
        return dict(cancelled=True)

    def _load_references(self, paths):
        """参考图从本地路径读入：校验能打开，压到长边 2048 的 JPEG 再发给服务，跟主图一个待遇。"""
        out = []
        for raw in paths:
            path = Path(raw)
            if not path.is_file(): raise ValueError('参考图找不到：' + path.name)
            try:
                with Image.open(path) as img:
                    img = img.convert('RGB')
            except Exception: raise ValueError('参考图不是有效图片：' + path.name) from None
            img.thumbnail((2048, 2048), Image.Resampling.LANCZOS)
            buffer = BytesIO(); img.save(buffer, 'JPEG', quality=92)
            if len(buffer.getvalue()) > 15*1024*1024: raise ValueError('参考图太大：' + path.name)
            out.append(buffer.getvalue())
        return out

    def _run(self, key, data):
        from uuid import uuid4
        from service import replay_operations
        event = self.events[key]
        try:
            # 发不带调色的原片（保留移除杂物等修改）：生成图作为新版本后，用户的调色照常套在上面，不会叠两次。
            with self.engine.lock:
                full, _ = replay_operations(self.engine.asset(data['id']))
            full = full.convert('RGB')
            sent = full.copy(); sent.thumbnail((2048, 2048), Image.Resampling.LANCZOS)
            buffer = BytesIO(); sent.save(buffer, 'JPEG', quality=92)
            references = self._load_references(data.get('reference_paths') or [])
            if event.is_set(): raise InterruptedError()
            results = call_service(data['service'], data.get('api_key'), data.get('model'), buffer.getvalue(), data['prompt'],
                                   references=references)
            if event.is_set(): raise InterruptedError()
            paths = []
            for item in results[:4]:
                with Image.open(BytesIO(item['data'])) as out: generated = out.convert('RGB')
                if data.get('selection'): generated = composite_selection(full, generated, data['selection'])
                path = self.engine.folder / (uuid4().hex + '-generated.png')
                generated.save(path, 'PNG')
                paths.append(str(path))
            with self.lock: self.jobs[key] = dict(state='done', paths=paths)
        except InterruptedError:
            with self.lock: self.jobs[key] = dict(state='cancelled')
        except Exception as exc:
            message = str(exc) if isinstance(exc, ValueError) else '生成未完成，原照片未改变'
            with self.lock: self.jobs[key] = dict(state='error', error=message)
