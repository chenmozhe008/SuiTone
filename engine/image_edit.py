"""生成式图片编辑适配器。"""
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


def gemini_edit(key, model, image, prompt, *, references=(), aspect_ratio=None, opener=_open):
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
    if aspect_ratio:
        if aspect_ratio not in IMAGE_RATIOS: raise ValueError('不支持的生成比例')
        body['generationConfig']['imageConfig'] = {'aspectRatio': aspect_ratio}
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
    'ideogram': dict(title='Ideogram', default_model='ideogram-4-5', paid=True, models=['ideogram-4-5']),
    'mock': dict(title='模拟出图（测试用）', default_model='mock', paid=False, models=['mock']),
}

IMAGE_RATIOS = ('1:1', '3:2', '2:3', '4:3', '3:4', '5:4', '4:5', '16:9', '9:16', '21:9')


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
    'ideogram-4-5': 5,
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


def call_service(service, key, model, image_bytes, prompt, *, references=(), aspect_ratio=None, mask=None, opener=_open):
    if service not in IMAGE_SERVICES: raise ValueError('未知的出图服务')
    if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 4000: raise ValueError('缺少生成要求')
    if aspect_ratio and (aspect_ratio not in IMAGE_RATIOS or service == 'ideogram'):
        raise ValueError('当前服务不支持这个生成比例')
    if service == 'mock':
        results = mock_edit(image_bytes, prompt)
        if aspect_ratio:
            from PIL import ImageOps
            w, h = map(int, aspect_ratio.split(':'))
            with Image.open(BytesIO(results[0]['data'])) as source:
                out = ImageOps.fit(source, (w * 64, h * 64))
                buf = BytesIO(); out.save(buf, 'PNG')
            results[0]['data'] = buf.getvalue()
        return results
    if service == 'ideogram':
        from ideogram_edit import ideogram_edit
        return ideogram_edit(key, model or IMAGE_SERVICES['ideogram']['default_model'], image_bytes, prompt, references=references, mask=mask, opener=opener)
    if service == 'gemini': return gemini_edit(key, model or IMAGE_SERVICES['gemini']['default_model'], image_bytes, prompt, references=references, aspect_ratio=aspect_ratio, opener=opener)
    from jimeng_edit import jimeng_edit
    return jimeng_edit(key, model or IMAGE_SERVICES['jimeng']['default_model'], image_bytes, prompt, references=references, aspect_ratio=aspect_ratio, opener=opener)


def selection_mask(image, selection):
    """把多笔选择合成与输入照片对齐的二值蒙版。"""
    import numpy as np
    from inpaint import shape_mask
    mask = shape_mask(image, selection.get('strokes'), selection.get('radius'), selection.get('polygon'),
                      selection.get('point'), selection.get('parts'), box=None if any(selection.get(k) is not None for k in
                      ('strokes', 'polygon', 'point', 'parts')) else selection.get('box'), allow_large=True)
    hard = np.asarray(mask) > .5
    if not hard.any(): raise ValueError('选区是空的，请重新画选区')
    return hard


def prompt_for_selection(prompt, hard):
    """为没有原生蒙版参数的服务提供大致位置，让模型结合整张图完成编辑。"""
    import numpy as np
    ys = np.flatnonzero(np.any(hard, axis=1))
    xs = np.flatnonzero(np.any(hard, axis=0))
    h, w = hard.shape
    x0, x1 = round(100 * xs[0] / w), round(100 * (xs[-1] + 1) / w)
    y0, y1 = round(100 * ys[0] / h), round(100 * (ys[-1] + 1) / h)
    hint = (f"\n用户选定的位置约在画面左起 {x0}%–{x1}%、上起 {y0}%–{y1}%。"
            "请结合整张照片理解并完成编辑，生成的物体及其阴影、倒影可以自然延伸到选区外，"
            "保持物体完整；其余画面尽量不变，并与原有光线、色彩、透视和纹理协调。")
    return prompt + hint if len(prompt) + len(hint) <= 4000 else prompt


def jimeng_supports_interactive(model):
    model = (model or IMAGE_SERVICES['jimeng']['default_model']).lower()
    return model.startswith(('doubao-seedream-5-0-pro', 'doubao-seedream-5-0-flash'))


