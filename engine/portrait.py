"""人像：肤色保护 + 轻修饰（不替代像素蛋糕的精修）。
  skin_mask(img)                      person 遮罩 ∩ YCrCb 肤色范围，羽化
  protect_skin(orig, graded, k=0.85)  风格调色后，皮肤区域的颜色(a/b)退回原图，只保留新的亮度 → 肤色不被调青/调黄
  retouch(img, smooth=0.5, bright=0.3) 皮肤低频磨平但留纹理（导向滤波做频率分离），脸部轻提亮
"""
import numpy as np
from PIL import Image
from grade import seg_classes, rgb2lab, lab2rgb, blur, _guided
def adjust_lab(original, lab, mask, protect=False, smooth=0.0, bright=0.0):
    out=lab.copy()
    if protect:
        w=(mask*.85)[...,None]
        out[...,1:]=out[...,1:]*(1-w)+original[...,1:]*w
    if smooth or bright:
        L=out[...,0]/100; base=_guided(L,L,max(L.shape[1]//250,4),eps=2e-3)
        adjusted=base+(L-base)*(1-.6*smooth)+bright*.04*(1-L)
        out[...,0]=100*(L*(1-mask)+adjusted*mask)
    return out

def skin_mask(img):
    a=np.asarray(img.convert('RGB'),np.float64); r,g,b=a[...,0],a[...,1],a[...,2]
    Y=0.299*r+0.587*g+0.114*b; Cr=(r-Y)*0.713+128; Cb=(b-Y)*0.564+128
    skin=((Cr>135)&(Cr<180)&(Cb>85)&(Cb<135)&(Y>50)).astype(np.float64)
    person=seg_classes(img,['person'])>0.4
    m=skin*person
    return np.clip(blur(m,max(img.width//400,2))*1.4,0,1)
def protect_skin(orig, graded, k=0.85, m=None):
    m=skin_mask(orig) if m is None else m
    lo=rgb2lab(np.asarray(orig,np.float64)/255); lg=rgb2lab(np.asarray(graded,np.float64)/255)
    w=(m*k)[...,None]; out=lg.copy(); out[...,1:]=lg[...,1:]*(1-w[...,0:1])+lo[...,1:]*w[...,0:1]
    return Image.fromarray((np.clip(lab2rgb(out),0,1)*255+0.5).astype(np.uint8))
def retouch(img, smooth=0.5, bright=0.3, m=None):
    m=skin_mask(img) if m is None else m
    lab=rgb2lab(np.asarray(img.convert('RGB'),np.float64)/255); L=lab[...,0]/100
    r=max(img.width//250,4); base=_guided(L,L,r,eps=2e-3)       # edge-aware low frequency
    detail=L-base; Ls=base+detail*(1-0.6*smooth)                 # keep 40%+ of texture, never plastic
    Ls=Ls+bright*0.04*(1-Ls)                                       # gentle lift
    lab[...,0]=100*(L*(1-m)+Ls*m)
    return Image.fromarray((np.clip(lab2rgb(lab),0,1)*255+0.5).astype(np.uint8))
