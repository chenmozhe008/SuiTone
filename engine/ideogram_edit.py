"""Ideogram 4.5 Precise Edit 图片编辑。"""
from io import BytesIO
import json
from urllib.parse import urlsplit
from urllib.request import Request
from uuid import uuid4

from PIL import Image
from api_providers import _open, _send, clean_key

ENDPOINT = 'https://api.ideogram.ai/v2/image/precise-edit/ideogram-4-5'


def ideogram_edit(key, model, image, prompt, *, references=(), opener=_open):
    key = clean_key(key) if isinstance(key, str) else ''
    if not key: raise ValueError('请先配置 Ideogram API 密钥')
    if model != 'ideogram-4-5': raise ValueError('Ideogram 暂只支持 ideogram-4-5')
    if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 4000: raise ValueError('请描述需要的图片编辑')
    references = list(references)
    if len(references) > 4: raise ValueError('Ideogram 4.5 最多支持 4 张参考图')
    boundary = 'suitone-' + uuid4().hex
    pieces = []
    def field(name, data, filename=None, mime=None):
        header = f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"'
        if filename: header += f'; filename="{filename}"\r\nContent-Type: {mime}'
        pieces.extend([header.encode() + b'\r\n\r\n', data, b'\r\n'])
    field('prompt', prompt.encode('utf-8'))
    for index, data in enumerate([image] + references):
        label = '输入图片' if index == 0 else '参考图'
        if not isinstance(data, bytes) or not 0 < len(data) <= 50 * 1024 * 1024: raise ValueError(label + '大小无效')
        try:
            with Image.open(BytesIO(data)) as source:
                mime = {'JPEG': 'image/jpeg', 'PNG': 'image/png', 'WEBP': 'image/webp'}.get(source.format)
                source.verify()
            if not mime: raise ValueError()
        except Exception: raise ValueError(label + '仅支持有效的 JPEG、PNG 或 WebP') from None
        field('image' if index == 0 else 'reference_images', data, f'image{index}', mime)
    pieces.append(f'--{boundary}--\r\n'.encode())
    request = Request(ENDPOINT, data=b''.join(pieces), method='POST',
                      headers={'Api-Key': key, 'Content-Type': 'multipart/form-data; boundary=' + boundary})
    payload = _send(request, {'title': 'Ideogram'}, opener, timeout=180, limit=2*1024*1024, key=key)
    try:
        items = json.loads(payload)['data']
        if not isinstance(items, list) or not items: raise ValueError()
        results = []
        for item in items[:4]:
            url = item['url']
            parts = urlsplit(url)
            if parts.scheme != 'https' or not parts.hostname or not (parts.hostname == 'ideogram.ai' or parts.hostname.endswith('.ideogram.ai')) or parts.username or parts.password or parts.port not in (None, 443):
                raise ValueError()
            data = _send(Request(url), {'title': 'Ideogram 图片下载'}, opener, timeout=120, limit=50*1024*1024+1)
            if len(data) > 50*1024*1024: raise ValueError()
            with Image.open(BytesIO(data)) as output:
                mime = {'PNG': 'image/png', 'JPEG': 'image/jpeg', 'WEBP': 'image/webp'}.get(output.format)
                output.verify()
            if not mime: raise ValueError()
            results.append(dict(mime=mime, data=data))
        return results
    except (KeyError, TypeError, ValueError, OSError):
        raise ValueError('Ideogram 没有返回可用图片，原照片未改变') from None