def jimeng_interactive_prompt(prompt, hard, selection, model, guidance='coordinates'):
    """5.0 Pro / Flash 接受归一化坐标标签；其他型号沿用自然语言定位。"""
    import numpy as np
    if not jimeng_supports_interactive(model):
        return prompt_for_selection(prompt, hard)
    if guidance == 'marked':
        hint = ('\n以图1中青色轮廓标记的区域作为编辑位置，结合整张照片完成要求；'
                '删除所有青色标记，保持原有构图、光线、色彩和背景，其余内容尽量不变。')
        if len(prompt) + len(hint) > 4000: raise ValueError('编辑要求过长，请缩短后再使用选区改图')
        return prompt + hint
    parts = selection.get('parts')
    point = None
    if parts is not None:
        if len(parts) == 1 and not parts[0].get('subtract'):
            point = parts[0].get('point')
    else:
        point = selection.get('point')
    normalized = lambda value: max(0, min(999, round(value * 1000)))
    if point is not None:
        location = f'<point>{normalized(point[0])} {normalized(point[1])}</point>'
    else:
        ys = np.flatnonzero(np.any(hard, axis=1))
        xs = np.flatnonzero(np.any(hard, axis=0))
        h, w = hard.shape
        x0, y0 = normalized(xs[0] / w), normalized(ys[0] / h)
        x1, y1 = normalized((xs[-1] + 1) / w), normalized((ys[-1] + 1) / h)
        location = f'<bbox>{x0} {y0} {x1} {y1}</bbox>'
    hint = (f'\n以图1 {location} 为编辑位置，结合整张照片完成要求；'
            '保持其余画面和原有光线、色彩、透视协调，物体和必要的阴影、倒影保持完整。')
    if len(prompt) + len(hint) > 4000:
        raise ValueError('编辑要求过长，请缩短后再使用选区改图')
    return prompt + hint


