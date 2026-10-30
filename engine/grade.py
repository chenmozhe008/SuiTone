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

from paths import ASSETS
MD=str(ASSETS/'segformer')

# ---------- basics ----------
_M=np.array([[0.4124,0.3576,0.1805],[0.2126,0.7152,0.0722],[0.0193,0.1192,0.9505]]); _Mi=np.linalg.inv(_M); _WP=np.array([0.95047,1.0,1.08883])
def _lin(c): return np.where(c<=0.04045,c/12.92,((c+0.055)/1.055)**2.4)
def _gam(c): c=np.clip(c,0,1); return np.where(c<=0.0031308,c*12.92,1.055*c**(1/2.4)-0.055)
def _expose(a,ev,highlights):
    linear=_lin(a)*2**ev
    if ev>0 and highlights<0:
        # 在截断前对亮部做连续肩部压缩，保持线性 RGB 比例和高光细节。
        knee=1-.5*min(-highlights,1.)
        peak=linear.max(axis=-1,keepdims=True)
        shoulder=knee+(1-knee)*(-np.expm1(-np.maximum(peak-knee,0)/(1-knee)))
        linear=linear*np.where(peak>knee,shoulder/np.maximum(peak,1e-12),1.)
    return _gam(linear)
def rgb2lab(a):
    x=_lin(a)@_M.T/_WP; f=np.where(x>0.008856,np.cbrt(x),7.787*x+16/116)
    return np.stack([116*f[...,1]-16,500*(f[...,0]-f[...,1]),200*(f[...,1]-f[...,2])],-1)
def lab2rgb(l):
    fy=(l[...,0]+16)/116; fx=fy+l[...,1]/500; fz=fy-l[...,2]/200; f=np.stack([fx,fy,fz],-1)
    return _gam(np.where(f**3>0.008856,f**3,(f-16/116)/7.787)*_WP@_Mi.T)
def ss(x,a,b): t=np.clip((x-a)/(b-a),0,1); return t*t*(3-2*t)
def _protect_contrast_highlights(original, adjusted):
    """平滑压缩对比增强造成的亮部增量，避免把原有细节推成一片白。"""
    increase=np.maximum(adjusted-original,0)
    room=np.maximum(100-original,0)
    safe=np.maximum(room,1e-9)
    compressed=room*(-np.expm1(-increase/safe))
    return np.where(increase>0,original+compressed,adjusted)
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
    from segmentation import probabilities, mask
    p = probabilities(img)
    return mask(img, ['water','sea','river','lake','swimming pool'], p), mask(img, ['sky'], p)
def seg_classes(img, names):
    """soft mask (image size) for any ADE20K labels, e.g. ['person'], ['railing','fence'], ['car']"""
    from segmentation import mask
    return mask(img, names)

