"""即梦（火山方舟 Seedream）图片编辑适配器。

接口依据火山方舟官方文档「图片生成 API」（docs.volcengine.com/docs/82379/1541523，2026-10-30 核对）：
POST https://ark.cn-beijing.volces.com/api/v3/images/generations，Bearer 鉴权；
image 支持 Base64（data:image/<小写格式>;base64,…），response_format 支持 b64_json；
size 可写具体像素；watermark 默认 true（右下角“AI 生成”），这里关掉，免得印在用户照片上。
"""
import base64
import binascii
from io import BytesIO
import json
import re
from urllib.request import Request
from PIL import Image
from api_providers import _open, _send, clean_key

ENDPOINT = 'https://ark.cn-beijing.volces.com/api/v3/images/generations'


def output_size(width, height, long=2048):
    """按输入比例给出具体像素，长边约 2048，宽高取 8 的倍数，避免服务按默认比例改构图。
    Seedream 5.0 要求总像素在 921,600–4,624,220 之间（官方文档），细长图会低于下限，按比例放大到范围内。"""
    scale = long / max(width, height)
    w, h = width * scale, height * scale
    low, high = 921_600, 4_624_220
    if w * h < low: w, h = w * (low / (w * h)) ** .5, h * (low / (w * h)) ** .5
    if w * h > high: w, h = w * (high / (w * h)) ** .5, h * (high / (w * h)) ** .5
    w, h = max(64, int(w // 8) * 8), max(64, int(h // 8) * 8)
    while w * h < low: w, h = w + 8, h + max(8, int(8 * height / width) // 8 * 8)
    return f'{w}x{h}'


def _post(key, body, opener):
    request = Request(ENDPOINT, data=json.dumps(body, ensure_ascii=False).encode(), method='POST',
                      headers={'Content-Type': 'application/json', 'Authorization': 'Bearer '+key})
    return _send(request, {'title': '即梦'}, opener, timeout=180, limit=60*1024*1024, key=key)


def _unsupported(message):
    """服务商说某个参数不被当前模型支持时返回 True，用来决定是否退到最小请求重试。"""
    text = message.lower()
    return 'not supported' in text or 'unsupported' in text or '不支持的参数' in message


def _encode(image_bytes, label='输入图片'):
    """校验一张输入图并编成 data URI；仅接受有效的 JPEG / PNG。"""
    if not isinstance(image_bytes, bytes) or not 0 < len(image_bytes) <= 30*1024*1024: raise ValueError(label+'大小无效')
    try:
        with Image.open(BytesIO(image_bytes)) as source: mime = {'JPEG': 'jpeg', 'PNG': 'png'}.get(source.format)
    except Exception: raise ValueError(label+'仅支持有效的 JPEG 或 PNG') from None
    if not mime: raise ValueError(label+'仅支持有效的 JPEG 或 PNG')
    return 'data:image/'+mime+';base64,'+base64.b64encode(image_bytes).decode('ascii')


def jimeng_edit(key, model, image, prompt, *, references=(), opener=_open):
    """image 是要改的图；references 是额外参考图（姿势、风格、物品等），
    Seedream 的 image 参数支持数组（官方文档：最多 10 张），两张及以上时整体传列表。"""
    key = clean_key(key) if isinstance(key, str) else ''
    if not key: raise ValueError('请先填写即梦（火山方舟）的 API 密钥')
    if not isinstance(model, str) or not re.fullmatch(r'[A-Za-z0-9._-]{1,128}', model): raise ValueError('图片模型名称无效')
    if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 4000: raise ValueError('缺少生成要求')
    if not isinstance(image, bytes): raise ValueError('输入图片大小无效')
    references = list(references)
    if len(references) > 9: raise ValueError('参考图最多 9 张')
    if len(image) > 30*1024*1024: raise ValueError('输入图片大小无效')
    try:
        with Image.open(BytesIO(image)) as source: size = source.size
    except Exception: raise ValueError('输入图片仅支持有效的 JPEG 或 PNG') from None
    encoded = _encode(image)
    refs = [_encode(ref, '参考图') for ref in references]
    images = [encoded] + refs
    # 组图参数 sequential_image_generation 文档里默认就是 disabled，而且只有部分模型认这个字段，
    # 传上去会直接 400（"the parameter is not supported by the current model"），所以不传。
    body = dict(model=model, prompt=prompt, image=images if len(images) > 1 else encoded,
                size=output_size(*size), response_format='b64_json', watermark=False)
    minimal = dict(model=model, prompt=prompt, image=images if len(images) > 1 else encoded)
    try:
        payload = _post(key, body, opener)
    except ValueError as exc:
        if not _unsupported(str(exc)): raise
        # 少数模型连 watermark / size 这类可选参数也不认：只带必要字段再试一次。
        payload = _post(key, minimal, opener)
    try:
        result = []
        for item in json.loads(payload).get('data', []):
            data = base64.b64decode(item['b64_json'], validate=True)
            with Image.open(BytesIO(data)) as output:
                output.verify(); fmt = output.format
            result.append(dict(mime='image/png' if fmt == 'PNG' else 'image/jpeg', data=data))
        if not result: raise ValueError()
        return result
    except (ValueError, KeyError, TypeError, binascii.Error, OSError):
        raise ValueError('即梦没有返回可用图片，原照片未改变') from None
