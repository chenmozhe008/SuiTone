"""生成式图片编辑适配器；当前仅供集成与模拟测试，尚未接入应用界面。"""
import base64
import binascii
from io import BytesIO
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
