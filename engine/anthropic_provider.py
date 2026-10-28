"""Claude Messages API 适配层；密钥只由调用方在内存中提供。"""
import base64
import json
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener


ENDPOINT = 'https://api.anthropic.com/v1/messages'
DEFAULT_MODEL = 'claude-sonnet-5-5'


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _open(request, timeout):
    return build_opener(_NoRedirect()).open(request, timeout=timeout)


def invoke(key, prompt, schema, images=(), *, image_consent=False,
           model=DEFAULT_MODEL, cancel=None, opener=_open):
    if not isinstance(key, str) or not key.strip():
        raise ValueError('请先配置 Claude API 密钥')
    if not isinstance(image_consent, bool):
        raise ValueError('图片发送开关无效')
    if images and not image_consent:
        raise ValueError('尚未允许向 Claude API 发送照片')
    if cancel is not None and cancel.is_set():
        raise InterruptedError()
    content = [dict(type='text', text=prompt)]
    for image in images:
        content.append(dict(type='text', text=image['label']))
        content.append(dict(type='image', source=dict(type='base64', media_type='image/jpeg',
                            data=base64.b64encode(image['data']).decode('ascii'))))
    body = dict(model=model, max_tokens=4096, messages=[dict(role='user', content=content)],
                output_config=dict(format=dict(type='json_schema', schema=schema)))
    payload = json.dumps(body, ensure_ascii=False).encode('utf-8')
    if len(payload)>30*1024*1024:
        raise ValueError('图片预览过多，请减少所选照片')
    request = Request(ENDPOINT, data=payload, method='POST', headers={
        'Content-Type':'application/json', 'anthropic-version':'2023-06-01',
        'x-api-key':key.strip(),
    })
    try:
        with opener(request, timeout=90) as response:
            response_bytes = response.read(2*1024*1024)
    except HTTPError as exc:
        if exc.code in (401, 403):raise ValueError('Claude API 密钥无效或没有权限') from None
        if exc.code == 429:raise ValueError('Claude API 请求受限，请稍后重试') from None
        raise ValueError('Claude API 未完成请求，请检查配置或稍后重试') from None
    except (URLError, TimeoutError, OSError):
        raise ValueError('无法连接 Claude API，请检查网络后重试') from None
    if cancel is not None and cancel.is_set():
        raise InterruptedError()
    try:
        result=json.loads(response_bytes)
        if result.get('stop_reason') not in ('end_turn', None):raise ValueError()
        text=next(part['text'] for part in result['content'] if part.get('type')=='text')
        return json.loads(text)
    except (KeyError, TypeError, ValueError, StopIteration):
        raise ValueError('Claude API 没有返回有效的调整计划') from None