def _refine(m,lab,r):
    """岸线：边界带内按「离本地水色近还是离本地岸色近」逐像素判，偏向判岸（防青边）"""
    band=blur(m,max(r//2,4)); band=(band>0.05)&(band<0.95)
    def lm(w):
        den=np.maximum(blur(w,r*3),0)+1e-3; return np.stack([blur(lab[...,i]*w,r*3)/den for i in range(3)],-1)
    wt=np.array([0.5,1,1]); mw,ml=lm((m>0.9)*1.0),lm((m<0.1)*1.0)
    dw=np.linalg.norm((lab-mw)*wt,axis=-1); dl=np.linalg.norm((lab-ml)*wt,axis=-1)
    return np.clip(blur(np.where(band,1/(1+np.exp(np.clip(-(dl-dw-4)/2.5,-50,50))),m),2),0,1)
def masks(img,lab,segmentation=None):
    W,H=img.size; wm,sm=seg(img) if segmentation is None else segmentation
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
def dehaze(a,omega=0.65,tmin=0.55,r=7,return_fields=False):
    H,W=a.shape[:2]; k=max(W//1000,1); sw,sh=W//k,H//k
    sa=np.asarray(Image.fromarray((a*255).astype(np.uint8)).resize((sw,sh),Image.BOX),np.float64)/255
    dc=np.asarray(Image.fromarray((sa.min(-1)*255).astype(np.uint8)).filter(ImageFilter.MinFilter(2*r+1)),np.float64)/255
    idx=np.argsort(dc.ravel())[-max(dc.size//1000,1):]; A=np.clip(sa.reshape(-1,3)[idx].mean(0),0.6,1.0)
    t=_guided(sa.mean(-1),1-omega*dc/A.max(),max(sw//40,8))
    t=np.clip(np.asarray(Image.fromarray(t.astype(np.float32),'F').resize((W,H),Image.BICUBIC)),tmin,1)[...,None]
    out=np.clip((a-A)/t+A,0,1)
    return (out,A,t[...,0]) if return_fields else out

# ---------- grade ----------
def grade_array(img, water=(54.0,-17.0,-7.0), water_var=0.6, dehaze_amt=1.0,
                sky_hue=-100.0, autumn=0.25, black_white=0.5, contrast=1.0,
                exposure=0.0, saturation=1.0, enabled=None, regions=None,
                match_strength=1.0, skin_protect=False, smooth=0.0, bright=0.0, analysis=None,auto_dehaze=False,
                temperature=0.0,tint=0.0,highlights=0.0,shadows=0.0,effect_strength=1.0,
                shadow_hue=-160.,shadow_chroma=0.,highlight_hue=65.,highlight_chroma=0.,fade=0.,
                whites=0.,blacks=0.,light=0.,vibrance=0.,texture=0.,local=None,manual_masks=None):
    if auto_dehaze:
        if analysis is None:
            from analysis import Analysis
            analysis=Analysis(img)
        dehaze_amt=analysis.recommended_dehaze()
    a=np.asarray(img).astype(np.float64)/255 if analysis is None else analysis.rgb.copy()
    H,W=a.shape[:2]; enabled=enabled or {}
    on=lambda n: enabled.get(n, True) and (enabled.get('light',True) if n in ('levels','dehaze','contrast') else True)
    wm,sm=masks(img,rgb2lab(a)) if analysis is None else (analysis.water,analysis.sky)
    # 1+2 去雾（天空一半、宽羽化防山脊白边）+ 黑白点
    skw=analysis.sky_blurred if getattr(analysis,'global_fields',False) else np.clip(blur(sm,max(W//25,8)),0,1)
    if analysis is not None and not getattr(analysis,'global_fields',False): analysis.sky_blurred=skw
    if on('dehaze') and dehaze_amt:
        if analysis is not None and analysis.dehazed is None:
            analysis.dehazed,analysis.dehaze_A,analysis.dehaze_t=dehaze(a,return_fields=True)
        dz=dehaze(a) if analysis is None else analysis.dehazed
        w=((1-0.4*wm)*(1-0.5*skw))[...,None]*dehaze_amt; a=a*(1-w)+dz*w
    lv=a.copy()
    level_points=[]
    for c in range(3):
        l,h=analysis.level_points[c] if getattr(analysis,'global_fields',False) else np.percentile(a[...,c],[0.4,99.6])
        level_points.append((l,h));lv[...,c]=np.clip((a[...,c]-l)/max(h-l,1e-3),0,1)
    if analysis is not None and not getattr(analysis,'global_fields',False): analysis.level_points=level_points
    k=black_white if on('levels') else 0; a=a*(1-k)+lv*k
    if exposure and on('light'): a=_expose(a,exposure,highlights)
    lab=rgb2lab(a); L,A,B=lab[...,0].copy(),lab[...,1].copy(),lab[...,2].copy()
    # 3 对比
    if on('contrast'):
        old=L.copy()
        local_blur=analysis.contrast_blur if getattr(analysis,'global_fields',False) else blur(L,40)
        if analysis is not None and not getattr(analysis,'global_fields',False): analysis.contrast_blur=local_blur
        L=L+0.15*(L-local_blur); L=100*np.interp(L/100,[0,0.1,0.3,0.5,0.7,0.9,1],[0,0.09,0.28,0.5,0.72,0.91,1]); L=old+(L-old)*contrast
        L=_protect_contrast_highlights(old,L)
    # 4 水：绝对目标色
    if on('water') and getattr(analysis,'water_active',wm.sum()>W*H*0.01):
        sel=wm>0.8
        if not sel.any(): sel=wm>0.35
        mu=analysis.water_mean if getattr(analysis,'global_fields',False) else np.array([L[sel].mean(),A[sel].mean(),B[sel].mean()])
        if analysis is not None and not getattr(analysis,'global_fields',False): analysis.water_mean=mu
        keep=1-ss(L,80,95); m=wm*keep
        L=L*(1-wm)+(water[0]+0.75*(L-mu[0]))*wm
        A=A*(1-m)+(water[1]+water_var*(A-mu[1]))*m; B=B*(1-m)+(water[2]+water_var*(B-mu[2]))*m
    # 5 天
    if on('sky') and getattr(analysis,'sky_active',sm.sum()>W*H*0.01):
        A3,B3=hue_pull(A,B,sky_hue,0.5,sm); A=A*(1-sm)+A3*sm; B=B*(1-sm)+B3*sm-3*sm; L=L-1.5*sm
    # 6 土地
    land=np.clip(1-wm-sm,0,1) if on('land') else np.zeros_like(wm); C0=np.hypot(A,B); lw=land*ss(C0,5,14)*(1-ss(-B,-1,4))
    A2,B2=hue_pull(A,B,70.0,0.35,lw); A=A*(1-lw)+A2*lw; B=B*(1-lw)+B2*lw
    A=A*(1+autumn*lw); B=B*(1+autumn*lw)
    shd=land*(1-ss(L,25,55))*(1-ss(C0,8,16)); B=B+4*shd; A=A+0.5*shd; L=L+3*shd   # 去雾后暗坡发紫 -> 回暖
    sat=saturation if on('color') else 1
    if on('light'):
        # 「光线」总滑块：只推中间调，两端不动，避免拉过头变灰或爆白。
        if light:L=L+light*16*np.sin(np.pi*np.clip(L,0,100)/100)
        L=L+shadows*18*(1-ss(L,12,62))*ss(L,0,8)
        L=L+highlights*18*ss(L,42,85)*(1-ss(L,96,100))
        if whites:L=L+whites*12*ss(L,55,96)
        if blacks:L=L+blacks*12*(1-ss(L,4,40))
    if on('color'):
        mid=.3+.7*np.clip(1-np.abs(L-50)/50,0,1)
        A=A+tint*7*mid; B=B+temperature*10*mid
        if shadow_chroma or highlight_chroma:
            shadow=(1-ss(L,18,62))*ss(L,0,10)*shadow_chroma
            highlight=ss(L,45,86)*(1-ss(L,98,100))*highlight_chroma
            A=A+shadow*np.cos(np.deg2rad(shadow_hue))+highlight*np.cos(np.deg2rad(highlight_hue))
            B=B+shadow*np.sin(np.deg2rad(shadow_hue))+highlight*np.sin(np.deg2rad(highlight_hue))
    if fade and on('light'):L=L+fade*14*(1-ss(L,0,58))
    lab=np.stack([L,A*sat,B*sat],-1)
    if vibrance and on('color'):
        # 「颜色」总滑块：加色时优先补淡的颜色，已经很浓的少动；减色时整体收。
        C=np.hypot(lab[...,1],lab[...,2])
        f=1+vibrance*(.8*(1-ss(C,10,60)) if vibrance>0 else .7)
        lab[...,1]*=f;lab[...,2]*=f
    if regions and on('match'):
        from match import apply_regions
        if analysis is None:
            from analysis import Analysis
            analysis=Analysis(img)
        lab=apply_regions(lab,analysis,regions,match_strength)
    if local:
        if analysis is None:
            from analysis import Analysis
            analysis=Analysis(img)
        lab=apply_local(lab,analysis,local,W,manual_masks or {})
    if on('portrait') and (skin_protect or smooth or bright):
        if analysis is None:
            from analysis import Analysis
            analysis=Analysis(img)
        if analysis.skin.any():
            from portrait import adjust_lab
            lab=adjust_lab(analysis.lab,lab,analysis.skin,skin_protect,smooth,bright)
    if texture:lab=apply_texture(lab,analysis,texture,W,H)
    if effect_strength<1:
        original=analysis.lab if analysis is not None else rgb2lab(np.asarray(img,np.float64)/255)
        lab=original+(lab-original)*effect_strength
    return lab2rgb(lab)


LOCAL_FIELDS=dict(exposure=(-1,1),contrast=(-1,1),highlights=(-1,1),temperature=(-1,1),
                  saturation=(-1,1),hue=(-180,180),feather=(0,1))


def local_mask(analysis,name,feather,W,manual_masks=None):
    """区域遮罩按羽化程度放宽边缘；分条渲染时直接取预览算好的那一份。"""
    cache=analysis.__dict__.setdefault('local_masks',{})
    selection=(manual_masks or {}).get(name)
    if selection is None:key=(name,round(float(feather),3))
    else:
        import json
        key=(name,round(float(feather),3),json.dumps(selection,sort_keys=True,separators=(',',':')))
    if getattr(analysis,'global_fields',False):return cache[key]
    if key not in cache:
        if len(cache)>=64:cache.clear()
        if selection is None:
            m=analysis.region(name)
        else:
            from inpaint import shape_mask
            from PIL import ImageDraw
            image=analysis.image
            if any(selection.get(k) is not None for k in ('strokes','polygon','point','parts')):
                m=shape_mask(image,selection.get('strokes'),selection.get('radius'),selection.get('polygon'),selection.get('point'),
                             selection.get('parts'),allow_large=True)
            else:
                mask=Image.new('L',image.size,0);draw=ImageDraw.Draw(mask)
                l,t,r,b=selection['box'];draw.rectangle((int(l*image.width),int(t*image.height),int(r*image.width),int(b*image.height)),fill=255)
                m=np.asarray(mask,dtype=np.float32)/255
        cache[key]=np.clip(blur(m,max(2,feather*W/25)),0,1) if feather>.02 else m
    return cache[key]


def apply_local(lab,analysis,local,W,manual_masks=None):
    """局部光线和颜色：只在识别到的区域里生效，边缘随羽化过渡。"""
    L,A,B=lab[...,0].copy(),lab[...,1].copy(),lab[...,2].copy()
    for name,v in local.items():
        g=lambda k:float(v.get(k,0))
        if not any(g(k) for k in LOCAL_FIELDS if k!='feather'):continue
        m=local_mask(analysis,name,g('feather'),W,manual_masks)
        L=L+g('exposure')*18*m
        L=L+g('contrast')*.4*(L-50)*m
        L=L+g('highlights')*18*ss(L,42,85)*m
        B=B+g('temperature')*12*m
        if g('hue'):
            t=np.deg2rad(g('hue'))*m;A,B=A*np.cos(t)-B*np.sin(t),A*np.sin(t)+B*np.cos(t)
        f=1+g('saturation')*m;A,B=A*f,B*f
    return np.stack([L,A,B],-1)


def apply_texture(lab,analysis,amount,W,H):
    """「质感」总滑块：暗角、柔光、颗粒一起加。按整幅坐标计算，分条渲染无接缝。"""
    top,full_h,full_w=getattr(analysis,'frame',(0,H,W)) if analysis is not None else (0,H,W)
    L=lab[...,0].copy()
    y=((np.arange(H)+top)/full_h-.5)[:,None]*2;x=(np.arange(W)/full_w-.5)[None,:]*2
    r=np.sqrt(x*x+y*y)/np.sqrt(2)
    if analysis is not None and getattr(analysis,'global_fields',False):glow=analysis.glow_field
    else:
        glow=blur(ss(L,65,95),max(4,W/50))
        if analysis is not None:analysis.glow_field=glow
    L=L+amount*10*glow*(1-L/100)
    L=L*(1-amount*.32*ss(r,.35,1.))
    # 颗粒：按整幅像素坐标取确定性噪声，粒径随画幅缩放，预览和导出观感一致。
    cy=np.floor((np.arange(H)+top)*1600/full_w)[:,None];cx=np.floor(np.arange(W)*1600/full_w)[None,:]
    n=np.modf(np.sin(cx*12.9898+cy*78.233)*43758.5453)[0]
    L=L+amount*3.2*(np.abs(n)-.5)*2*(1-np.abs(L-50)/60).clip(0,1)
    return np.stack([L,lab[...,1],lab[...,2]],-1)


def quantize(rgb,rng=None):
    """只在输出前量化一次，确定性 dither 防色阶断层。"""
    out=rgb+(rng if rng is not None else np.random.default_rng(0)).uniform(-0.5,0.5,rgb.shape)/255
    return Image.fromarray((np.clip(out,0,1)*255+0.5).astype(np.uint8))


def grade(img,water=(54.0,-17.0,-7.0),water_var=.6,dehaze_amt=1.0,sky_hue=-100.0,autumn=.25,**params):
    return quantize(grade_array(img,water=water,water_var=water_var,dehaze_amt=dehaze_amt,
                               sky_hue=sky_hue,autumn=autumn,**params))