def marked_selection_image(image, hard):
    """只在发给服务的副本上描出选区，原图及本地合成底图不带标记。"""
    import cv2
    import numpy as np
    w, h = image.size
    stencil = cv2.resize(hard.astype(np.uint8), (w, h), interpolation=cv2.INTER_NEAREST)
    contours, _ = cv2.findContours(stencil, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    marked = np.asarray(image.convert('RGB')).copy()
    cv2.drawContours(marked, contours, -1, (0, 230, 255), max(2, round(min(w, h) / 350)))
    return Image.fromarray(marked, 'RGB')


def composite_selection(original, generated, selection, *, hard=None):
    """将生成结果限制在选区内，按边界附近的色差做渐变衔接。"""
    import cv2
    import numpy as np
    original = original.convert('RGB')
    generated = generated.convert('RGB').resize(original.size, Image.Resampling.LANCZOS)
    if hard is None: hard = selection_mask(original, selection)
    if not hard.any(): raise ValueError('选区是空的，请重新画选区')

    # 在缩略图上估计局部色差，避免大照片产生数倍内存；最终仅在选区内混合。
    w, h = original.size
    scale = min(1., 1536 / max(w, h))
    sw, sh = max(1, round(w * scale)), max(1, round(h * scale))
    original_small = np.asarray(original.resize((sw, sh), Image.Resampling.LANCZOS), np.float32)
    generated_small = np.asarray(generated.resize((sw, sh), Image.Resampling.LANCZOS), np.float32)
    mask_small = (cv2.resize(hard.astype(np.float32), (sw, sh), interpolation=cv2.INTER_AREA) > 0).astype(np.uint8)
    # 图片边缘不是拼接边界；只对选区与原图交界的内侧做羽化。
    padded = np.pad(mask_small, 1, constant_values=1)
    distance = cv2.distanceTransform(padded, cv2.DIST_L2, 3)[1:-1, 1:-1]
    feather = max(4., min(32., min(sw, sh) * .018))
    t = np.clip(distance / feather, 0, 1)
    alpha = (t * t * (3 - 2 * t)) * mask_small
    edge_weight = ((distance > 0) & (distance <= 2 * feather)).astype(np.float32)
    sigma = max(3., feather * 1.5)
    weight = cv2.GaussianBlur(edge_weight, (0, 0), sigma)
    correction = np.zeros_like(generated_small)
    for channel in range(3):
        delta = (original_small[:, :, channel] - generated_small[:, :, channel]) * edge_weight
        smooth = cv2.GaussianBlur(delta, (0, 0), sigma)
        correction[:, :, channel] = np.clip(smooth / np.maximum(weight, 1e-5), -24, 24)
    fade = np.clip(1 - distance / (3 * feather), 0, 1) * mask_small
    correction *= fade[:, :, None]
    alpha_full = cv2.resize(alpha, (w, h), interpolation=cv2.INTER_LINEAR)
    alpha_full *= hard
    result = np.asarray(original).copy()
    # 分块插值和混合，避免原图尺寸较大时产生多个全幅浮点 RGB 副本。
    correction = cv2.resize(np.uint8(np.clip(correction + 128, 0, 255)), (w, h), interpolation=cv2.INTER_LINEAR)
    source = np.asarray(generated)
    for top in range(0, h, 512):
        bottom = min(h, top + 512)
        blend = alpha_full[top:bottom, :, None]
        edited = np.clip(source[top:bottom].astype(np.float32) + correction[top:bottom].astype(np.float32) - 128, 0, 255)
        result[top:bottom] = np.uint8(np.clip(result[top:bottom] * (1 - blend) + edited * blend + .5, 0, 255))
    return Image.fromarray(result, 'RGB')


def composite_guided_selection(original, generated, hard):
    """选区及附近保留生成内容，远处保留当前画面；边缘渐变过渡。"""
    import cv2
    import numpy as np
    original = original.convert('RGB')
    generated = generated.convert('RGB').resize(original.size, Image.Resampling.LANCZOS)
    h, w = hard.shape
    ys, xs = np.nonzero(hard)
    if not len(xs): raise ValueError('选区是空的，请重新画选区')
    # 留出适度的构图和羽化余量；距离远的区域严格保留原像素。
    radius = max(8., min(.18 * min(w, h), float(max(xs.max()-xs.min()+1, ys.max()-ys.min()+1))))
    outside = cv2.distanceTransform((~hard).astype(np.uint8), cv2.DIST_L2, 5)
    feather = max(3., radius * .25)
    alpha = np.clip((radius - outside) / feather, 0, 1)
    alpha = alpha * alpha * (3 - 2 * alpha)
    result = np.asarray(original).copy()
    source = np.asarray(generated)
    # 找与选区相连、明显超出选区的变化，避免帆、杆等被固定羽化范围截断。
    # 仅采用面积受限的高对比连通块；无法可靠识别语义，远处依旧以原图为准。
    sw = min(800, w); sh = max(1, round(h * sw / w))
    before = cv2.resize(result, (sw, sh), interpolation=cv2.INTER_AREA)
    after = cv2.resize(source, (sw, sh), interpolation=cv2.INTER_AREA)
    selected = cv2.resize(hard.astype(np.uint8), (sw, sh), interpolation=cv2.INTER_NEAREST)
    changes = (np.max(np.abs(before.astype(np.int16) - after.astype(np.int16)), axis=2) > 60).astype(np.uint8)
    changes = cv2.morphologyEx(changes, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))
    count, labels, stats, _ = cv2.connectedComponentsWithStats(changes)
    extensions = np.zeros_like(selected)
    for label in np.unique(labels[(selected > 0) & (labels > 0)]):
        area = int(stats[label, cv2.CC_STAT_AREA])
        if area < 100 or area > .12 * sw * sh: continue
        component = labels == label
        outside_area = np.count_nonzero(component & (selected == 0))
        if outside_area and outside_area <= .08 * sw * sh:
            extensions[component] = 1
    if extensions.any():
        extension = cv2.resize(extensions, (w, h), interpolation=cv2.INTER_NEAREST)
        distance = cv2.distanceTransform(1 - extension, cv2.DIST_L2, 5)
        margin = max(3., min(32., min(w, h) * .012))
        extra = np.clip((margin - distance) / max(2., margin * .6), 0, 1)
        alpha = np.maximum(alpha, extra * extra * (3 - 2 * extra))
    # 以选区外的周边作为参照，估计生成图整体色偏；中位数降低新物体和纹理的干扰。
    # 只作小幅修正，避免把生成主体的固有颜色强行变成背景色。
    ring = (outside >= radius * .45) & (outside <= radius * .95)
    rows, cols = np.nonzero(ring)
    correction = np.zeros(3, dtype=np.float32)
    if len(rows) >= 64:
        step = max(1, len(rows) // 50000)
        delta = result[rows[::step], cols[::step]].astype(np.float32) - source[rows[::step], cols[::step]].astype(np.float32)
        correction = np.clip(np.median(delta, axis=0), -18, 18)
    for top in range(0, h, 512):
        bottom = min(h, top + 512)
        blend = alpha[top:bottom, :, None]
        adjusted = np.clip(source[top:bottom].astype(np.float32) + correction, 0, 255)
        result[top:bottom] = np.uint8(np.clip(result[top:bottom] * (1-blend) + adjusted * blend + .5, 0, 255))
    return Image.fromarray(result, 'RGB')


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
        self.engine.asset(data['id']); params = parameters(data.get('params', {})); quality_settings(data.get('quality'))
        prompt = data.get('prompt')
        if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 4000: raise ValueError('缺少生成要求')
        selection = data.get('selection')
        guidance = data.get('selection_guidance', 'coordinates')
        if guidance not in ('coordinates', 'marked'): raise ValueError('选区定位方式无效')
        if guidance == 'marked' and (selection is None or service != 'jimeng' or not jimeng_supports_interactive(data.get('model'))):
            raise ValueError('当前模型不支持画线标记定位')
        aspect_ratio = data.get('aspect_ratio') or None
        if aspect_ratio and (aspect_ratio not in IMAGE_RATIOS or service == 'ideogram'):
            raise ValueError('当前服务不支持这个生成比例')
        if aspect_ratio and selection is not None: raise ValueError('参考选区时必须保持原图比例')
        if selection is not None:
            from service import shape_input, parts_input, repair_input
            if not isinstance(selection, dict) or set(selection) - {'box', 'strokes', 'radius', 'polygon', 'point', 'parts'}:
                raise ValueError('选区格式无效')
            if selection.get('box') is not None: repair_input(selection['box'])
            shape_input(selection.get('strokes'), selection.get('radius'), selection.get('polygon'), selection.get('point'))
            parts_input(selection.get('parts'))
        reference_paths = data.get('reference_paths') or []
        limit = reference_limit(service, data.get('model'))
        if service == 'ideogram' and selection is not None: limit = min(limit, 3)
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
        """参考图从本地路径读入：校验能打开，压到长边 2048 的 JPEG 再发给服务，跟主图一个待遇。

        走 image_io.load_image：HEIC / HEIF（iPhone 默认格式）和 RAW 也能读，色彩也跟主图一致。
        """
        from image_io import load_image
        out = []
        for raw in paths:
            path = Path(raw)
            if not path.is_file(): raise ValueError('参考图找不到：' + path.name)
            try:
                img = load_image(path, long=2048)
            except Exception: raise ValueError('参考图打不开：' + path.name) from None
            buffer = BytesIO(); img.save(buffer, 'JPEG', quality=92)
            if len(buffer.getvalue()) > 15*1024*1024: raise ValueError('参考图太大：' + path.name)
            out.append(buffer.getvalue())
        return out

    def _run(self, key, data):
        from uuid import uuid4
        event = self.events[key]
        try:
            # 完整渲染当前画面，生成版本采用时重置参数，避免重复应用。
            with self.engine.lock:
                rendered = self.engine.render_full_png(data['id'], data.get('params', {}), data.get('quality'))
            with Image.open(rendered['path']) as image:
                full = image.convert('RGB')
            selection = data.get('selection')
            hard = selection_mask(full, selection) if selection else None
            sent = full.copy(); sent.thumbnail((2048, 2048), Image.Resampling.LANCZOS)
            if hard is not None and data.get('selection_guidance') == 'marked':
                sent = marked_selection_image(sent, hard)
            buffer = BytesIO(); sent.save(buffer, 'JPEG', quality=92)
            references = self._load_references(data.get('reference_paths') or [])
            native_mask = None
            if hard is not None and data['service'] == 'ideogram':
                import numpy as np
                selected = Image.fromarray(np.uint8(hard) * 255, 'L').resize(sent.size, Image.Resampling.NEAREST)
                # Ideogram: 黑色修改，白色保留。
                native = Image.fromarray(255 - np.asarray(selected), 'L')
                if native.getextrema() != (0, 255):
                    raise ValueError('选区过小或覆盖整张照片，请调整选区后重试')
                out = BytesIO(); native.save(out, 'PNG'); native_mask = out.getvalue()
            if event.is_set(): raise InterruptedError()
            prompt = data['prompt']
            if hard is not None and data['service'] == 'jimeng':
                prompt = jimeng_interactive_prompt(prompt, hard, selection, data.get('model'), data.get('selection_guidance', 'coordinates'))
            elif hard is not None and data['service'] == 'gemini':
                prompt = prompt_for_selection(prompt, hard)
            results = call_service(data['service'], data.get('api_key'), data.get('model'), buffer.getvalue(), prompt,
                                   references=references, aspect_ratio=data.get('aspect_ratio') or None, mask=native_mask)
            if event.is_set(): raise InterruptedError()
            paths = []
            raw_paths = []
            for item in results[:4]:
                with Image.open(BytesIO(item['data'])) as out: generated = out.convert('RGB')
                if selection:
                    raw_path = self.engine.folder / (uuid4().hex + '-model-raw.png')
                    generated.save(raw_path, 'PNG')
                    raw_paths.append(str(raw_path))
                if selection:
                    if data['service'] in ('jimeng', 'gemini'):
                        generated = composite_guided_selection(full, generated, hard)
                    else:
                        generated = composite_selection(full, generated, selection, hard=hard)
                path = self.engine.folder / (uuid4().hex + '-generated.png')
                generated.save(path, 'PNG')
                paths.append(str(path))
            with self.lock: self.jobs[key] = dict(state='done', paths=paths, raw_paths=raw_paths,
                                                   before_path=rendered['path'] if selection else None)
        except InterruptedError:
            with self.lock: self.jobs[key] = dict(state='cancelled')
        except Exception as exc:
            message = str(exc) if isinstance(exc, ValueError) else '生成未完成，原照片未改变'
            with self.lock: self.jobs[key] = dict(state='error', error=message)
