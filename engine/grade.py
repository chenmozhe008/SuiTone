"""photo-edit 调色：节点式、分区（AI 遮罩）、全程 Lab + float，不出断层。

节点顺序（对应达芬奇思路）：
  1 一级：黑白点        2 去雾：暗通道 + 导向滤波（整张图统一，天空只给一半）
  3 对比曲线 + 轻微局部对比
  4 水：锁到一个绝对目标色（多张统一），保留原有明暗/波纹，高光碎光不动
  5 天：色相拉向干净蓝，轻微加深       6 土地：秋叶提饱和、绿色收向橄榄、暗坡回暖
用法：
  from grade import grade, load
  out = grade(load('IMG_1.jpg'), water=(54,-17,-7), dehaze=1.0)
  近景/俯拍（雾很薄）dehaze 给 0.35–0.6，大远景 1.0。
遮罩模型：SegFormer-B2 ADE20K ONNX，放在 ~/.cache/photo-edit/segformer/（model.onnx + config.json）。
  缺失时：curl -x http://127.0.0.1:7897 -L -o model.onnx https://huggingface.co/Xenova/segformer-b2-finetuned-ade-512-512/resolve/main/onnx/model.onnx （config.json 同路径）
"""
import os, json
import numpy as np
from PIL import Image, ImageOps, ImageFilter

MD=os.path.expanduser('~/.cache/photo-edit/segformer')

# ---------- basics ----------
_M=np.array([[0.4124,0.3576,0.1805],[0.2126,0.7152,0.0722],[0.0193,0.1192,0.9505]]); _Mi=np.linalg.inv(_M); _WP=np.array([0.95047,1.0,1.08883])
def _lin(c): return np.where(c<=0.04045,c/12.92,((c+0.055)/1.055)**2.4)
def _gam(c): c=np.clip(c,0,1); return np.where(c<=0.0031308,c*12.92,1.055*c**(1/2.4)-0.055)
def rgb2lab(a):
    x=_lin(a)@_M.T/_WP; f=np.where(x>0.008856,np.cbrt(x),7.787*x+16/116)
    return np.stack([116*f[...,1]-16,500*(f[...,0]-f[...,1]),200*(f[...,1]-f[...,2])],-1)
def lab2rgb(l):
    fy=(l[...,0]+16)/116; fx=fy+l[...,1]/500; fz=fy-l[...,2]/200; f=np.stack([fx,fy,fz],-1)
    return _gam(np.where(f**3>0.008856,f**3,(f-16/116)/7.787)*_WP@_Mi.T)
