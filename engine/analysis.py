"""可复用的分区分析；滑块不触发识别，图像内容改变后才重新分析。"""
import numpy as np
from PIL import Image
from grade import rgb2lab, masks, blur
import segmentation

REGIONS = ('water', 'sky', 'land', 'person')


class Analysis:
    def __init__(self, image, rgb=None, probability_result=None):
        self.image = image
        self.rgb = np.asarray(image, np.float64) / 255 if rgb is None else rgb
        self.lab = rgb2lab(self.rgb)
        p = probability_result if probability_result is not None else segmentation.probabilities(image)
        water = segmentation.mask(image, ['water', 'sea', 'river', 'lake', 'swimming pool'], p)
        sky = segmentation.mask(image, ['sky'], p)
        self.water, self.sky = masks(image, self.lab, (water, sky))
        self.person = segmentation.mask(image, ['person'], p)
        # 建筑、车和无把握的背景不当作土地；避免参考土地把整幅城市染色。
        ground = segmentation.mask(image, ['earth', 'mountain', 'hill', 'field', 'grass', 'tree',
                                          'plant', 'sand', 'rock', 'land', 'palm'], p)
        self.land = np.clip(ground * (1 - self.water) * (1 - self.sky) * (1 - self.person), 0, 1)
        r, g, b = (self.rgb[..., i] * 255 for i in range(3))
        y = .299*r + .587*g + .114*b
        cr, cb = (r-y)*.713+128, (b-y)*.564+128
        skin = ((cr > 135) & (cr < 180) & (cb > 85) & (cb < 135) & (y > 50)) * (self.person > .4)
        self.skin = np.clip(blur(skin.astype(float), max(image.width//400, 2))*1.4, 0, 1)
        self.dehazed = None

    def region(self, name):
        return getattr(self, name)

    def recommended_dehaze(self):
        """只作初始建议：暗景轻去雾，近景减弱，开阔远景保留原强度。"""
        if np.median(self.lab[...,0])<25:return .2
        sky=float(self.sky.mean())
        if sky>=.04:return 1.0
        if sky>=.01:return .6
        return .35

    def summary(self):
        result = {}
        for name in REGIONS:
            m = self.region(name)
            selected = m > .65
            area = float(selected.mean())
            confidence = float(m[selected].mean()) if selected.any() else 0
            result[name] = {'area': area, 'confidence': confidence,
                            'available': area >= (.003 if name=='person' else .01) and confidence >= .7}
        return result

    def overlay(self, name):
        colors = {'water': (40, 190, 220), 'sky': (110, 140, 255),
                  'land': (220, 160, 60), 'person': (230, 100, 140), 'skin': (230, 100, 140)}
        m = self.region(name) * .45
        a = self.rgb*(1-m[..., None]) + np.array(colors[name])/255*m[..., None]
        return Image.fromarray(np.uint8(np.clip(a, 0, 1)*255+.5))
