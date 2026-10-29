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


def _comparison(before, after):
    """同一附件中按左前右后排列；不更改编辑结果或添加照片装饰。"""
    images=[]
    for path in (before,after):
        with Image.open(path) as source:
            image=source.convert('RGB');image.thumbnail((LONG_EDGE//2,LONG_EDGE),Image.Resampling.LANCZOS)
            images.append(image)
    canvas=Image.new('RGB',(images[0].width+images[1].width,max(i.height for i in images)),(24,24,24))
    canvas.paste(images[0],(0,0));canvas.paste(images[1],(images[0].width,0))
    result=BytesIO();canvas.save(result,format='JPEG',quality=90,optimize=True)
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
    before_by_id = {item['id']:item for item in data.get('review_before',[])}
    count = len(targets) + len(references) + (1 if selection else 0)
    if count > MAX_ATTACHMENTS:
        raise ValueError('看图一次最多发送 20 张预览，请减少所选照片或参考图')
    result = []
    for item in targets:
        if cancel is not None and cancel.is_set():raise InterruptedError()
        preview = engine.preview(item['id'], item['params'], item.get('quality'))['preview']
        if item['id'] in before_by_id:
            before=before_by_id[item['id']]
            original=engine.preview(before['source_id'],before['params'],before.get('quality'))['preview']
            result.append(dict(label='照片对照 '+item['id']+'：左侧调整前，右侧调整后',data=_comparison(original,preview)))
        else:result.append(dict(label='当前照片 '+item['id'], data=_jpeg(preview)))
        if selection and selection['id'] == item['id']:
            result.append(dict(label='红框是用户指定的选区 '+item['id'], data=_jpeg(preview, selection['box'])))
    for reference in references:
        if cancel is not None and cancel.is_set():raise InterruptedError()
        asset = engine.asset(reference)
        result.append(dict(label='参考图 '+reference, data=_jpeg(asset.image_path)))
    return result
