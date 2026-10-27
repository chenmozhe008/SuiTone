"""底部出片信息白条（iPhone 式）：左 地点 + 坐标/海拔，右 机型 + 焦距/光圈/快门/ISO/时间。全部读 EXIF（mdls）。
用法： from info_bar import with_bar, meta ; with_bar(img, meta('IMG.jpg'), place='宁夏 · 西吉 · 党家岔震湖')"""
import os, re, subprocess
from datetime import datetime, timedelta
from PIL import Image, ImageDraw, ImageFont
def F(size, weight):
    for path in [os.path.expanduser(f'~/Library/Fonts/SourceHanSansCN-{weight}.otf'),
                 '/System/Library/Fonts/PingFang.ttc', '/System/Library/Fonts/STHeiti Light.ttc']:
        if os.path.isfile(path): return ImageFont.truetype(path, size)
    return ImageFont.load_default(size=size)
def meta(path):
    o=subprocess.run(['mdls',path],capture_output=True,text=True).stdout
    g=lambda k:(re.search(rf'{k}\s*=\s*"?([^"\n]+)',o) or [None,None])[1]
    result=dict(lat=g('kMDItemLatitude'),lon=g('kMDItemLongitude'),alt=g('kMDItemAltitude'),model=g('kMDItemAcquisitionModel'),
                f=g('kMDItemFocalLength35mm'),fn=g('kMDItemFNumber'),t=g('kMDItemExposureTimeSeconds'),iso=g('kMDItemISOSpeed'),date=g('kMDItemContentCreationDate'))
    result={k:None if v in (None,'(null)','null') else v.strip() for k,v in result.items()}
    try:
        with Image.open(path) as image:
            exif=image.getexif(); camera=exif.get(272)
            try: detail=exif.get_ifd(34665)
            except (KeyError,TypeError): detail={}
            for key,tag in [('f',41989),('fn',33437),('t',33434),('iso',34855)]:
                if detail.get(tag) is not None: result[key]=str(float(detail[tag]))
            if camera: result['model']=str(camera)
            shot=detail.get(36867) or exif.get(306)
            if shot:
                try:
                    result['date']=datetime.strptime(str(shot)[:19],'%Y:%m:%d %H:%M:%S').strftime('%Y-%m-%d %H:%M:%S')
                    result['local_date']=True
                except ValueError: pass
    except (OSError,ValueError): pass
    return result
def _dms(v,p,n): v=float(v); d=abs(v); return f"{int(d)}°{int(d*60%60):02d}′{int(d*3600%60):02d}″{p if v>=0 else n}"
def with_bar(g, m, place, tz=8):
    def value(key,formatter):
        try: return formatter(float(m[key])) if m.get(key) is not None else ''
        except (ValueError,TypeError,ZeroDivisionError): return ''
    date=''
    try:
        dt=datetime.strptime(m['date'][:19],'%Y-%m-%d %H:%M:%S')
        if not m.get('local_date'): dt+=timedelta(hours=tz)
        date=dt.strftime('%Y.%m.%d %H:%M')
    except (ValueError,TypeError,KeyError): pass
    l2='  '.join(filter(None,[value('lat',lambda x:_dms(x,'N','S')),value('lon',lambda x:_dms(x,'E','W')),value('alt',lambda x:f'海拔 {round(x)} m')]))
    r2='  '.join(filter(None,[value('f',lambda x:f'{x:g}mm'),value('fn',lambda x:f'f/{x:.1f}'),value('t',lambda x:f'1/{round(1/x)}s' if x<1 else f'{x:g}s'),value('iso',lambda x:f'ISO {x:g}'),date]))
    W,H=g.size; bar=int(max(W,H)*0.055); c=Image.new('RGB',(W,H+bar),(250,250,248)); c.paste(g,(0,0)); d=ImageDraw.Draw(c)
    fs=int(bar*0.24); y=H+bar//2; pad=int(W*0.03)
    d.text((pad,y-int(fs*0.7)),place,font=F(fs,'Bold'),fill=(30,30,30),anchor='lm')
    d.text((pad,y+int(fs*0.75)),l2,font=F(int(fs*0.72),'Normal'),fill=(130,130,130),anchor='lm')
    d.text((W-pad,y-int(fs*0.7)),m.get('model') or '',font=F(fs,'Bold'),fill=(30,30,30),anchor='rm')
    d.text((W-pad,y+int(fs*0.75)),r2,font=F(int(fs*0.72),'Normal'),fill=(130,130,130),anchor='rm')
    return c
