"""去杂物：LaMa 修补（本地 ONNX，~/.cache/photo-edit/lama/lama_fp32.onnx）。

遮罩三种来源（可叠加）：
  classes=['railing','fence','pole','person','car',...]  按物体类别自动找（SegFormer ADE20K 150 类）
  box=(l,t,r,b)  比例坐标框，只在框内找/抹（类别 + 框 = 只去掉这一处的这种东西）
  mask=灰度图     手工遮罩
  keep=['sky']+box  框里除了天空都去掉（叫不出类别名的东西用这个）
用法：
  from inpaint import remove
  out = remove(img, classes=['railing'], box=(0.9,0.5,1,1))
做法：遮罩外扩几像素 → 以遮罩为中心裁一块带上下文的方形 → 缩到 512 修补 → 放回，只替换遮罩内（羽化）。
大面积（> 画面 15%）修补会糊，宁可裁掉。
"""
import os
import numpy as np
from PIL import Image, ImageFilter
from grade import seg_classes
MP=os.path.expanduser('~/.cache/photo-edit/lama/lama_fp32.onnx')
_s=None
def _lama(img512, m512):
    global _s
    import onnxruntime as ort
    if _s is None: _s=ort.InferenceSession(MP,providers=['CPUExecutionProvider'])
    x=(np.asarray(img512,np.float32)/255).transpose(2,0,1)[None]
    m=(np.asarray(m512,np.float32)/255>0.5).astype(np.float32)[None,None]
    y=_s.run(None,{'image':x,'mask':m})[0][0].transpose(1,2,0)
    if y.max()<=1.5: y=y*255
    return Image.fromarray(np.clip(y,0,255).astype(np.uint8))
def build_mask(img, classes=None, box=None, mask=None, thr=0.35, grow=None, keep=None):
    """keep=['sky'] + box：框里除了 keep 类之外的东西都算要去掉（模型叫不出名字的物体，如信号塔被认成 building/streetlight）"""
    W,H=img.size; m=np.zeros((H,W))
    if keep and box is not None:
        l,t,r,b=box; L,T,R,B=int(W*l),int(H*t),int(W*r),int(H*b)
        crop=img.crop((L,T,R,B)); probability=seg_classes(crop,keep)
        selected=probability<0.5
        if keep==['sky']:
            # 语义模型会漏掉细天线；只补入与已识别物体连通的暗细线，不抹平云层。
            import cv2
            gray=np.asarray(crop.convert('L'))
            k=max(5,(min(crop.size)//12)|1)
            lines=cv2.morphologyEx(gray,cv2.MORPH_BLACKHAT,np.ones((k,k),np.uint8))>10
            candidates=((probability<.9)|lines).astype(np.uint8)
            candidates=cv2.dilate(candidates,np.ones((3,3),np.uint8))
            _,labels=cv2.connectedComponents(candidates,connectivity=8)
            connected=np.unique(labels[selected]);connected=connected[connected!=0]
            selected=np.isin(labels,connected)
        sub=np.zeros((H,W)); sub[T:B,L:R]=selected*1.0
        m=np.maximum(m,sub); classes=classes or None
    if classes:
        if box is not None:   # 细小物体：在框内放大后再识别，比整张图识别准得多
            l,t,r,b=box; L,T,R,B=int(W*l),int(H*t),int(W*r),int(H*b)
            sub=np.zeros((H,W)); sub[T:B,L:R]=(seg_classes(img.crop((L,T,R,B)),classes)>thr)*1.0
            m=np.maximum(m,sub)
        else: m=np.maximum(m,(seg_classes(img,classes)>thr)*1.0)
    if mask is not None: m=np.maximum(m,np.asarray(mask.convert('L').resize((W,H)),float)/255)
    if box is not None:
        bx=np.zeros((H,W)); l,t,r,b=box; bx[int(H*t):int(H*b),int(W*l):int(W*r)]=1
        m=m*bx if (classes or mask is not None or keep) else bx
    g=grow or max(W//300,4)
    return Image.fromarray((m*255).astype(np.uint8)).filter(ImageFilter.MaxFilter(2*(g//2)+1)).filter(ImageFilter.MaxFilter(2*(g//2)+1))
def remove(img, classes=None, box=None, mask=None, thr=0.35, win=640, keep=None):
    """沿遮罩滑窗、接近原分辨率逐块修补（窗口 win 缩到 512，放大倍数小 → 不糊）；后一块能看到前一块的结果"""
    img=img.convert('RGB'); W,H=img.size; M=build_mask(img,classes,box,mask,thr,keep=keep)
    todo=np.asarray(M)>127
    if not todo.any(): return img, M
    out=img.copy(); left=todo.copy(); step=win//2
    ys,xs=np.where(todo); y0,y1,x0,x1=ys.min(),ys.max(),xs.min(),xs.max()
    for T in range(max(0,y0-step//2),y1+1,step):
        for L in range(max(0,x0-step//2),x1+1,step):
            T2=min(max(0,T),max(H-win,0)); L2=min(max(0,L),max(W-win,0)); R,B=min(W,L2+win),min(H,T2+win)
            core=left[T2:B,L2:R]
            if not core.any(): continue
            crop=out.crop((L2,T2,R,B)); mc=Image.fromarray((core*255).astype(np.uint8))
            fixed=_lama(crop.resize((512,512),Image.LANCZOS),mc.resize((512,512),Image.NEAREST).filter(ImageFilter.MaxFilter(3))).resize(crop.size,Image.LANCZOS)
            feather=mc.filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.GaussianBlur(2))
            out.paste(Image.composite(fixed,crop,feather),(L2,T2)); left[T2:B,L2:R]=False
    return out, M
