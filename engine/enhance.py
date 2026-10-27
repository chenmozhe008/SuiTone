"""降噪 + 放大（本地）。
  denoise(img, strength=1.0)   夜景/高 ISO：亮度轻降、色度噪点重降（OpenCV NLMeans，保细节）
  upscale(img, scale=2|4)      Swin2SR ONNX（~/.cache/photo-edit/sr/），分块推理防爆内存；
                               x4 是 realworld 版（对手机/压缩过的图更稳），x2 是 classical 版
放大适合：裁过的小图、旧图、要打印。原图已经 4000px 的不必放大。
"""
import os
import numpy as np
from PIL import Image
SR=os.path.expanduser('~/.cache/photo-edit/sr')
def denoise(img, strength=1.0):
    import cv2
    a=cv2.cvtColor(np.asarray(img.convert('RGB')),cv2.COLOR_RGB2LAB)
    L,A,B=cv2.split(a)
    L=cv2.fastNlMeansDenoising(L,None,h=int(4*strength),templateWindowSize=7,searchWindowSize=21)
    A=cv2.fastNlMeansDenoising(A,None,h=int(10*strength),templateWindowSize=7,searchWindowSize=21)
    B=cv2.fastNlMeansDenoising(B,None,h=int(10*strength),templateWindowSize=7,searchWindowSize=21)
    return Image.fromarray(cv2.cvtColor(cv2.merge([L,A,B]),cv2.COLOR_LAB2RGB))
_s={}
def upscale(img, scale=2, tile=256, pad=16):
    import onnxruntime as ort
    f={2:'swin2SR-classical-sr-x2-64.onnx',4:'swin2SR-realworld-sr-x4-64-bsrgan-psnr.onnx'}[scale]
    if f not in _s: _s[f]=ort.InferenceSession(os.path.join(SR,f),providers=['CPUExecutionProvider'])
    s=_s[f]; a=np.asarray(img.convert('RGB'),np.float32)/255; H,W=a.shape[:2]
    out=np.zeros((H*scale,W*scale,3),np.float32)
    for y in range(0,H,tile):
        for x in range(0,W,tile):
            y0,x0=max(0,y-pad),max(0,x-pad); y1,x1=min(H,y+tile+pad),min(W,x+tile+pad)
            t=a[y0:y1,x0:x1]; h,w=t.shape[:2]; ph,pw=(-h)%8,(-w)%8
            t=np.pad(t,((0,ph),(0,pw),(0,0)),mode='reflect')
            r=s.run(None,{'pixel_values':t.transpose(2,0,1)[None]})[0][0].transpose(1,2,0)[:h*scale,:w*scale]
            oy,ox=(y-y0)*scale,(x-x0)*scale; hh,ww=min(tile,H-y)*scale,min(tile,W-x)*scale
            out[y*scale:y*scale+hh,x*scale:x*scale+ww]=r[oy:oy+hh,ox:ox+ww]
    return Image.fromarray((np.clip(out,0,1)*255+0.5).astype(np.uint8))
