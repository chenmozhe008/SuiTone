"""裁切与旋转：放在调色之后做，只改变出片的取景。

这样画面分析、区域识别、选区和 AI 改图仍然基于完整原图，裁切只影响最终看到的范围。
"""
import math

from PIL import Image, ImageOps


def _largest_inside(width, height, angle):
    """旋转后能放进去的最大矩形，避免四个角露出空白。

    任意角度都适用：先把角度折到 0–90°，公式本身对大于 90° 的旋转同样成立。
    """
    angle = math.radians(abs(angle) % 180)
    sin_a, cos_a = abs(math.sin(angle)), abs(math.cos(angle))
    wider = width >= height
    long_side, short_side = (width, height) if wider else (height, width)
    if short_side <= 2 * sin_a * cos_a * long_side or abs(sin_a - cos_a) < 1e-10:
        half = 0.5 * short_side
        w, h = (half / sin_a, half / cos_a) if wider else (half / cos_a, half / sin_a)
    else:
        cos_2a = cos_a * cos_a - sin_a * sin_a
        w = (width * cos_a - height * sin_a) / cos_2a
        h = (height * cos_a - width * sin_a) / cos_2a
    return max(1, int(w)), max(1, int(h))


def straighten(image, angle):
    """小角度拉直：转完按内接矩形裁掉空白。"""
    if abs(angle) < 0.01:
        return image
    rotated = image.rotate(angle, resample=Image.BICUBIC, expand=True)
    w, h = _largest_inside(image.width, image.height, angle)
    left = (rotated.width - w) // 2
    top = (rotated.height - h) // 2
    return rotated.crop((left, top, left + w, top + h))


def apply(image, params):
    """按旋转 → 拉直 → 翻转 → 裁切的顺序套用几何调整。"""
    rotation = int(params.get('rotation') or 0) % 360
    angle = float(params.get('angle') or 0)
    flip = params.get('flip') or ''
    crop = params.get('crop')
    if rotation:
        image = image.rotate(-rotation, resample=Image.BICUBIC, expand=True)
    image = straighten(image, angle)
    if flip == 'h':
        image = ImageOps.mirror(image)
    elif flip == 'v':
        image = ImageOps.flip(image)
    if crop:
        x, y, w, h = crop
        box = (round(x * image.width), round(y * image.height),
               round((x + w) * image.width), round((y + h) * image.height))
        box = (max(0, box[0]), max(0, box[1]), min(image.width, box[2]), min(image.height, box[3]))
        if box[2] - box[0] >= 8 and box[3] - box[1] >= 8:
            image = image.crop(box)
    return image


GEOMETRY_KEYS = ('rotation', 'angle', 'flip', 'crop')


def color_params(params):
    """调色只管颜色，几何字段要在渲染最后单独套用。"""
    return {key: value for key, value in params.items() if key not in GEOMETRY_KEYS}


def is_neutral(params):
    return not (int(params.get('rotation') or 0) % 360 or abs(float(params.get('angle') or 0)) >= 0.01
                or params.get('flip') or params.get('crop'))
