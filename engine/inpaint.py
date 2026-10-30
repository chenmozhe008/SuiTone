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
from paths import ASSETS
MP=str(ASSETS/'lama'/'lama_fp32.onnx')
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
def shape_mask(img, strokes=None, radius=None, polygon=None, point=None, parts=None, box=None, allow_large=False):
    """手画选区：strokes＝画笔轨迹（比例坐标折线，radius 为笔刷半径占宽度比例）、polygon＝套索、point＝点选物体。
    parts＝多笔选区，按顺序合成：每笔是上面任一种（或 box 方框），subtract=True 的从已有选区里减掉。"""
    if parts:
        m=shape_mask(img,strokes,radius,polygon,point,allow_large=allow_large) if (strokes or polygon or point is not None) else np.zeros(img.size[::-1])
        for part in parts:
            piece=shape_mask(img,part.get('strokes'),part.get('radius'),part.get('polygon'),part.get('point'),
                             box=part.get('box'),allow_large=True)
            m=m*(1-piece) if part.get('subtract') else np.maximum(m,piece)
        return m
    from PIL import ImageDraw
    W,H=img.size; canvas=Image.new('L',(W,H),0); draw=ImageDraw.Draw(canvas)
    if box is not None:
        l,t,r,b=box;draw.rectangle((int(l*W),int(t*H),int(r*W),int(b*H)),fill=255)
    for line in strokes or []:
        r=max(1,(radius or .02)*W); pts=[(x*W,y*H) for x,y in line]
        if len(pts)>1:draw.line(pts,fill=255,width=int(2*r),joint='curve')
        for x,y in pts:draw.ellipse((x-r,y-r,x+r,y+r),fill=255)
    if polygon and len(polygon)>=3:draw.polygon([(x*W,y*H) for x,y in polygon],fill=255)
    m=np.asarray(canvas,float)/255
    if point is not None:m=np.maximum(m,object_mask(img,point,allow_large))
    return m
def object_mask(img, point, allow_large=False):
    """点一下：取该点所属类别中与点相连的那一块。大片背景（天空、地面、墙）不当作杂物。"""
    import cv2
    from segmentation import probabilities
    p,labels=probabilities(img); label=p.argmax(0)
    h,w=label.shape; x,y=point; target=label[min(int(y*h),h-1),min(int(x*w),w-1)]
    same=(label==target).astype(np.uint8)
    _,components=cv2.connectedComponents(same,connectivity=8)
    piece=(components==components[min(int(y*h),h-1),min(int(x*w),w-1)]).astype(np.float32)
    if piece.mean()>.25 and not allow_large:raise ValueError('点到的是大片背景（'+labels[int(target)].split(', ')[0]+'），不像杂物。请改用画笔涂抹')
    W,H=img.size
    return (np.asarray(Image.fromarray(piece).resize((W,H),Image.BILINEAR))>.5)*1.0
def build_mask(img, classes=None, box=None, mask=None, thr=0.35, grow=None, keep=None,
               strokes=None, radius=None, polygon=None, point=None, parts=None):
    """keep=['sky'] + box：框里除了 keep 类之外的东西都算要去掉（模型叫不出名字的物体，如信号塔被认成 building/streetlight）"""
    W,H=img.size; m=np.zeros((H,W))
    if strokes or polygon or point is not None or parts:
        m=shape_mask(img,strokes,radius,polygon,point,parts)
        # 点选的物体边缘常带一圈识别不到的暗边或影子，外扩多一些；手画的选区已由用户留了余量。
        g=grow or (max(W//100,8) if point is not None else max(W//300,4))
        return Image.fromarray((m*255).astype(np.uint8)).filter(ImageFilter.MaxFilter(2*(g//2)+1))
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
def remove(img, classes=None, box=None, mask=None, thr=0.35, win=640, keep=None, strokes=None, radius=None, polygon=None, point=None, parts=None):
    """沿遮罩滑窗、接近原分辨率逐块修补（窗口 win 缩到 512，放大倍数小 → 不糊）；后一块能看到前一块的结果"""
    img=img.convert('RGB'); W,H=img.size
    M=build_mask(img,classes,box,mask,thr,keep=keep,strokes=strokes,radius=radius,polygon=polygon,point=point,parts=parts)
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
