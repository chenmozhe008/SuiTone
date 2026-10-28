"""为明确授权的视觉请求准备不含原始元数据的小尺寸预览。"""
from io import BytesIO

from PIL import Image, ImageDraw


MAX_ATTACHMENTS = 20
LONG_EDGE = 1024


def _jpeg(path, box=None):
    with Image.open(path) as source:
        image = source.convert('RGB')
        image.thumbnail((LONG_EDGE, LONG_EDGE), Image.Resampling.LANCZOS)
    if box is not None:
        width, height = image.size
        coords = (round(box[0]*width), round(box[1]*height),
                  round(box[2]*width), round(box[3]*height))
        ImageDraw.Draw(image).rectangle(coords, outline=(255, 80, 30), width=max(2, width//250))
    result = BytesIO()
    image.save(result, format='JPEG', quality=90, optimize=True)
    return result.getvalue()


def prepare_images(engine, data, cancel=None):
    """只按会话资产 ID 取得图像；关闭授权时甚至不触碰图像内容。"""
    consent = data.get('image_consent', False)
    if not isinstance(consent, bool):
        raise ValueError('图片发送开关无效')
    if not consent:
        return []
    targets = data['targets']
    references = data.get('reference_ids', [])
    selection = data.get('repair_selection')
    count = len(targets) + len(references) + (1 if selection else 0)
    if count > MAX_ATTACHMENTS:
        raise ValueError('看图一次最多发送 20 张预览，请减少所选照片或参考图')
    result = []
    for item in targets:
        if cancel is not None and cancel.is_set():raise InterruptedError()
        preview = engine.preview(item['id'], item['params'], item.get('quality'))['preview']
        result.append(dict(label='当前照片 '+item['id'], data=_jpeg(preview)))
        if selection and selection['id'] == item['id']:
            result.append(dict(label='红框是用户指定的选区 '+item['id'], data=_jpeg(preview, selection['box'])))
    for reference in references:
        if cancel is not None and cancel.is_set():raise InterruptedError()
        asset = engine.asset(reference)
        result.append(dict(label='参考图 '+reference, data=_jpeg(asset.image_path)))
    return result
