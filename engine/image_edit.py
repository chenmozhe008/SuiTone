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


def gemini_edit(key, model, image, prompt, *, opener=_open):
    """返回图片字节；调用方负责用户授权、持久化、费用和数量控制。"""
    key=clean_key(key) if isinstance(key,str) else ''
    if not key:raise ValueError('请先配置 Gemini API 密钥')
    if not isinstance(model,str) or not re.fullmatch(r'[A-Za-z0-9._-]{1,128}',model):raise ValueError('图片模型名称无效')
    if not isinstance(prompt,str) or not prompt.strip() or len(prompt)>8000:raise ValueError('请描述需要的图片编辑')
    if not isinstance(image,bytes) or not 0<len(image)<=15*1024*1024:raise ValueError('输入图片大小无效')
    try:
        with Image.open(BytesIO(image)) as source:
            mime={'JPEG':'image/jpeg','PNG':'image/png'}.get(source.format)
            source.verify()
        if not mime:raise ValueError()
    except Exception:raise ValueError('输入图片仅支持有效的 JPEG 或 PNG') from None
    body={'contents':[{'role':'user','parts':[{'text':prompt},
           {'inline_data':{'mime_type':mime,'data':base64.b64encode(image).decode('ascii')}}]}],
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
IMAGE_SERVICES = {
    'jimeng': dict(title='即梦（火山方舟）', default_model='doubao-seedream-4-0-250828', paid=True),
    'gemini': dict(title='Gemini', default_model='gemini-2.5-flash-image', paid=True),
    'mock': dict(title='模拟出图（测试用）', default_model='mock', paid=False),
}


def mock_edit(image_bytes, prompt):
    from PIL import ImageOps
    with Image.open(BytesIO(image_bytes)) as source:
        image = ImageOps.mirror(source.convert('RGB'))
    band = Image.new('RGB', (image.width, max(8, image.height // 12)), (200, 60, 60))
    image.paste(band, (0, image.height - band.height))
    out = BytesIO(); image.save(out, 'PNG')
    return [dict(mime='image/png', data=out.getvalue())]


def call_service(service, key, model, image_bytes, prompt, opener=_open):
    if service not in IMAGE_SERVICES: raise ValueError('未知的出图服务')
    if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 4000: raise ValueError('缺少生成要求')
    if service == 'mock': return mock_edit(image_bytes, prompt)
    if service == 'gemini': return gemini_edit(key, model or IMAGE_SERVICES['gemini']['default_model'], image_bytes, prompt, opener=opener)
    from jimeng_edit import jimeng_edit
    return jimeng_edit(key, model or IMAGE_SERVICES['jimeng']['default_model'], image_bytes, prompt, opener=opener)


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
            if event.is_set(): raise InterruptedError()
            results = call_service(data['service'], data.get('api_key'), data.get('model'), buffer.getvalue(), data['prompt'])
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
