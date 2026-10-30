"""为明确授权的视觉请求准备不含原始元数据的小尺寸预览。"""
from io import BytesIO

from PIL import Image, ImageDraw


MAX_ATTACHMENTS = 20
LONG_EDGE = 1024


def _jpeg(path, selection=None):
    with Image.open(path) as source:
        image = source.convert('RGB')
        image.thumbnail((LONG_EDGE, LONG_EDGE), Image.Resampling.LANCZOS)
    if selection is not None:
        width, height = image.size
        draw=ImageDraw.Draw(image);color=(255,80,30);line_width=max(2,width//250)
        point=lambda p:(round(p[0]*width),round(p[1]*height))
        if selection.get('parts'):
            # 多笔选区（有加有减）：合成真实形状后描出边缘，AI 看到的就是最终选中的范围。
            import cv2, numpy as np
            from inpaint import shape_mask
            inside=(shape_mask(image,None,None,None,None,selection['parts'],allow_large=True)>.5).astype(np.uint8)
            edge=cv2.dilate(inside,np.ones((line_width*2+1,)*2,np.uint8))-inside
            pixels=np.asarray(image).copy();pixels[edge>0]=color
            image=Image.fromarray(pixels);draw=ImageDraw.Draw(image)
        elif selection.get('strokes'):
            stroke_width=max(2,round(2*selection.get('radius',.02)*width))
            for stroke in selection['strokes']:
                points=[point(p) for p in stroke]
                if len(points)>1:draw.line(points,fill=color,width=stroke_width,joint='curve')
                for x,y in points:
                    r=stroke_width/2;draw.ellipse((x-r,y-r,x+r,y+r),fill=color)
        elif selection.get('polygon'):
            points=[point(p) for p in selection['polygon']];draw.line(points+[points[0]],fill=color,width=line_width)
        elif selection.get('point'):
            x,y=point(selection['point']);r=max(5,width//100);draw.ellipse((x-r,y-r,x+r,y+r),outline=color,width=line_width)
        else:
            box=selection['box'];draw.rectangle((*point(box[:2]),*point(box[2:])),outline=color,width=line_width)
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
            result.append(dict(label='红色标记是用户指定的选区 '+item['id'], data=_jpeg(preview, selection)))
    for reference in references:
        if cancel is not None and cancel.is_set():raise InterruptedError()
        asset = engine.asset(reference)
        result.append(dict(label='参考图 '+reference, data=_jpeg(asset.image_path)))
    return result
