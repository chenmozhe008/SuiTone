"""RAW 读取（rawpy/LibRaw）：ProRAW DNG、佳能 CR2/CR3、尼康 NEF、索尼 ARW 等。
RAW 比 JPG 多出来的是高光和暗部的余量，所以这里：线性 16bit 解码 → 曝光补偿 → 高光柔和压缩（救天空）
→ 输出给 grade() 的 8bit 图。用法：
  from raw import load_raw ; img = load_raw('x.DNG', exposure=0.0, highlight=0.8, long=4032)
"""
import numpy as np
from PIL import Image
def load_raw(path, exposure=0.0, highlight=0.8, long=4032):
    import rawpy
    with rawpy.imread(path) as r:
        rgb=r.postprocess(use_camera_wb=True, no_auto_bright=True, output_bps=16, gamma=(1,1),
                          highlight_mode=rawpy.HighlightMode.Blend, output_color=rawpy.ColorSpace.sRGB)
    x=rgb.astype(np.float64)/65535*(2**exposure)
    # auto exposure anchor: put the 50th percentile luminance near 0.18 linear
    lum=x.mean(-1); k=0.18/max(np.percentile(lum,50),1e-4); x=x*np.clip(k,0.25,8)
    # highlight shoulder (Reinhard-style on the top end only) — keeps clouds / bright sky detail
    t=0.7; over=np.clip(x-t,0,None); x=np.where(x>t,t+over/(1+over/(highlight*(1-t)+1e-6)),x)
    x=np.clip(x/max(x.max(),1e-6) if x.max()>1 else x,0,1)
    srgb=np.where(x<=0.0031308,12.92*x,1.055*x**(1/2.4)-0.055)
    im=Image.fromarray((np.clip(srgb,0,1)*255+0.5).astype(np.uint8))
    s=long/max(im.size)
    return im.resize((int(im.width*s),int(im.height*s)),Image.LANCZOS) if s<1 else im
