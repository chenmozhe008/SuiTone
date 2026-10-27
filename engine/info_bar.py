"""底部出片信息白条（iPhone 式）：左 地点 + 坐标/海拔，右 机型 + 焦距/光圈/快门/ISO/时间。全部读 EXIF（mdls）。
用法： from info_bar import with_bar, meta ; with_bar(img, meta('IMG.jpg'), place='宁夏 · 西吉 · 党家岔震湖')"""
import os, re, subprocess
from datetime import datetime, timedelta
from PIL import Image, ImageDraw, ImageFont
F=lambda s,w: ImageFont.truetype(os.path.expanduser(f'~/Library/Fonts/SourceHanSansCN-{w}.otf'),s)
def meta(path):
    o=subprocess.run(['mdls',path],capture_output=True,text=True).stdout
    g=lambda k:(re.search(rf'{k}\s*=\s*"?([^"\n]+)',o) or [None,None])[1]
    return dict(lat=g('kMDItemLatitude'),lon=g('kMDItemLongitude'),alt=g('kMDItemAltitude'),model=g('kMDItemAcquisitionModel'),
                f=g('kMDItemFocalLength35mm'),fn=g('kMDItemFNumber'),t=g('kMDItemExposureTimeSeconds'),iso=g('kMDItemISOSpeed'),date=g('kMDItemContentCreationDate'))
def _dms(v,p,n): v=float(v); d=abs(v); return f"{int(d)}°{int(d*60%60):02d}′{int(d*3600%60):02d}″{p if v>=0 else n}"
def with_bar(g, m, place, tz=8):
    dt=datetime.strptime(m['date'][:19],'%Y-%m-%d %H:%M:%S')+timedelta(hours=tz)
    l2=f"{_dms(m['lat'],'N','S')}  {_dms(m['lon'],'E','W')}   海拔 {round(float(m['alt']))} m"
    r2=f"{m['f']}mm  f/{float(m['fn']):.1f}  1/{round(1/float(m['t']))}s  ISO {m['iso']}   {dt:%Y.%m.%d %H:%M}"
    W,H=g.size; bar=int(max(W,H)*0.055); c=Image.new('RGB',(W,H+bar),(250,250,248)); c.paste(g,(0,0)); d=ImageDraw.Draw(c)
    fs=int(bar*0.24); y=H+bar//2; pad=int(W*0.03)
    d.text((pad,y-int(fs*0.7)),place,font=F(fs,'Bold'),fill=(30,30,30),anchor='lm')
    d.text((pad,y+int(fs*0.75)),l2,font=F(int(fs*0.72),'Normal'),fill=(130,130,130),anchor='lm')
    d.text((W-pad,y-int(fs*0.7)),m['model'],font=F(fs,'Bold'),fill=(30,30,30),anchor='rm')
    d.text((W-pad,y+int(fs*0.75)),r2,font=F(int(fs*0.72),'Normal'),fill=(130,130,130),anchor='rm')
    return c
