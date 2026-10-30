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
    """按输入比例给出具体像素，长边约 2048，宽高取 8 的倍数，避免服务按默认比例改构图。"""
    scale = long / max(width, height)
    return f'{max(64, round(width*scale/8)*8)}x{max(64, round(height*scale/8)*8)}'


def jimeng_edit(key, model, image, prompt, *, opener=_open):
    key = clean_key(key) if isinstance(key, str) else ''
    if not key: raise ValueError('请先填写即梦（火山方舟）的 API 密钥')
    if not isinstance(model, str) or not re.fullmatch(r'[A-Za-z0-9._-]{1,128}', model): raise ValueError('图片模型名称无效')
    if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 4000: raise ValueError('缺少生成要求')
    if not isinstance(image, bytes) or not 0 < len(image) <= 30*1024*1024: raise ValueError('输入图片大小无效')
    try:
        with Image.open(BytesIO(image)) as source:
            mime = {'JPEG': 'jpeg', 'PNG': 'png'}.get(source.format); size = source.size
    except Exception: raise ValueError('输入图片仅支持有效的 JPEG 或 PNG') from None
    if not mime: raise ValueError('输入图片仅支持有效的 JPEG 或 PNG')
    body = dict(model=model, prompt=prompt, image='data:image/'+mime+';base64,'+base64.b64encode(image).decode('ascii'),
                size=output_size(*size), response_format='b64_json', sequential_image_generation='disabled', watermark=False)
    request = Request(ENDPOINT, data=json.dumps(body, ensure_ascii=False).encode(), method='POST',
                      headers={'Content-Type': 'application/json', 'Authorization': 'Bearer '+key})
    payload = _send(request, {'title': '即梦'}, opener, timeout=180, limit=60*1024*1024, key=key)
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