def ss(x,a,b): t=np.clip((x-a)/(b-a),0,1); return t*t*(3-2*t)
def blur(m,r):
    H,W=m.shape; k=max(int(r),1)
    return np.asarray(Image.fromarray(m.astype(np.float32),'F').resize((max(W//k,2),max(H//k,2)),Image.BOX).resize((W,H),Image.BICUBIC))
def hue_pull(A,B,deg,k,w):
    C=np.hypot(A,B); h=np.arctan2(B,A); d=np.angle(np.exp(1j*(np.deg2rad(deg)-h))); h2=h+k*w*d
    return C*np.cos(h2), C*np.sin(h2)
def load(path, crop=None, long=4032):
    """crop = (l,t,r,b) fractions; HEIC 先用 sips 转 jpg"""
    im=ImageOps.exif_transpose(Image.open(path)).convert('RGB')
    if crop: W,H=im.size; im=im.crop((int(W*crop[0]),int(H*crop[1]),int(W*crop[2]),int(H*crop[3])))
    s=long/max(im.size)
    return im.resize((int(im.width*s),int(im.height*s)),Image.LANCZOS) if s<1 else im

# ---------- masks ----------
_sess=None
def seg(img):
    """returns soft water / sky masks at image size"""
    global _sess
    import onnxruntime as ort
    if _sess is None: _sess=ort.InferenceSession(MD+'/model.onnx',providers=['CPUExecutionProvider'])
    lab={int(k):v for k,v in json.load(open(MD+'/config.json'))['id2label'].items()}
    WATER=[i for i,n in lab.items() if n in ('water','sea','river','lake','swimming pool')]; SKY=[i for i,n in lab.items() if n=='sky']
    x=np.asarray(img.resize((512,512),Image.BICUBIC)).astype(np.float32)/255
    x=((x-np.array([0.485,0.456,0.406]))/np.array([0.229,0.224,0.225])).transpose(2,0,1)[None].astype(np.float32)
    lo=_sess.run(None,{_sess.get_inputs()[0].name:x})[0][0]; e=np.exp(lo-lo.max(0)); p=e/e.sum(0)
    up=lambda m: np.clip(np.asarray(Image.fromarray(m.astype(np.float32),'F').resize(img.size,Image.BICUBIC)),0,1)
    return up(p[WATER].sum(0)), up(p[SKY].sum(0))
def seg_classes(img, names):
    """soft mask (image size) for any ADE20K labels, e.g. ['person'], ['railing','fence'], ['car']"""
    global _sess
    import onnxruntime as ort
    if _sess is None: _sess=ort.InferenceSession(MD+'/model.onnx',providers=['CPUExecutionProvider'])
    lab={int(k):v for k,v in json.load(open(MD+'/config.json'))['id2label'].items()}
    ids=[i for i,n in lab.items() if any(n==x or n.startswith(x+',') or x in n.split(', ') for x in names)]
    x=np.asarray(img.resize((512,512),Image.BICUBIC)).astype(np.float32)/255
    x=((x-np.array([0.485,0.456,0.406]))/np.array([0.229,0.224,0.225])).transpose(2,0,1)[None].astype(np.float32)
    lo=_sess.run(None,{_sess.get_inputs()[0].name:x})[0][0]; e=np.exp(lo-lo.max(0)); p=e/e.sum(0)
    return np.clip(np.asarray(Image.fromarray(p[ids].sum(0).astype(np.float32),'F').resize(img.size,Image.BICUBIC)),0,1)

def _refine(m,lab,r):
    """岸线：边界带内按「离本地水色近还是离本地岸色近」逐像素判，偏向判岸（防青边）"""
    band=blur(m,max(r//2,4)); band=(band>0.05)&(band<0.95)
    def lm(w):
        den=np.maximum(blur(w,r*3),0)+1e-3; return np.stack([blur(lab[...,i]*w,r*3)/den for i in range(3)],-1)
    wt=np.array([0.5,1,1]); mw,ml=lm((m>0.9)*1.0),lm((m<0.1)*1.0)
    dw=np.linalg.norm((lab-mw)*wt,axis=-1); dl=np.linalg.norm((lab-ml)*wt,axis=-1)
    return np.clip(blur(np.where(band,1/(1+np.exp(np.clip(-(dl-dw-4)/2.5,-50,50))),m),2),0,1)
def masks(img,lab):
    W,H=img.size; wm,sm=seg(img)
    if wm.mean()>0.5:   # 近景满幅水面：模型会把碎光认成天 -> 天并入水，只排除有把握的陆地
        other=np.clip(1-wm-sm,0,1); wm=np.clip(1-blur(ss(other,0.6,0.9),max(W//40,8)),0,1); sm=np.zeros_like(sm)
    else: wm=_refine(wm,lab,max(W//60,8))
    wm=ss(wm,0.35,0.65); sm=ss(sm,0.35,0.65)
    if wm.sum()>W*H*0.01:   # 暖色守卫：芦苇沙嘴/泥滩/倒影里的暖色不染成水
        mu=lab[wm>0.8].mean(0) if (wm>0.8).any() else lab.reshape(-1,3).mean(0)
        wm=wm*np.clip(1-blur(ss(lab[...,2]-mu[2],6,12),3),0,1)
    return wm,sm

# ---------- dehaze ----------
def _boxf(x,r):
    H,W=x.shape; c=np.cumsum(np.cumsum(np.pad(x,((1,0),(1,0))),0),1)
    y0=np.clip(np.arange(H)-r,0,H); y1=np.clip(np.arange(H)+r+1,0,H); x0=np.clip(np.arange(W)-r,0,W); x1=np.clip(np.arange(W)+r+1,0,W)
    return (c[y1][:,x1]-c[y0][:,x1]-c[y1][:,x0]+c[y0][:,x0])/((y1-y0)[:,None]*(x1-x0)[None,:])
def _guided(I,p,r,eps=1e-3):
    mI,mp=_boxf(I,r),_boxf(p,r); a=(_boxf(I*p,r)-mI*mp)/(_boxf(I*I,r)-mI*mI+eps); b=mp-a*mI
    return _boxf(a,r)*I+_boxf(b,r)
def dehaze(a,omega=0.65,tmin=0.55,r=7):
    H,W=a.shape[:2]; k=max(W//1000,1); sw,sh=W//k,H//k
    sa=np.asarray(Image.fromarray((a*255).astype(np.uint8)).resize((sw,sh),Image.BOX),np.float64)/255
    dc=np.asarray(Image.fromarray((sa.min(-1)*255).astype(np.uint8)).filter(ImageFilter.MinFilter(2*r+1)),np.float64)/255
    idx=np.argsort(dc.ravel())[-max(dc.size//1000,1):]; A=np.clip(sa.reshape(-1,3)[idx].mean(0),0.6,1.0)
    t=_guided(sa.mean(-1),1-omega*dc/A.max(),max(sw//40,8))
    t=np.clip(np.asarray(Image.fromarray(t.astype(np.float32),'F').resize((W,H),Image.BICUBIC)),tmin,1)[...,None]
    return np.clip((a-A)/t+A,0,1)

# ---------- grade ----------
def grade(img, water=(54.0,-17.0,-7.0), water_var=0.6, dehaze_amt=1.0, sky_hue=-100.0, autumn=0.25):
    a=np.asarray(img).astype(np.float64)/255; H,W=a.shape[:2]
    wm,sm=masks(img,rgb2lab(a))
    # 1+2 去雾（天空一半、宽羽化防山脊白边）+ 黑白点
    skw=np.clip(blur(sm,max(W//25,8)),0,1)
    w=((1-0.4*wm)*(1-0.5*skw))[...,None]*dehaze_amt; a=a*(1-w)+dehaze(a)*w
    lv=a.copy()
    for c in range(3):
        l,h=np.percentile(a[...,c],[0.4,99.6]); lv[...,c]=np.clip((a[...,c]-l)/max(h-l,1e-3),0,1)
    a=a*0.5+lv*0.5
    lab=rgb2lab(a); L,A,B=lab[...,0].copy(),lab[...,1].copy(),lab[...,2].copy()
    # 3 对比
    L=L+0.15*(L-blur(L,40)); L=100*np.interp(L/100,[0,0.1,0.3,0.5,0.7,0.9,1],[0,0.09,0.28,0.5,0.72,0.91,1])
    # 4 水：绝对目标色
    if wm.sum()>W*H*0.01:
        sel=wm>0.8; mu=np.array([L[sel].mean(),A[sel].mean(),B[sel].mean()]); keep=1-ss(L,80,95); m=wm*keep
        L=L*(1-wm)+(water[0]+0.75*(L-mu[0]))*wm
        A=A*(1-m)+(water[1]+water_var*(A-mu[1]))*m; B=B*(1-m)+(water[2]+water_var*(B-mu[2]))*m
    # 5 天
    if sm.sum()>W*H*0.01:
        A3,B3=hue_pull(A,B,sky_hue,0.5,sm); A=A*(1-sm)+A3*sm; B=B*(1-sm)+B3*sm-3*sm; L=L-1.5*sm
    # 6 土地
    land=np.clip(1-wm-sm,0,1); C0=np.hypot(A,B); lw=land*ss(C0,5,14)*(1-ss(-B,-1,4))
    A2,B2=hue_pull(A,B,70.0,0.35,lw); A=A*(1-lw)+A2*lw; B=B*(1-lw)+B2*lw
    A=A*(1+autumn*lw); B=B*(1+autumn*lw)
    shd=land*(1-ss(L,25,55))*(1-ss(C0,8,16)); B=B+4*shd; A=A+0.5*shd; L=L+3*shd   # 去雾后暗坡发紫 -> 回暖
    out=lab2rgb(np.stack([L,A,B],-1))+np.random.default_rng(0).uniform(-0.5,0.5,(H,W,3))/255   # dither 防断层
    return Image.fromarray((np.clip(out,0,1)*255+0.5).astype(np.uint8))
