"""点选语义连通区域的基础抠图；输出透明蒙版，不修改源图。"""
import numpy as np
from PIL import Image, ImageFilter


def subject_alpha(image, point):
    import cv2
    import segmentation
    p, labels = segmentation.probabilities(image)
    h, w = p.shape[1:]
    x, y = min(int(point[0]*w),w-1), min(int(point[1]*h),h-1)
    target = int(p[:,y,x].argmax())
    name = labels[target].split(', ')[0]
    background = {'sky','wall','floor','road','earth','water','sea','river','lake','field','mountain','building'}
    if name in background:
        raise ValueError('这里更像背景，请点选人物或清晰的物体')
    mask = (p.argmax(0)==target).astype(np.uint8)
    _, components = cv2.connectedComponents(mask, connectivity=8)
    region = components==components[y,x]
    if region.mean()<.001 or region.mean()>.98 or float(p[target][region].mean())<.45:
        raise ValueError('主体识别不够可靠，请换一个位置点选')
    alpha = Image.fromarray(np.uint8(region*255)).resize(image.size, Image.Resampling.BILINEAR)
    return alpha.filter(ImageFilter.GaussianBlur(.6))
