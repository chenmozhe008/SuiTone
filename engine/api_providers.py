"""API 密钥接入：Claude 走原生接口，其余各家走 OpenAI 兼容接口；密钥只由调用方在内存中提供。"""
import base64
import json
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

# models 只是常见的看图模型，作为默认与提示；各家改名频繁，界面可从服务商拉取完整列表或手填。
# schema=True 表示支持 json_schema 结构化输出，其余用 json_object 并把 Schema 写进提示词。
CATALOG = [
    dict(id='anthropic', title='Claude', kind='anthropic', base_url='https://api.anthropic.com/v1',
         models=['claude-sonnet-5-5', 'claude-opus-5-5', 'claude-haiku-5-5'], schema=True),
    dict(id='openai', title='OpenAI', kind='openai', base_url='https://api.openai.com/v1',
         models=['gpt-5.5', 'gpt-5.5-mini'], schema=True),
    dict(id='gemini', title='Gemini', kind='openai',
         base_url='https://generativelanguage.googleapis.com/v1beta/openai',
         models=['gemini-3-flash', 'gemini-3-pro'], schema=True),
    dict(id='qwen', title='通义千问', kind='openai', base_url='https://dashscope.aliyuncs.com/compatible-mode/v1',
         models=['qwen3-vl-plus', 'qwen3-vl-flash'], schema=False),
    dict(id='doubao', title='豆包', kind='openai', base_url='https://ark.cn-beijing.volces.com/api/v3',
         models=['doubao-seed-1-6-vision-250815'], schema=False),
    dict(id='deepseek', title='DeepSeek', kind='openai', base_url='https://api.deepseek.com',
         models=['deepseek-flash'], schema=False),
    dict(id='zhipu', title='智谱 GLM', kind='openai', base_url='https://open.bigmodel.cn/api/paas/v4',
         models=['glm-4.5v'], schema=False),
    dict(id='kimi', title='Kimi', kind='openai', base_url='https://api.moonshot.cn/v1',
         models=['kimi-latest'], schema=False),
    dict(id='custom', title='自定义（OpenAI 兼容）', kind='openai', base_url='', models=[], schema=False),
]
BY_ID = {item['id']: item for item in CATALOG}


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _open(request, timeout):
    return build_opener(_NoRedirect()).open(request, timeout=timeout)


def public_catalog():
    return [dict(id=p['id'], title=p['title'], models=p['models'], base_url=p['base_url'],
                 needs_base_url=not p['base_url']) for p in CATALOG]


def resolve(data):
    """校验并整理调用参数；返回 (provider, key, model, base_url)。"""
    provider = BY_ID.get(data.get('provider'))
    if provider is None:raise ValueError('请选择可用的对话引擎')
    key = data.get('api_key')
    if not isinstance(key, str) or not 0 < len(key.strip()) <= 512:
        raise ValueError('请先配置 '+provider['title']+' API 密钥')
    model = data.get('model') or (provider['models'][0] if provider['models'] else '')
    if not isinstance(model, str) or not 0 < len(model.strip()) <= 128:raise ValueError('请填写模型名称')
    base_url = provider['base_url'] or data.get('base_url') or ''
    if not isinstance(base_url, str) or len(base_url) > 300:raise ValueError('接口地址无效')
    parts = urlsplit(base_url.strip())
    local = parts.hostname in ('127.0.0.1', 'localhost')
    if not parts.hostname or not (parts.scheme == 'https' or (parts.scheme == 'http' and local)):
        raise ValueError('接口地址需以 https:// 开头（本机服务可用 http://localhost）')
    return provider, key.strip(), model.strip(), base_url.strip().rstrip('/')


def _name(provider):
    return provider['title'].split('（')[0]


