"""从「原图 → 调好的图」学一个 3D LUT（.cube），给达芬奇/剪映/PS 一键套用。

原理：把成对像素按原图颜色落进 33³ 的格子，每格取调后颜色的平均；没样本的格子
用相邻格子逐步扩散补齐，最后轻微平滑。LUT 只能表达「同一个颜色 → 同一个颜色」，
所以分区（水和天颜色接近却调法不同）、去雾这类空间操作只能近似；报告里给出误差。
用法：
  python lut.py fit  out.cube  原图1 调后1 [原图2 调后2 ...]
  python lut.py apply in.cube 图片 输出
"""
import sys
import numpy as np
from PIL import Image

N=33
def base_lut(params):
    """可精确表达为全局映射的底色；不把分区操作伪装成 LUT。"""
    from grade import rgb2lab, lab2rgb, _lin, _gam
    grid=np.stack(np.meshgrid(*[np.linspace(0,1,N)]*3,indexing='ij'),-1)
    light=params.get('enabled',{}).get('light',True)
    rgb=_gam(np.clip(_lin(grid)*2**(params.get('exposure',0) if light else 0),0,1))
    lab=rgb2lab(rgb)
    if light and params.get('enabled',{}).get('contrast',True):
        L=lab[...,0]; curve=100*np.interp(L/100,[0,.1,.3,.5,.7,.9,1],[0,.09,.28,.5,.72,.91,1])
        lab[...,0]=L+(curve-L)*params.get('contrast',1)
    lab[...,1:]*=params.get('saturation',1) if params.get('enabled',{}).get('color',True) else 1
    return np.clip(lab2rgb(lab),0,1)
def _pairs(src,dst,long=1200):
    a=Image.open(src).convert('RGB'); b=Image.open(dst).convert('RGB')
    if a.size!=b.size: a=a.resize(b.size,Image.LANCZOS)
    s=long/max(b.size)
    if s<1: a=a.resize((int(a.width*s),int(a.height*s)),Image.BOX); b=b.resize(a.size,Image.BOX)
    return np.asarray(a,np.float64).reshape(-1,3)/255, np.asarray(b,np.float64).reshape(-1,3)/255
def fit(pairs):
    S=np.zeros((N,N,N,3)); C=np.zeros((N,N,N))
    for x,y in pairs:
        i=np.clip(np.rint(x*(N-1)).astype(int),0,N-1)
        np.add.at(S,(i[:,0],i[:,1],i[:,2]),y); np.add.at(C,(i[:,0],i[:,1],i[:,2]),1)
    filled=C>=3; L=np.where(filled[...,None],S/np.maximum(C,1)[...,None],0)
    g=np.stack(np.meshgrid(*[np.linspace(0,1,N)]*3,indexing='ij'),-1)
    # empty cells: start from identity offset of nearest filled neighbours (diffuse the *offset*, not the colour)
    off=np.where(filled[...,None],L-g,0.0); known=filled.copy()
    for _ in range(200):
        if known.all(): break
        acc=np.zeros_like(off); cnt=np.zeros(known.shape)
        for ax in range(3):
            for d in (1,-1):
                acc+=np.roll(off*known[...,None],d,ax); cnt+=np.roll(known,d,ax)
        new=(~known)&(cnt>0); off[new]=acc[new]/cnt[new][:,None]; known|=new
    # light smoothing of the offset field (keeps transitions free of steps)
    for _ in range(2):
        sm=off.copy()
        for ax in range(3): sm+=np.roll(off,1,ax)+np.roll(off,-1,ax)
        off=sm/7
    return np.clip(g+off,0,1), filled.mean()
def write_cube(L,path,title='photo-edit'):
    with open(path,'w') as f:
        f.write(f'TITLE "{title}"\nLUT_3D_SIZE {N}\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n')
        for b in range(N):
            for g in range(N):
                for r in range(N): f.write('%.6f %.6f %.6f\n'%tuple(L[r,g,b]))
def read_cube(path):
    with open(path) as handle:
        rows=[l.split() for l in handle if l[:1].isdigit() or l[:1]=='-' or (l[:1]=='.' )]
    v=np.array([[float(t) for t in r] for r in rows if len(r)==3]); n=round(len(v)**(1/3))
    return v.reshape(n,n,n,3).transpose(2,1,0,3)
def apply(L,img):
    n=L.shape[0]; a=np.asarray(img.convert('RGB'),np.float64)/255*(n-1)
    i0=np.clip(np.floor(a).astype(int),0,n-2); f=a-i0; out=0
    for dr in (0,1):
        for dg in (0,1):
            for db in (0,1):
                w=(f[...,0] if dr else 1-f[...,0])*(f[...,1] if dg else 1-f[...,1])*(f[...,2] if db else 1-f[...,2])
                out=out+w[...,None]*L[i0[...,0]+dr,i0[...,1]+dg,i0[...,2]+db]
    return Image.fromarray((np.clip(out,0,1)*255+0.5).astype(np.uint8))
if __name__=='__main__':
    if sys.argv[1]=='fit':
        ps=[_pairs(sys.argv[i],sys.argv[i+1]) for i in range(3,len(sys.argv),2)]
        L,cov=fit(ps); write_cube(L,sys.argv[2]); print(f'coverage {cov:.1%}')
    else:
        apply(read_cube(sys.argv[2]),Image.open(sys.argv[3])).save(sys.argv[4],quality=93)