def _send(request, provider, opener, timeout=90, limit=2*1024*1024):
    name = _name(provider)
    try:
        with opener(request, timeout=timeout) as response:
            return response.read(limit)
    except HTTPError as exc:
        if exc.code in (401, 403):raise ValueError(name+' API 密钥无效或没有权限') from None
        if exc.code == 404:raise ValueError(name+' 找不到这个模型或接口地址，请检查模型名称') from None
        if exc.code == 429:raise ValueError(name+' API 请求受限或额度不足，请稍后重试') from None
        if exc.code == 400:raise ValueError(name+' 拒绝了请求，可能是所选模型不支持看图，请换带视觉的模型') from None
        raise ValueError(name+' API 未完成请求，请检查配置或稍后重试') from None
    except (URLError, TimeoutError, OSError):
        raise ValueError('无法连接 '+name+' API，请检查网络后重试') from None


def _check(images, image_consent, cancel, provider):
    if not isinstance(image_consent, bool):raise ValueError('图片发送开关无效')
    if images and not image_consent:raise ValueError('尚未允许向 '+_name(provider)+' 发送照片')
    if cancel is not None and cancel.is_set():raise InterruptedError()


def _payload(body):
    payload = json.dumps(body, ensure_ascii=False).encode('utf-8')
    if len(payload) > 30*1024*1024:raise ValueError('图片预览过多，请减少所选照片')
    return payload


def _json_text(text):
    text = text.strip()
    if text.startswith('```'):
        text = text.split('\n', 1)[1] if '\n' in text else ''
        text = text.rsplit('```', 1)[0]
    return json.loads(text)


def invoke(data, prompt, schema, images=(), *, cancel=None, opener=_open):
    provider, key, model, base_url = resolve(data)
    image_consent = data.get('image_consent', False)
    _check(images, image_consent, cancel, provider)
    if provider['kind'] == 'anthropic':
        from anthropic_provider import invoke as claude
        return claude(key, prompt, schema, images, image_consent=image_consent, model=model,
                      cancel=cancel, opener=opener)
    content = [dict(type='text', text=prompt if provider['schema'] else
                    prompt+'\n只输出一个 JSON 对象，不要其他文字，严格符合以下 JSON Schema：\n'
                    +json.dumps(schema, ensure_ascii=False))]
    for image in images:
        content.append(dict(type='text', text=image['label']))
        content.append(dict(type='image_url', image_url=dict(
            url='data:image/jpeg;base64,'+base64.b64encode(image['data']).decode('ascii'))))
    body = dict(model=model, messages=[dict(role='user', content=content)],
                response_format=dict(type='json_schema', json_schema=dict(name='plan', strict=True, schema=schema))
                if provider['schema'] else dict(type='json_object'))
    request = Request(base_url+'/chat/completions', data=_payload(body), method='POST', headers={
        'Content-Type':'application/json', 'Authorization':'Bearer '+key})
    response_bytes = _send(request, provider, opener)
    if cancel is not None and cancel.is_set():raise InterruptedError()
    try:
        choice = json.loads(response_bytes)['choices'][0]
        if choice.get('finish_reason') not in ('stop', None):raise ValueError()
        return _json_text(choice['message']['content'])
    except (KeyError, IndexError, TypeError, ValueError, AttributeError):
        raise ValueError(_name(provider)+' 没有返回有效的调整计划') from None


def list_models(data, *, opener=_open):
    """从服务商读取可用模型名，供界面挑选；不判断是否支持看图。"""
    provider, key, _, base_url = resolve(dict(data, model=data.get('model') or 'x'))
    headers = {'anthropic-version':'2023-06-01', 'x-api-key':key} if provider['kind'] == 'anthropic' \
        else {'Authorization':'Bearer '+key}
    response_bytes = _send(Request(base_url+'/models', headers=headers), provider, opener, timeout=20)
    try:
        items = json.loads(response_bytes)['data']
        names = sorted({str(item['id']).removeprefix('models/') for item in items if item.get('id')})
    except (KeyError, TypeError, ValueError):
        raise ValueError(_name(provider)+' 没有返回模型列表，可直接填写模型名称') from None
    return dict(models=names[:300])
